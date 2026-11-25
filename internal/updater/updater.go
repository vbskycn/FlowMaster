package updater

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	flowmaster "github.com/vbskycn/flowmaster"
	"github.com/vbskycn/flowmaster/internal/logger"
)

const defaultRepoSlug = "vbskycn/FlowMaster"

var semverStrictRegex = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)

var githubProxyPool = []string{
	"https://gh-proxy.com/",
	"https://ghfast.top/",
	"https://ghproxy.net/",
}

// Manager 负责检测运行部署形态、查询远程最新 Release、主控安装包中转缓存以及执行安全原子自升级。
type Manager struct {
	log             *logger.Manager
	repoSlug        string
	executablePath  string
	deployMode      string
	canSelfUpgrade  bool
	onBeforeRestart func()

	dataDir  string
	hubURL   string
	hubToken string
	distMu   sync.Mutex

	mu             sync.RWMutex
	state          string // idle | upgrading | restarting | failed
	message        string
	cachedLatest   string
	cachedLatestAt time.Time
}

// NewManager 初始化自升级管理器并检测当前进程是否具备安全的二进制原地升级条件。
func NewManager(log *logger.Manager, onBeforeRestart func()) *Manager {
	repo := strings.TrimSpace(os.Getenv("FLOWMASTER_REPO"))
	if repo == "" {
		repo = defaultRepoSlug
	}
	mode := detectDeployMode()
	execPath, canUpgrade := checkBinaryWritable(mode)
	return &Manager{
		log:             log,
		repoSlug:        repo,
		executablePath:  execPath,
		deployMode:      mode,
		canSelfUpgrade:  canUpgrade,
		onBeforeRestart: onBeforeRestart,
		state:           "idle",
	}
}

func detectDeployMode() string {
	if _, err := os.Stat("/.dockerenv"); err == nil {
		return "docker"
	}
	if raw, err := os.ReadFile("/proc/1/cgroup"); err == nil {
		s := string(raw)
		if strings.Contains(s, "docker") || strings.Contains(s, "containerd") || strings.Contains(s, "kubepods") {
			return "docker"
		}
	}
	return "binary"
}

func checkBinaryWritable(mode string) (string, bool) {
	if mode != "binary" || runtime.GOOS != "linux" || (runtime.GOARCH != "amd64" && runtime.GOARCH != "arm64") {
		return "", false
	}
	exe, err := os.Executable()
	if err != nil {
		return "", false
	}
	resolved, err := filepath.EvalSymlinks(exe)
	if err == nil && resolved != "" {
		exe = resolved
	}
	parent := filepath.Dir(exe)
	probe, err := os.CreateTemp(parent, ".fm-write-probe-*")
	if err != nil {
		return exe, false
	}
	probeName := probe.Name()
	_ = probe.Close()
	_ = os.Remove(probeName)
	return exe, true
}

func (m *Manager) DeployMode() string {
	return m.deployMode
}

// ConfigureCluster 注入数据目录与可选的被控主控连接参数：
// - 主控模式下使用 dataDir/dist-cache 缓存并向被控节点分发安装包；
// - 被控模式下执行远程自升级时优先从已连接的主控节点下载安装包，避免国内机器直连 GitHub 失败。
func (m *Manager) ConfigureCluster(dataDir, hubURL, hubToken string) {
	m.mu.Lock()
	m.dataDir = strings.TrimSpace(dataDir)
	m.hubURL = strings.TrimRight(strings.TrimSpace(hubURL), "/")
	m.hubToken = strings.TrimSpace(hubToken)
	m.mu.Unlock()
}

func (m *Manager) CanSelfUpgrade() bool {
	return m.canSelfUpgrade
}

func (m *Manager) Status() (state, message string) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.state, m.message
}

func (m *Manager) setStatus(state, message string) {
	m.mu.Lock()
	m.state = state
	m.message = message
	m.mu.Unlock()
}

