package updater

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"time"

	flowmaster "github.com/vbskycn/flowmaster"
)

// ResolveDistVersion 解析主控分发目标版本号（默认优先对齐主控当前版本，避免无外网环境报错）。
func (m *Manager) ResolveDistVersion(verOrLatest string) (string, error) {
	trimmed := strings.TrimSpace(verOrLatest)
	if trimmed == "" || strings.EqualFold(trimmed, "latest") {
		return flowmaster.AppVersion(), nil
	}
	clean := strings.TrimPrefix(trimmed, "v")
	if !semverStrictRegex.MatchString(clean) {
		return "", errors.New("无效的版本号格式")
	}
	return clean, nil
}

// ResolveDistArchive 为被控节点提供指定版本与架构的预编译 .tar.gz 安装包：
// 1. 若目标版本与主控一致且 CPU 架构相同（linux/amd64 或 linux/arm64），直接将主控自身静态二进制打包返回（零外网依赖）；
// 2. 若跨架构或指定了新版本，首次从 GitHub Release 拉取并严格校验 SHA-256 后缓存在 DATA_DIR/dist-cache/，供后续多台国内节点高速拉取。
func (m *Manager) ResolveDistArchive(ctx context.Context, verOrLatest, arch string) ([]byte, string, string, error) {
	if arch != "amd64" && arch != "arm64" {
		return nil, "", "", errors.New("不支持的目标 CPU 架构")
	}
	ver, err := m.ResolveDistVersion(verOrLatest)
	if err != nil {
		return nil, "", "", err
	}

	m.distMu.Lock()
	defer m.distMu.Unlock()

	cacheRoot := m.distCacheRoot()
	verDir := filepath.Join(cacheRoot, "v"+ver)
	if mkErr := os.MkdirAll(verDir, 0o750); mkErr != nil {
		return nil, "", "", fmt.Errorf("初始化安装包缓存目录失败: %w", mkErr)
	}
	m.pruneOldDistVersionsLocked(cacheRoot, "v"+ver)

	// 同版本且同为 Linux 匹配架构时，优先由本机当前静态可执行文件直接合成归档（即使主控无 GitHub 外网也可完成分发）
	if ver == flowmaster.AppVersion() && runtime.GOOS == "linux" && runtime.GOARCH == arch {
		data, hash, lErr := m.ensureLocalSelfArchiveLocked(verDir, arch)
		if lErr == nil {
			return data, ver, hash, nil
		}
	}

	archiveName := fmt.Sprintf("flowmaster-linux-%s.tar.gz", arch)
	cachedTar := filepath.Join(verDir, archiveName)
	cachedSum := cachedTar + ".sha256"
	if data, hash, ok := readVerifiedCachedFile(cachedTar, cachedSum); ok {
		return data, ver, hash, nil
	}

	baseURL := fmt.Sprintf("https://github.com/%s/releases/download/v%s", m.repoSlug, ver)
	officialSumsPath := filepath.Join(verDir, "official.SHA256SUMS")
	sumsBytes, err := os.ReadFile(officialSumsPath)
	if err != nil || parseExpectedHash(string(sumsBytes), archiveName) == "" {
		sumsBytes, err = downloadWithFallback(ctx, baseURL+"/SHA256SUMS", 64*1024)
		if err != nil {
			return nil, "", "", fmt.Errorf("主控拉取 v%s SHA256SUMS 失败: %w", ver, err)
		}
		_ = atomicWriteFile(officialSumsPath, sumsBytes, 0o640)
	}

	expectedHash := parseExpectedHash(string(sumsBytes), archiveName)
	if len(expectedHash) != 64 {
		return nil, "", "", fmt.Errorf("未在官方 SHA256SUMS 中找到 %s 摘要", archiveName)
	}

	archiveBytes, err := downloadWithFallback(ctx, baseURL+"/"+archiveName, 64*1024*1024)
	if err != nil {
		return nil, "", "", fmt.Errorf("主控拉取安装包 %s 失败: %w", archiveName, err)
	}
	sum := sha256.Sum256(archiveBytes)
	actualHash := hex.EncodeToString(sum[:])
	if !strings.EqualFold(expectedHash, actualHash) {
		return nil, "", "", errors.New("主控拉取的安装包 SHA-256 校验未通过")
	}

	_ = atomicWriteFile(cachedTar, archiveBytes, 0o640)
	_ = atomicWriteFile(cachedSum, []byte(actualHash+"\n"), 0o640)
	if m.log != nil {
		m.log.Info("主控已缓存跨架构/新版本分发包: v%s (%s, %s...)", ver, archiveName, actualHash[:12])
	}
	return archiveBytes, ver, actualHash, nil
}

