package store

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/vbskycn/flowmaster/internal/model"
)

const (
	BackupKindManual     = "manual"
	BackupKindPreRestore = "pre_restore"

	maxBackupArchiveBytes    = 256 * 1024 * 1024 // 上传/恢复压缩包上限 256 MiB
	maxBackupExtractedBytes  = 1024 * 1024 * 1024 // 解压后上限 1 GiB
	maxBackupArchiveMembers  = 16
)

var safeBackupNameRegex = regexp.MustCompile(`^(?:flowmaster-backup|pre-restore)-[0-9]{8}-[0-9]{6}(?:-[0-9]+)?\.tar\.gz$`)

type backupMetadata struct {
	Kind       string `json:"kind"`
	CreatedAt  string `json:"createdAt"`
	Timestamp  int64  `json:"timestamp"`
	AppVersion string `json:"appVersion"`
	DBSHA256   string `json:"dbSha256"`
	Note       string `json:"note,omitempty"`
}

// BackupManager 管理 SQLite 快照备份、完整性校验、保护快照与一键恢复。
type BackupManager struct {
	store     *Store
	backupDir string
}

// NewBackupManager 创建备份管理器并清理上次异常中断可能残留的临时目录。
func NewBackupManager(st *Store, dataDir string) (*BackupManager, error) {
	dir := filepath.Join(dataDir, "backups")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("创建备份目录失败: %w", err)
	}
	mgr := &BackupManager{
		store:     st,
		backupDir: dir,
	}
	mgr.cleanupStaleTemps()
	return mgr, nil
}

func (m *BackupManager) cleanupStaleTemps() {
	entries, err := os.ReadDir(m.backupDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		name := entry.Name()
		if strings.HasPrefix(name, ".tmp-") {
			_ = os.RemoveAll(filepath.Join(m.backupDir, name))
		}
	}
}

// IsValidBackupName 校验备份文件名，防止目录穿越。
func IsValidBackupName(name string) bool {
	return safeBackupNameRegex.MatchString(name)
}

// ResolveBackupPath 返回经过校验的已存在备份归档绝对路径。
func (m *BackupManager) ResolveBackupPath(name string) (string, error) {
	if !IsValidBackupName(name) {
		return "", errors.New("非法的备份文件名")
	}
	full := filepath.Join(m.backupDir, name)
	info, err := os.Lstat(full)
	if err != nil || !info.Mode().IsRegular() {
		return "", errors.New("备份文件不存在")
	}
	return full, nil
}

// CreateSnapshot 创建在线一致性快照（kind: manual | pre_restore），并按保留上限自动轮转旧快照。
func (m *BackupManager) CreateSnapshot(kind, note, appVer string) (model.BackupInfo, error) {
	if !m.store.TryLockMaintenance() {
		return model.BackupInfo{}, errors.New("当前已有备份、恢复或数据导入任务正在执行，请稍后重试")
	}
	defer m.store.UnlockMaintenance()

	return m.createSnapshotUnlocked(kind, note, appVer)
}