// FetchLatestVersion 查询仓库最新发布版本号（带 10 分钟内存缓存与国内多节点代理回退）。
func (m *Manager) FetchLatestVersion(ctx context.Context, forceRefresh bool) (string, error) {
	m.mu.RLock()
	if !forceRefresh && m.cachedLatest != "" && time.Since(m.cachedLatestAt) < 10*time.Minute {
		ver := m.cachedLatest
		m.mu.RUnlock()
		return ver, nil
	}
	m.mu.RUnlock()

	client := &http.Client{Timeout: 6 * time.Second}
	var resolved string

	// 1. 尝试 GitHub Releases API
	apiURL := fmt.Sprintf("https://api.github.com/repos/%s/releases/latest", m.repoSlug)
	if req, err := http.NewRequestWithContext(ctx, http.MethodGet, apiURL, nil); err == nil {
		req.Header.Set("User-Agent", "FlowMaster-Updater")
		if resp, dErr := client.Do(req); dErr == nil {
			raw, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				var parsed struct {
					TagName string `json:"tag_name"`
				}
				if json.Unmarshal(raw, &parsed) == nil {
					cand := strings.TrimPrefix(strings.TrimSpace(parsed.TagName), "v")
					if semverStrictRegex.MatchString(cand) {
						resolved = cand
					}
				}
			}
		}
	}

	// 2. 回退读取主分支 VERSION（自动走直连 + 国内代理候选池）
	if resolved == "" {
		rawVerURL := fmt.Sprintf("https://raw.githubusercontent.com/%s/main/VERSION", m.repoSlug)
		if data, err := downloadWithFallback(ctx, rawVerURL, 16*1024); err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				line = strings.TrimSpace(line)
				if strings.HasPrefix(line, "APP_VERSION=") {
					cand := strings.TrimPrefix(strings.Trim(strings.TrimPrefix(line, "APP_VERSION="), `"' `), "v")
					if semverStrictRegex.MatchString(cand) {
						resolved = cand
						break
					}
				}
			}
		}
	}

	if resolved == "" {
		return flowmaster.AppVersion(), errors.New("暂时无法获取远程最新版本信息")
	}

	m.mu.Lock()
	m.cachedLatest = resolved
	m.cachedLatestAt = time.Now()
	m.mu.Unlock()
	return resolved, nil
}

// TriggerUpgrade 异步启动受控原子自升级流程（仅允许官方 Release 版本号，强制校验 SHA256SUMS）。
func (m *Manager) TriggerUpgrade(targetVersion string) error {
	cleanVer := strings.TrimPrefix(strings.TrimSpace(targetVersion), "v")
	if !semverStrictRegex.MatchString(cleanVer) {
		return errors.New("目标版本号格式无效")
	}
	if cleanVer == flowmaster.AppVersion() {
		m.setStatus("idle", "当前已是目标版本 v"+cleanVer)
		return nil
	}
	if !m.canSelfUpgrade {
		if m.deployMode == "docker" {
			return errors.New("该节点为 Docker 容器运行，请在宿主机执行 sudo ./install.sh update 更新镜像")
		}
		return errors.New("当前二进制目录只读或环境不支持自动替换，请执行 sudo ./install.sh update")
	}

	m.mu.Lock()
	if m.state == "upgrading" || m.state == "restarting" {
		m.mu.Unlock()
		return errors.New("当前节点正在执行升级任务")
	}
	m.state = "upgrading"
	m.message = "正在下载并校验 v" + cleanVer
	m.mu.Unlock()

	go m.runUpgradeWorker(cleanVer)
	return nil
}

func (m *Manager) runUpgradeWorker(ver string) {
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()

	archiveName := fmt.Sprintf("flowmaster-linux-%s.tar.gz", runtime.GOARCH)

	var archiveBytes []byte
	if hubArchive, err := m.tryDownloadUpgradeFromHub(ctx, ver, archiveName); err == nil && len(hubArchive) > 0 {
		archiveBytes = hubArchive
		m.log.Info("已通过主控节点分发通道完成升级包 v%s (%s) 下载与 SHA-256 校验", ver, archiveName)
	} else {
		if err != nil && m.hubURL != "" {
			m.log.Warn("从主控分发源拉取升级包未成功 (%v)，正在回退尝试 GitHub 与加速代理源...", err)
		}
		baseURL := fmt.Sprintf("https://github.com/%s/releases/download/v%s", m.repoSlug, ver)

		sumsBytes, dErr := downloadWithFallback(ctx, baseURL+"/SHA256SUMS", 64*1024)
		if dErr != nil {
			m.failUpgrade("下载 SHA256SUMS 校验文件失败: %v", dErr)
			return
		}
		expectedHash := parseExpectedHash(string(sumsBytes), archiveName)
		if len(expectedHash) != 64 {
			m.failUpgrade("未在 SHA256SUMS 中找到 %s 的有效摘要", archiveName)
			return
		}

		rawArchive, aErr := downloadWithFallback(ctx, baseURL+"/"+archiveName, 64*1024*1024)
		if aErr != nil {
			m.failUpgrade("下载升级包 %s 失败: %v", archiveName, aErr)
			return
		}

		sum := sha256.Sum256(rawArchive)
		actualHash := hex.EncodeToString(sum[:])
		if !strings.EqualFold(expectedHash, actualHash) {
			m.failUpgrade("升级包 SHA-256 摘要不匹配，已中止替换")
			return
		}
		archiveBytes = rawArchive
	}

	binBytes, err := extractBinaryFromTarGz(archiveBytes)
	if err != nil {
		m.failUpgrade("解压升级包失败: %v", err)
		return
	}

	parentDir := filepath.Dir(m.executablePath)
	stagedFile, err := os.CreateTemp(parentDir, ".flowmaster-upgrade-*")
	if err != nil {
		m.failUpgrade("创建临时升级文件失败: %v", err)
		return
	}
	stagedPath := stagedFile.Name()
	cleanupStaged := func() { _ = os.Remove(stagedPath) }

	if _, err := stagedFile.Write(binBytes); err != nil {
		_ = stagedFile.Close()
		cleanupStaged()
		m.failUpgrade("写入新版本二进制失败: %v", err)
		return
	}
	_ = stagedFile.Sync()
	_ = stagedFile.Close()
	if err := os.Chmod(stagedPath, 0o755); err != nil {
		cleanupStaged()
		m.failUpgrade("设置可执行权限失败: %v", err)
		return
	}

	// 替换前先执行一次 --version 自检，确保新二进制在当前内核/CPU 架构可正常启动
	checkCtx, checkCancel := context.WithTimeout(ctx, 5*time.Second)
	out, checkErr := exec.CommandContext(checkCtx, stagedPath, "--version").CombinedOutput()
	checkCancel()
	if checkErr != nil || !strings.Contains(string(out), ver) {
		cleanupStaged()
		m.failUpgrade("新版本二进制预执行自检失败: %v", checkErr)
		return
	}

	if err := os.Rename(stagedPath, m.executablePath); err != nil {
		cleanupStaged()
		m.failUpgrade("原子替换可执行文件失败: %v", err)
		return
	}

	m.log.Info("远程自升级至 v%s 校验替换完成，即将重启进程生效", ver)
	m.setStatus("restarting", "升级至 v"+ver+" 成功，正在重启服务")
	if m.onBeforeRestart != nil {
		m.onBeforeRestart()
	}
	time.Sleep(400 * time.Millisecond)
	os.Exit(0)
}