// ResolveDistSums 生成或返回主控分发通道对应的 SHA256SUMS 内容。
func (m *Manager) ResolveDistSums(ctx context.Context, verOrLatest string) ([]byte, error) {
	ver, err := m.ResolveDistVersion(verOrLatest)
	if err != nil {
		return nil, err
	}

	m.distMu.Lock()
	defer m.distMu.Unlock()

	cacheRoot := m.distCacheRoot()
	verDir := filepath.Join(cacheRoot, "v"+ver)
	_ = os.MkdirAll(verDir, 0o750)

	hashes := make(map[string]string, 2)

	// 尝试读取或静默拉取官方 SHA256SUMS，使异构架构（如 amd64 主控带 arm64 子节点）也能拿到校验值
	officialSumsPath := filepath.Join(verDir, "official.SHA256SUMS")
	sumsBytes, err := os.ReadFile(officialSumsPath)
	if err != nil {
		fetchCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		baseURL := fmt.Sprintf("https://github.com/%s/releases/download/v%s/SHA256SUMS", m.repoSlug, ver)
		if fetched, fErr := downloadWithFallback(fetchCtx, baseURL, 64*1024); fErr == nil {
			sumsBytes = fetched
			_ = atomicWriteFile(officialSumsPath, sumsBytes, 0o640)
		}
		cancel()
	}
	for _, arch := range []string{"amd64", "arm64"} {
		fn := fmt.Sprintf("flowmaster-linux-%s.tar.gz", arch)
		if h := parseExpectedHash(string(sumsBytes), fn); len(h) == 64 {
			hashes[fn] = strings.ToLower(h)
		}
	}

	// 若请求版本等于主控当前运行版本，确保本机架构条目与本机直出归档哈希严格一致（且无外网时仍可独立生成）
	if ver == flowmaster.AppVersion() && runtime.GOOS == "linux" && (runtime.GOARCH == "amd64" || runtime.GOARCH == "arm64") {
		if _, localHash, lErr := m.ensureLocalSelfArchiveLocked(verDir, runtime.GOARCH); lErr == nil && len(localHash) == 64 {
			fn := fmt.Sprintf("flowmaster-linux-%s.tar.gz", runtime.GOARCH)
			hashes[fn] = localHash
		}
	}

	if len(hashes) == 0 {
		return nil, fmt.Errorf("暂时无法获取 v%s 的 SHA256SUMS 校验清单", ver)
	}

	var out strings.Builder
	for _, arch := range []string{"amd64", "arm64"} {
		fn := fmt.Sprintf("flowmaster-linux-%s.tar.gz", arch)
		if h, ok := hashes[fn]; ok {
			out.WriteString(h)
			out.WriteString("  ")
			out.WriteString(fn)
			out.WriteByte('\n')
		}
	}
	return []byte(out.String()), nil
}

func (m *Manager) tryDownloadUpgradeFromHub(ctx context.Context, ver, archiveName string) ([]byte, error) {
	m.mu.RLock()
	hubURL := m.hubURL
	hubToken := m.hubToken
	m.mu.RUnlock()

	if hubURL == "" || hubToken == "" {
		return nil, errors.New("未配置主控连接")
	}

	sumsURL := fmt.Sprintf("%s/api/v1/cluster/dist/v%s/SHA256SUMS", hubURL, ver)
	sumsBytes, err := fetchHubDistBytes(ctx, sumsURL, hubToken, 64*1024, 15*time.Second)
	if err != nil {
		return nil, err
	}
	expectedHash := parseExpectedHash(string(sumsBytes), archiveName)
	if len(expectedHash) != 64 {
		return nil, fmt.Errorf("主控 SHA256SUMS 未包含 %s", archiveName)
	}

	archiveURL := fmt.Sprintf("%s/api/v1/cluster/dist/v%s/%s", hubURL, ver, archiveName)
	archiveBytes, err := fetchHubDistBytes(ctx, archiveURL, hubToken, 64*1024*1024, 180*time.Second)
	if err != nil {
		return nil, err
	}

	sum := sha256.Sum256(archiveBytes)
	actualHash := hex.EncodeToString(sum[:])
	if !strings.EqualFold(expectedHash, actualHash) {
		return nil, errors.New("主控下发升级包 SHA-256 不匹配")
	}
	return archiveBytes, nil
}