func (m *BackupManager) createSnapshotUnlocked(kind, note, appVer string) (model.BackupInfo, error) {
	now := time.Now()
	prefix := "flowmaster-backup"
	if kind == BackupKindPreRestore {
		prefix = "pre-restore"
	} else {
		kind = BackupKindManual
	}

	baseName := fmt.Sprintf("%s-%s.tar.gz", prefix, now.Format("20060102-150405"))
	finalPath := filepath.Join(m.backupDir, baseName)
	for seq := 1; ; seq++ {
		if _, err := os.Stat(finalPath); os.IsNotExist(err) {
			break
		}
		baseName = fmt.Sprintf("%s-%s-%d.tar.gz", prefix, now.Format("20060102-150405"), seq)
		finalPath = filepath.Join(m.backupDir, baseName)
	}

	workDir, err := os.MkdirTemp(m.backupDir, ".tmp-create-*")
	if err != nil {
		return model.BackupInfo{}, fmt.Errorf("创建备份临时目录失败: %w", err)
	}
	defer func() { _ = os.RemoveAll(workDir) }()

	snapDBPath := filepath.Join(workDir, "flowmaster.db")
	if err := m.store.VacuumInto(snapDBPath); err != nil {
		return model.BackupInfo{}, fmt.Errorf("导出数据库一致性快照失败: %w", err)
	}
	if err := VerifySQLiteFile(snapDBPath); err != nil {
		return model.BackupInfo{}, fmt.Errorf("新生成的快照未通过完整性检查: %w", err)
	}

	dbHash, err := sha256File(snapDBPath)
	if err != nil {
		return model.BackupInfo{}, err
	}

	meta := backupMetadata{
		Kind:       kind,
		CreatedAt:  now.Format(time.RFC3339),
		Timestamp:  now.Unix(),
		AppVersion: appVer,
		DBSHA256:   dbHash,
		Note:       note,
	}
	metaBytes, err := json.MarshalIndent(meta, "", "  ")
	if err != nil {
		return model.BackupInfo{}, err
	}

	tmpArchive := filepath.Join(workDir, "archive.tar.gz")
	if err := writeTarGzArchive(tmpArchive, snapDBPath, metaBytes); err != nil {
		return model.BackupInfo{}, fmt.Errorf("打包备份归档失败: %w", err)
	}

	archiveHash, err := sha256File(tmpArchive)
	if err != nil {
		return model.BackupInfo{}, err
	}

	sidecarTmp := filepath.Join(workDir, "archive.sha256")
	sidecarLine := fmt.Sprintf("%s  %s\n", archiveHash, baseName)
	if err := os.WriteFile(sidecarTmp, []byte(sidecarLine), 0o600); err != nil {
		return model.BackupInfo{}, err
	}

	if err := os.Chmod(tmpArchive, 0o600); err != nil {
		return model.BackupInfo{}, err
	}
	if err := os.Rename(tmpArchive, finalPath); err != nil {
		return model.BackupInfo{}, fmt.Errorf("保存备份文件失败: %w", err)
	}
	if err := os.Rename(sidecarTmp, finalPath+".sha256"); err != nil {
		_ = os.Remove(finalPath)
		return model.BackupInfo{}, fmt.Errorf("保存备份校验文件失败: %w", err)
	}

	settings := m.store.GetSystemSettings()
	m.pruneSnapshotsUnlocked(settings.MaxBackups, settings.MaxProtectSnapshots)

	stat, err := os.Stat(finalPath)
	if err != nil {
		return model.BackupInfo{}, err
	}
	return model.BackupInfo{
		Name:       baseName,
		CreatedAt:  meta.CreatedAt,
		Timestamp:  meta.Timestamp,
		SizeBytes:  stat.Size(),
		Kind:       kind,
		SHA256:     archiveHash,
		AppVersion: appVer,
		Note:       note,
	}, nil
}

// ListBackups 按时间倒序返回所有快照列表。
func (m *BackupManager) ListBackups() ([]model.BackupInfo, error) {
	entries, err := os.ReadDir(m.backupDir)
	if err != nil {
		return nil, err
	}
	var list []model.BackupInfo
	for _, entry := range entries {
		name := entry.Name()
		if !entry.Type().IsRegular() || !IsValidBackupName(name) {
			continue
		}
		fullPath := filepath.Join(m.backupDir, name)
		info, err := entry.Info()
		if err != nil {
			continue
		}
		kind := BackupKindManual
		if strings.HasPrefix(name, "pre-restore-") {
			kind = BackupKindPreRestore
		}
		meta, _ := readArchiveMetadataQuick(fullPath)
		createdAt := info.ModTime().Format(time.RFC3339)
		ts := info.ModTime().Unix()
		appVer := ""
		note := ""
		if meta.CreatedAt != "" {
			createdAt = meta.CreatedAt
			ts = meta.Timestamp
			appVer = meta.AppVersion
			note = meta.Note
		}
		hash := readSidecarHash(fullPath + ".sha256")
		list = append(list, model.BackupInfo{
			Name:       name,
			CreatedAt:  createdAt,
			Timestamp:  ts,
			SizeBytes:  info.Size(),
			Kind:       kind,
			SHA256:     hash,
			AppVersion: appVer,
			Note:       note,
		})
	}
	sort.Slice(list, func(i, j int) bool {
		if list[i].Timestamp != list[j].Timestamp {
			return list[i].Timestamp > list[j].Timestamp
		}
		return list[i].Name > list[j].Name
	})
	return list, nil
}

// DeleteBackup 删除指定的历史备份文件及其 sidecar 摘要。
func (m *BackupManager) DeleteBackup(name string) error {
	if !m.store.TryLockMaintenance() {
		return errors.New("当前已有维护任务正在执行，请稍后重试")
	}
	defer m.store.UnlockMaintenance()

	full, err := m.ResolveBackupPath(name)
	if err != nil {
		return err
	}
	_ = os.Remove(full + ".sha256")
	return os.Remove(full)
}

// RestoreFromExisting 从备份列表中的已有快照执行完整校验、自动留存保护快照并原子恢复。
func (m *BackupManager) RestoreFromExisting(name, appVer string) (model.BackupInfo, error) {
	if !m.store.TryLockMaintenance() {
		return model.BackupInfo{}, errors.New("当前已有备份、恢复或导入任务正在执行，请稍后重试")
	}
	defer m.store.UnlockMaintenance()

	fullPath, err := m.ResolveBackupPath(name)
	if err != nil {
		return model.BackupInfo{}, err
	}

	if expectedHash := readSidecarHash(fullPath + ".sha256"); expectedHash != "" {
		actualHash, hErr := sha256File(fullPath)
		if hErr != nil || !strings.EqualFold(expectedHash, actualHash) {
			return model.BackupInfo{}, errors.New("备份归档 SHA-256 校验失败，文件可能已损坏")
		}
	}

	return m.extractVerifyAndSwapUnlocked(fullPath, appVer)
}