func (m *Manager) failUpgrade(format string, args ...any) {
	msg := fmt.Sprintf(format, args...)
	m.log.Error("远程自升级失败: %s", msg)
	m.setStatus("failed", msg)
}

func parseExpectedHash(sumsText, filename string) string {
	for _, line := range strings.Split(sumsText, "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		if len(fields) >= 2 {
			target := strings.TrimPrefix(fields[1], "*")
			if target == filename && len(fields[0]) == 64 {
				return fields[0]
			}
		}
	}
	return ""
}

func extractBinaryFromTarGz(archive []byte) ([]byte, error) {
	gz, err := gzip.NewReader(bytes.NewReader(archive))
	if err != nil {
		return nil, err
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if filepath.Base(hdr.Name) == "flowmaster" && (hdr.Typeflag == tar.TypeReg || hdr.Typeflag == tar.TypeRegA) {
			return io.ReadAll(io.LimitReader(tr, 64*1024*1024))
		}
	}
	return nil, errors.New("归档中未找到 flowmaster 二进制文件")
}

func downloadWithFallback(ctx context.Context, rawURL string, maxBytes int64) ([]byte, error) {
	var candidates []string
	if custom := strings.TrimSpace(os.Getenv("FLOWMASTER_GH_PROXY")); custom != "" {
		if !strings.HasSuffix(custom, "/") {
			custom += "/"
		}
		candidates = append(candidates, custom+rawURL)
	}
	if os.Getenv("FLOWMASTER_CN") == "1" {
		for _, p := range githubProxyPool {
			candidates = append(candidates, p+rawURL)
		}
		candidates = append(candidates, rawURL)
	} else {
		candidates = append(candidates, rawURL)
		for _, p := range githubProxyPool {
			candidates = append(candidates, p+rawURL)
		}
	}

	client := &http.Client{Timeout: 45 * time.Second}
	var lastErr error
	for _, target := range candidates {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
		if err != nil {
			lastErr = err
			continue
		}
		req.Header.Set("User-Agent", "FlowMaster-Updater")
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		data, rErr := io.ReadAll(io.LimitReader(resp.Body, maxBytes+1))
		_ = resp.Body.Close()
		if rErr != nil || resp.StatusCode != http.StatusOK || len(data) == 0 || int64(len(data)) > maxBytes {
			lastErr = fmt.Errorf("HTTP %d from %s", resp.StatusCode, target)
			continue
		}
		head := strings.ToLower(string(data[:min(64, len(data))]))
		if strings.Contains(head, "<!doctype html") || strings.Contains(head, "<html") {
			lastErr = fmt.Errorf("proxy returned HTML error page from %s", target)
			continue
		}
		return data, nil
	}
	if lastErr == nil {
		lastErr = errors.New("下载失败")
	}
	return nil, lastErr
}

// CompareSemver 比较两个 a.b.c 版本号：a < b 返回 -1，相等返回 0，a > b 返回 1。
func CompareSemver(a, b string) int {
	pa := parseSemverParts(a)
	pb := parseSemverParts(b)
	for i := 0; i < 3; i++ {
		if pa[i] < pb[i] {
			return -1
		}
		if pa[i] > pb[i] {
			return 1
		}
	}
	return 0
}

func parseSemverParts(v string) [3]int {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	parts := strings.Split(v, ".")
	var out [3]int
	for i := 0; i < 3 && i < len(parts); i++ {
		var n int
		_, _ = fmt.Sscanf(parts[i], "%d", &n)
		out[i] = n
	}
	return out
}