func fetchHubDistBytes(ctx context.Context, targetURL, token string, maxBytes int64, timeout time.Duration) ([]byte, error) {
	reqCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, targetURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("User-Agent", "FlowMaster-Agent-Updater")

	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	data, rErr := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
	_ = resp.Body.Close()
	if rErr != nil || resp.StatusCode != http.StatusOK || len(data) == 0 || int64(len(data)) > maxBytes {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	head := strings.ToLower(string(data[:min(64, len(data))]))
	if strings.Contains(head, "<!doctype html") || strings.Contains(head, "<html") {
		return nil, errors.New("收到非预期的 HTML 响应（请检查反代/CDN WAF 是否拦截了 /api/v1/cluster/）")
	}
	return data, nil
}

func (m *Manager) distCacheRoot() string {
	m.mu.RLock()
	base := m.dataDir
	m.mu.RUnlock()
	if base == "" {
		base = os.TempDir()
	}
	return filepath.Join(base, "dist-cache")
}

func (m *Manager) ensureLocalSelfArchiveLocked(verDir, arch string) ([]byte, string, error) {
	cachedTar := filepath.Join(verDir, fmt.Sprintf("local-flowmaster-linux-%s.tar.gz", arch))
	cachedSum := cachedTar + ".sha256"
	if data, hash, ok := readVerifiedCachedFile(cachedTar, cachedSum); ok {
		return data, hash, nil
	}

	exe, err := os.Executable()
	if err != nil {
		return nil, "", err
	}
	if resolved, rErr := filepath.EvalSymlinks(exe); rErr == nil && resolved != "" {
		exe = resolved
	}
	binBytes, err := os.ReadFile(exe)
	if err != nil || len(binBytes) == 0 {
		return nil, "", fmt.Errorf("读取本机可执行文件失败: %w", err)
	}

	archiveBytes, err := buildDeterministicBinaryTarGz(binBytes)
	if err != nil {
		return nil, "", err
	}
	sum := sha256.Sum256(archiveBytes)
	hash := hex.EncodeToString(sum[:])

	_ = atomicWriteFile(cachedTar, archiveBytes, 0o640)
	_ = atomicWriteFile(cachedSum, []byte(hash+"\n"), 0o640)
	return archiveBytes, hash, nil
}

func buildDeterministicBinaryTarGz(binBytes []byte) ([]byte, error) {
	var buf bytes.Buffer
	gz, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	gz.ModTime = time.Unix(0, 0).UTC()

	tw := tar.NewWriter(gz)
	hdr := &tar.Header{
		Name:     "flowmaster",
		Mode:     0o755,
		Size:     int64(len(binBytes)),
		Typeflag: tar.TypeReg,
		ModTime:  time.Unix(0, 0).UTC(),
	}
	if err := tw.WriteHeader(hdr); err != nil {
		return nil, err
	}
	if _, err := tw.Write(binBytes); err != nil {
		return nil, err
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := gz.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func readVerifiedCachedFile(filePath, sumPath string) ([]byte, string, bool) {
	sumRaw, err := os.ReadFile(sumPath)
	if err != nil {
		return nil, "", false
	}
	expected := strings.ToLower(strings.TrimSpace(string(sumRaw)))
	if len(expected) != 64 {
		return nil, "", false
	}
	data, err := os.ReadFile(filePath)
	if err != nil || len(data) == 0 {
		return nil, "", false
	}
	actualSum := sha256.Sum256(data)
	actual := hex.EncodeToString(actualSum[:])
	if actual != expected {
		return nil, "", false
	}
	return data, actual, true
}

func atomicWriteFile(dest string, data []byte, perm os.FileMode) error {
	tmp := dest + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	if err := os.Rename(tmp, dest); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
}

func (m *Manager) pruneOldDistVersionsLocked(cacheRoot, keepDirName string) {
	entries, err := os.ReadDir(cacheRoot)
	if err != nil {
		return
	}
	var verDirs []string
	for _, e := range entries {
		if e.IsDir() && strings.HasPrefix(e.Name(), "v") {
			verDirs = append(verDirs, e.Name())
		}
	}
	if len(verDirs) <= 3 {
		return
	}
	slices.SortFunc(verDirs, func(a, b string) int {
		return CompareSemver(a, b)
	})
	for len(verDirs) > 3 {
		victim := verDirs[0]
		verDirs = verDirs[1:]
		if victim == keepDirName {
			continue
		}
		_ = os.RemoveAll(filepath.Join(cacheRoot, victim))
	}
}
