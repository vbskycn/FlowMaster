package store

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/vbskycn/flowmaster/internal/model"
)

func TestStoreTrafficAndIdempotentVnstatImport(t *testing.T) {
	tmpDir := t.TempDir()
	st, err := Open(tmpDir)
	if err != nil {
		t.Fatalf("Open failed: %v", err)
	}
	defer st.Close()

	now := time.Date(2026, 11, 25, 14, 12, 0, 0, time.Local)
	err = st.RecordTrafficDeltas(map[string]TrafficDelta{
		"eth0": {RxBytes: 100 * 1024 * 1024, TxBytes: 50 * 1024 * 1024},
	}, now)
	if err != nil {
		t.Fatalf("RecordTrafficDeltas failed: %v", err)
	}

	daily, err := st.QueryStats("eth0", "d", 10)
	if err != nil || len(daily) != 1 {
		t.Fatalf("QueryStats daily failed: %v, len=%d", err, len(daily))
	}
	if daily[0].RxBytes != 100*1024*1024 || daily[0].TxBytes != 50*1024*1024 {
		t.Fatalf("unexpected daily bytes: %+v", daily[0])
	}

	// 幂等合并测试：重复导入同一天数据，取较大值而非重复累加
	dayTs := time.Date(2026, 11, 25, 0, 0, 0, 0, time.Local).Unix()
	importDay := []model.TrafficPoint{
		{Label: "2026-11-25", Timestamp: dayTs, RxBytes: 200 * 1024 * 1024, TxBytes: 40 * 1024 * 1024},
	}
	if _, err := st.MergeVnstatPoints("eth0", nil, nil, importDay, nil); err != nil {
		t.Fatalf("first MergeVnstatPoints failed: %v", err)
	}
	if _, err := st.MergeVnstatPoints("eth0", nil, nil, importDay, nil); err != nil {
		t.Fatalf("second MergeVnstatPoints failed: %v", err)
	}

	after, err := st.QueryDateRange("eth0", "2026-11-25", "2026-11-25")
	if err != nil || len(after) != 1 {
		t.Fatalf("QueryDateRange failed: %v", err)
	}
	if after[0].RxBytes != 200*1024*1024 || after[0].TxBytes != 50*1024*1024 {
		t.Fatalf("expected MAX merge (200MiB rx, 50MiB tx), got %+v", after[0])
	}
}

func TestBackupRestoreLifecycleAndMaliciousArchiveDefense(t *testing.T) {
	tmpDir := t.TempDir()
	st, err := Open(tmpDir)
	if err != nil {
		t.Fatalf("Open failed: %v", err)
	}
	defer st.Close()

	bm, err := NewBackupManager(st, tmpDir)
	if err != nil {
		t.Fatalf("NewBackupManager failed: %v", err)
	}

	// 写入初始配置 v1 并创建手动备份
	sysV1 := model.DefaultSystemSettings()
	sysV1.SiteTitle = "Title Before Restore"
	if err := st.SaveSystemSettings(sysV1); err != nil {
		t.Fatalf("SaveSystemSettings failed: %v", err)
	}

	snap, err := bm.CreateSnapshot(BackupKindManual, "unit-test", "1.1.21")
	if err != nil {
		t.Fatalf("CreateSnapshot failed: %v", err)
	}
	if snap.SHA256 == "" || snap.SizeBytes <= 0 {
		t.Fatalf("invalid snapshot metadata: %+v", snap)
	}

	// 修改配置为 v2
	sysV2 := sysV1
	sysV2.SiteTitle = "Modified Title"
	_ = st.SaveSystemSettings(sysV2)

	// 攻击测试：构造含路径穿越 ../evil.db 的恶意 tar.gz，必须被拒绝且不破坏现网 v2 数据
	var evilBuf bytes.Buffer
	gz := gzip.NewWriter(&evilBuf)
	tw := tar.NewWriter(gz)
	_ = tw.WriteHeader(&tar.Header{Name: "../evil.db", Mode: 0o600, Size: 4, Typeflag: tar.TypeReg})
	_, _ = tw.Write([]byte("evil"))
	_ = tw.Close()
	_ = gz.Close()

	if _, err := bm.RestoreFromUpload(bytes.NewReader(evilBuf.Bytes()), "1.1.21"); err == nil {
		t.Fatalf("expected path traversal archive to be rejected")
	}
	if got := st.GetSystemSettings().SiteTitle; got != "Modified Title" {
		t.Fatalf("live database should remain intact after rejected upload, got %q", got)
	}

	// 正常从快照恢复：应自动留存 pre-restore 保护快照并精确恢复到 v1
	protectSnap, err := bm.RestoreFromExisting(snap.Name, "1.1.21")
	if err != nil {
		t.Fatalf("RestoreFromExisting failed: %v", err)
	}
	if protectSnap.Kind != BackupKindPreRestore {
		t.Fatalf("expected pre_restore protective snapshot, got %+v", protectSnap)
	}
	if got := st.GetSystemSettings().SiteTitle; got != "Title Before Restore" {
		t.Fatalf("expected restored title 'Title Before Restore', got %q", got)
	}

	// 验证上传本地备份文件也能完整恢复保护快照（即回到 Modified Title）
	protectPath, err := bm.ResolveBackupPath(protectSnap.Name)
	if err != nil {
		t.Fatalf("ResolveBackupPath failed: %v", err)
	}
	rawArchive, err := os.ReadFile(filepath.Clean(protectPath))
	if err != nil {
		t.Fatalf("ReadFile failed: %v", err)
	}
	if _, err := bm.RestoreFromUpload(bytes.NewReader(rawArchive), "1.1.21"); err != nil {
		t.Fatalf("RestoreFromUpload failed: %v", err)
	}
	if got := st.GetSystemSettings().SiteTitle; got != "Modified Title" {
		t.Fatalf("expected 'Modified Title' after restoring protective snapshot, got %q", got)
	}
}