// RestoreFromUpload 从上传的本地备份流执行边界防御、完整性检查、保护快照留存并原子恢复。
func (m *BackupManager) RestoreFromUpload(reader io.Reader, appVer string) (model.BackupInfo, error) {
	if !m.store.TryLockMaintenance() {
		return model.BackupInfo{}, errors.New("当前已有备份、恢复或导入任务正在执行，请稍后重试")
	}
	defer m.store.UnlockMaintenance()

	workDir, err := os.MkdirTemp(m.backupDir, ".tmp-upload-*")
	if err != nil {
		return model.BackupInfo{}, fmt.Errorf("创建上传暂存目录失败: %w", err)
	}
	defer func() { _ = os.RemoveAll(workDir) }()

	uploadPath := filepath.Join(workDir, "uploaded.tar.gz")
	outFile, err := os.OpenFile(uploadPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return model.BackupInfo{}, err
	}
	written, copyErr := io.Copy(outFile, io.LimitReader(reader, maxBackupArchiveBytes+1))
	_ = outFile.Close()
	if copyErr != nil {
		return model.BackupInfo{}, fmt.Errorf("读取上传文件失败: %w", copyErr)
	}
	if written == 0 || written > maxBackupArchiveBytes {
		return model.BackupInfo{}, errors.New("上传备份文件为空或超过允许体积上限 (256 MiB)")
	}

	return m.extractVerifyAndSwapUnlocked(uploadPath, appVer)
}

func (m *BackupManager) extractVerifyAndSwapUnlocked(archivePath, appVer string) (model.BackupInfo, error) {
	// 阶段 1：在与主库同一文件系统下创建 staging 目录，先完成全部归档安全与数据库完整性校验。
	dbParent := filepath.Dir(m.store.DBPath())
	stageDir, err := os.MkdirTemp(dbParent, ".tmp-restore-*")
	if err != nil {
		return model.BackupInfo{}, fmt.Errorf("创建恢复暂存目录失败: %w", err)
	}
	defer func() { _ = os.RemoveAll(stageDir) }()

	stagedDBPath, err := extractAndValidateArchive(archivePath, stageDir)
	if err != nil {
		return model.BackupInfo{}, err
	}

	// 阶段 2：恢复前强制自动创建保护快照，确保误操作随时可一键找回。
	protectSnap, err := m.createSnapshotUnlocked(BackupKindPreRestore, "还原前自动留存保护快照", appVer)
	if err != nil {
		return model.BackupInfo{}, fmt.Errorf("创建还原前保护快照失败，已中止还原以保护现网数据: %w", err)
	}

	// 阶段 3：原子切换数据库，内部若失败会自动回滚至现网原库。
	if err := m.store.ReplaceDatabaseAtomically(stagedDBPath); err != nil {
		return protectSnap, err
	}
	return protectSnap, nil
}

func extractAndValidateArchive(archivePath, destDir string) (string, error) {
	f, err := os.Open(archivePath)
	if err != nil {
		return "", err
	}
	defer f.Close()

	// 支持标准 .tar.gz 备份包；若用户直接上传裸 SQLite 文件则明确提示使用标准备份包格式。
	gz, err := gzip.NewReader(f)
	if err != nil {
		return "", errors.New("备份文件不是有效的 Gzip 压缩归档 (.tar.gz)")
	}
	defer gz.Close()

	tr := tar.NewReader(gz)
	seen := make(map[string]bool)
	var totalBytes int64
	memberCount := 0
	var extractedDBPath string
	var meta backupMetadata

	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return "", fmt.Errorf("读取归档成员失败: %w", err)
		}
		memberCount++
		if memberCount > maxBackupArchiveMembers {
			return "", errors.New("备份归档成员数量超出安全上限")
		}
		if hdr.Typeflag != tar.TypeReg && hdr.Typeflag != tar.TypeRegA {
			return "", errors.New("备份归档包含非普通文件（链接或特殊文件已被拒绝）")
		}

		cleanName := filepath.ToSlash(filepath.Clean(hdr.Name))
		cleanName = strings.TrimPrefix(cleanName, "./")
		if cleanName == "" || cleanName == "." || strings.Contains(cleanName, "/") || strings.Contains(cleanName, "..") {
			return "", fmt.Errorf("拒绝非预期的归档路径: %s", hdr.Name)
		}
		if seen[cleanName] {
			return "", fmt.Errorf("拒绝重复的归档成员: %s", cleanName)
		}
		seen[cleanName] = true

		if hdr.Size < 0 || totalBytes+hdr.Size > maxBackupExtractedBytes {
			return "", errors.New("备份归档解压体积超出安全上限")
		}
		totalBytes += hdr.Size

		switch cleanName {
		case "flowmaster.db":
			extractedDBPath = filepath.Join(destDir, "flowmaster.db")
			out, err := os.OpenFile(extractedDBPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
			if err != nil {
				return "", err
			}
			if _, err := io.Copy(out, io.LimitReader(tr, maxBackupExtractedBytes)); err != nil {
				_ = out.Close()
				return "", err
			}
			_ = out.Close()
		case "metadata.json":
			raw, err := io.ReadAll(io.LimitReader(tr, 64*1024))
			if err != nil {
				return "", err
			}
			if err := json.Unmarshal(raw, &meta); err != nil {
				return "", errors.New("备份元数据 metadata.json 格式无效")
			}
		default:
			return "", fmt.Errorf("拒绝未知归档成员: %s", cleanName)
		}
	}

	if extractedDBPath == "" || !seen["metadata.json"] {
		return "", errors.New("备份归档缺少必要的 flowmaster.db 或 metadata.json")
	}

	if meta.DBSHA256 != "" {
		actualDBHash, err := sha256File(extractedDBPath)
		if err != nil || !strings.EqualFold(meta.DBSHA256, actualDBHash) {
			return "", errors.New("备份内数据库 SHA-256 摘要不匹配")
		}
	}

	if err := VerifySQLiteFile(extractedDBPath); err != nil {
		return "", fmt.Errorf("备份数据库未通过完整性与表结构校验: %w", err)
	}
	return extractedDBPath, nil
}

func writeTarGzArchive(destArchive, dbPath string, metaJSON []byte) error {
	outFile, err := os.OpenFile(destArchive, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer outFile.Close()

	gz := gzip.NewWriter(outFile)
	defer gz.Close()

	tw := tar.NewWriter(gz)
	defer tw.Close()

	now := time.Now()
	metaHdr := &tar.Header{
		Name:    "metadata.json",
		Mode:    0o600,
		Size:    int64(len(metaJSON)),
		ModTime: now,
	}
	if err := tw.WriteHeader(metaHdr); err != nil {
		return err
	}
	if _, err := tw.Write(metaJSON); err != nil {
		return err
	}

	dbStat, err := os.Stat(dbPath)
	if err != nil {
		return err
	}
	dbFile, err := os.Open(dbPath)
	if err != nil {
		return err
	}
	defer dbFile.Close()

	dbHdr := &tar.Header{
		Name:    "flowmaster.db",
		Mode:    0o600,
		Size:    dbStat.Size(),
		ModTime: now,
	}
	if err := tw.WriteHeader(dbHdr); err != nil {
		return err
	}
	if _, err := io.Copy(tw, dbFile); err != nil {
		return err
	}
	return nil
}

func (m *BackupManager) pruneSnapshotsUnlocked(maxManual, maxProtect int) {
	list, err := m.ListBackups()
	if err != nil {
		return
	}
	manualCount := 0
	protectCount := 0
	for _, item := range list {
		if item.Kind == BackupKindPreRestore {
			protectCount++
			if maxProtect > 0 && protectCount > maxProtect {
				full := filepath.Join(m.backupDir, item.Name)
				_ = os.Remove(full)
				_ = os.Remove(full + ".sha256")
			}
		} else {
			manualCount++
			if maxManual > 0 && manualCount > maxManual {
				full := filepath.Join(m.backupDir, item.Name)
				_ = os.Remove(full)
				_ = os.Remove(full + ".sha256")
			}
		}
	}
}

func sha256File(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func readSidecarHash(sidecarPath string) string {
	raw, err := os.ReadFile(sidecarPath)
	if err != nil {
		return ""
	}
	fields := strings.Fields(string(raw))
	if len(fields) >= 1 && len(fields[0]) == 64 {
		return fields[0]
	}
	return ""
}

func readArchiveMetadataQuick(archivePath string) (backupMetadata, error) {
	f, err := os.Open(archivePath)
	if err != nil {
		return backupMetadata{}, err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return backupMetadata{}, err
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	for i := 0; i < 4; i++ {
		hdr, err := tr.Next()
		if err != nil {
			break
		}
		if filepath.Clean(hdr.Name) == "metadata.json" {
			raw, err := io.ReadAll(io.LimitReader(tr, 64*1024))
			if err != nil {
				return backupMetadata{}, err
			}
			var meta backupMetadata
			if err := json.Unmarshal(raw, &meta); err == nil {
				return meta, nil
			}
		}
	}
	return backupMetadata{}, errors.New("metadata not found")
}
