package store

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"

	_ "modernc.org/sqlite"

	"github.com/vbskycn/flowmaster/internal/model"
)

const (
	keySystemSettings = "system_settings"
	keyQuotaConfig    = "quota_config"
	keyAlertConfig    = "alert_config"
	keyAdminPassHash  = "admin_password_hash"
	keyAlertState     = "alert_dedupe_state"
)

// Store 封装 SQLite 连接生命周期、原子换库锁与全部业务持久化方法。
type Store struct {
	mu      sync.RWMutex
	maintMu sync.Mutex
	dbPath  string
	db      *sql.DB
}

// Open 打开或初始化指定目录下的 flowmaster.db。
func Open(dataDir string) (*Store, error) {
	if err := os.MkdirAll(dataDir, 0o750); err != nil {
		return nil, fmt.Errorf("创建数据目录失败: %w", err)
	}
	dbPath := filepath.Join(dataDir, "flowmaster.db")
	db, err := openAndMigrate(dbPath)
	if err != nil {
		return nil, err
	}
	return &Store{
		dbPath: dbPath,
		db:     db,
	}, nil
}

func buildDSN(dbPath string) string {
	return fmt.Sprintf("file:%s?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(ON)", filepath.ToSlash(dbPath))
}

func openAndMigrate(dbPath string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", buildDSN(dbPath))
	if err != nil {
		return nil, fmt.Errorf("打开 SQLite 失败: %w", err)
	}
	// 单写者多读者配合 WAL，限制连接池避免不必要内存占用与锁竞争。
	db.SetMaxOpenConns(4)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(30 * time.Minute)

	schemaSQL := `
CREATE TABLE IF NOT EXISTS kv_settings (
	key TEXT PRIMARY KEY,
	value TEXT NOT NULL,
	updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS interface_meta (
	name TEXT PRIMARY KEY,
	alias TEXT NOT NULL DEFAULT '',
	visible INTEGER,
	updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS traffic_5m (
	iface TEXT NOT NULL,
	bucket_ts INTEGER NOT NULL,
	rx_bytes INTEGER NOT NULL DEFAULT 0,
	tx_bytes INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (iface, bucket_ts)
);

CREATE TABLE IF NOT EXISTS traffic_hourly (
	iface TEXT NOT NULL,
	bucket_ts INTEGER NOT NULL,
	rx_bytes INTEGER NOT NULL DEFAULT 0,
	tx_bytes INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (iface, bucket_ts)
);

CREATE TABLE IF NOT EXISTS traffic_daily (
	iface TEXT NOT NULL,
	day_date TEXT NOT NULL,
	bucket_ts INTEGER NOT NULL,
	rx_bytes INTEGER NOT NULL DEFAULT 0,
	tx_bytes INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (iface, day_date)
);

CREATE TABLE IF NOT EXISTS traffic_monthly (
	iface TEXT NOT NULL,
	month_ym TEXT NOT NULL,
	bucket_ts INTEGER NOT NULL,
	rx_bytes INTEGER NOT NULL DEFAULT 0,
	tx_bytes INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (iface, month_ym)
);

CREATE TABLE IF NOT EXISTS cluster_nodes (
	id TEXT PRIMARY KEY,
	name TEXT NOT NULL,
	group_name TEXT NOT NULL DEFAULT '',
	remark TEXT NOT NULL DEFAULT '',
	token_hash TEXT NOT NULL UNIQUE,
	token_mask TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	last_seen INTEGER NOT NULL DEFAULT 0,
	last_ip TEXT NOT NULL DEFAULT '',
	version TEXT NOT NULL DEFAULT '',
	hostname TEXT NOT NULL DEFAULT '',
	os TEXT NOT NULL DEFAULT '',
	arch TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS idx_traffic_5m_ts ON traffic_5m(bucket_ts);
CREATE INDEX IF NOT EXISTS idx_traffic_hourly_ts ON traffic_hourly(bucket_ts);
CREATE INDEX IF NOT EXISTS idx_traffic_daily_date ON traffic_daily(day_date);
`
	if _, err := db.Exec(schemaSQL); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("初始化数据库表结构失败: %w", err)
	}
	return db, nil
}

// VerifySQLiteFile 在独立只读连接中对候选备份库执行 PRAGMA integrity_check 及核心表结构检查。
func VerifySQLiteFile(candidatePath string) error {
	info, err := os.Stat(candidatePath)
	if err != nil || info.IsDir() || info.Size() == 0 {
		return errors.New("数据库文件不存在或为空")
	}
	db, err := sql.Open("sqlite", fmt.Sprintf("file:%s?mode=ro&_pragma=busy_timeout(3000)", filepath.ToSlash(candidatePath)))
	if err != nil {
		return fmt.Errorf("无法打开候选数据库: %w", err)
	}
	defer db.Close()

	var integrity string
	if err := db.QueryRow("PRAGMA integrity_check").Scan(&integrity); err != nil {
		return fmt.Errorf("执行 integrity_check 失败: %w", err)
	}
	if integrity != "ok" {
		return fmt.Errorf("数据库完整性校验未通过: %s", integrity)
	}

	requiredTables := []string{"kv_settings", "traffic_5m", "traffic_hourly", "traffic_daily", "traffic_monthly"}
	for _, tbl := range requiredTables {
		var name string
		err := db.QueryRow("SELECT name FROM sqlite_master WHERE type='table' AND name=?", tbl).Scan(&name)
		if err != nil || name != tbl {
			return fmt.Errorf("缺少核心数据表 %s", tbl)
		}
	}
	return nil
}

// TryLockMaintenance 尝试获取备份/恢复/导入共享的非阻塞维护互斥锁。
func (s *Store) TryLockMaintenance() bool {
	return s.maintMu.TryLock()
}

// UnlockMaintenance 释放维护互斥锁。
func (s *Store) UnlockMaintenance() {
	s.maintMu.Unlock()
}

// DBPath 返回主数据库文件路径。
func (s *Store) DBPath() string {
	return s.dbPath
}

// DBFileSize 返回当前数据库文件（含 WAL）的总字节占用。
func (s *Store) DBFileSize() int64 {
	var total int64
	for _, suffix := range []string{"", "-wal", "-shm"} {
		if info, err := os.Stat(s.dbPath + suffix); err == nil {
			total += info.Size()
		}
	}
	return total
}

// Close 关闭底层数据库连接。
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db != nil {
		_, _ = s.db.Exec("PRAGMA wal_checkpoint(TRUNCATE)")
		err := s.db.Close()
		s.db = nil
		return err
	}
	return nil
}

// VacuumInto 在线生成一致性数据库快照副本。
func (s *Store) VacuumInto(destPath string) error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return errors.New("数据库未打开")
	}
	_ = os.Remove(destPath)
	_, err := s.db.Exec("VACUUM INTO ?", destPath)
	return err
}

// ReplaceDatabaseAtomically 在写锁保护下将主数据库原子替换为已校验的 stagedDBPath，失败自动回滚现网数据。
func (s *Store) ReplaceDatabaseAtomically(stagedDBPath string) error {
	if err := VerifySQLiteFile(stagedDBPath); err != nil {
		return err
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	rollbackPath := fmt.Sprintf("%s.rollback.%d", s.dbPath, time.Now().UnixNano())
	if s.db != nil {
		_, _ = s.db.Exec("PRAGMA wal_checkpoint(TRUNCATE)")
		_ = s.db.Close()
		s.db = nil
	}

	// 移除旧 WAL/SHM，保留原主库为同目录回滚副本
	_ = os.Remove(s.dbPath + "-wal")
	_ = os.Remove(s.dbPath + "-shm")

	hadOriginal := false
	if _, err := os.Stat(s.dbPath); err == nil {
		if err := os.Rename(s.dbPath, rollbackPath); err != nil {
			reopened, _ := openAndMigrate(s.dbPath)
			s.db = reopened
			return fmt.Errorf("保存回滚副本失败: %w", err)
		}
		hadOriginal = true
	}

	restoreOriginal := func(cause error) error {
		_ = os.Remove(s.dbPath)
		_ = os.Remove(s.dbPath + "-wal")
		_ = os.Remove(s.dbPath + "-shm")
		if hadOriginal {
			_ = os.Rename(rollbackPath, s.dbPath)
		}
		if reopened, err := openAndMigrate(s.dbPath); err == nil {
			s.db = reopened
		}
		return cause
	}

	if err := os.Rename(stagedDBPath, s.dbPath); err != nil {
		return restoreOriginal(fmt.Errorf("切换新数据库文件失败: %w", err))
	}
	_ = os.Chmod(s.dbPath, 0o640)

	newDB, err := openAndMigrate(s.dbPath)
	if err != nil {
		return restoreOriginal(fmt.Errorf("打开恢复后的数据库失败: %w", err))
	}
	var check string
	if err := newDB.QueryRow("PRAGMA integrity_check").Scan(&check); err != nil || check != "ok" {
		_ = newDB.Close()
		return restoreOriginal(errors.New("恢复后数据库自检失败，已自动回滚原数据"))
	}

	s.db = newDB
	if hadOriginal {
		_ = os.Remove(rollbackPath)
	}
	return nil
}

// TrafficDelta 表示单个网卡在采样窗口内新增的收发字节数。
type TrafficDelta struct {
	RxBytes int64
	TxBytes int64
}

// RecordTrafficDeltas 在单个事务内将多网卡增量同步写入 5m / hourly / daily / monthly 四个粒度表。
func (s *Store) RecordTrafficDeltas(deltas map[string]TrafficDelta, now time.Time) error {
	if len(deltas) == 0 {
		return nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return errors.New("数据库已关闭")
	}

	localNow := now.In(time.Local)
	bucket5m := time.Date(localNow.Year(), localNow.Month(), localNow.Day(), localNow.Hour(), (localNow.Minute()/5)*5, 0, 0, time.Local).Unix()
	bucketHour := time.Date(localNow.Year(), localNow.Month(), localNow.Day(), localNow.Hour(), 0, 0, 0, time.Local).Unix()
	dayDate := localNow.Format("2006-01-02")
	bucketDay := time.Date(localNow.Year(), localNow.Month(), localNow.Day(), 0, 0, 0, 0, time.Local).Unix()
	monthYM := localNow.Format("2006-01")
	bucketMonth := time.Date(localNow.Year(), localNow.Month(), 1, 0, 0, 0, 0, time.Local).Unix()

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	for iface, d := range deltas {
		if d.RxBytes <= 0 && d.TxBytes <= 0 {
			continue
		}
		if _, err := tx.Exec(`
			INSERT INTO traffic_5m (iface, bucket_ts, rx_bytes, tx_bytes)
			VALUES (?, ?, ?, ?)
			ON CONFLICT(iface, bucket_ts) DO UPDATE SET
				rx_bytes = rx_bytes + excluded.rx_bytes,
				tx_bytes = tx_bytes + excluded.tx_bytes`,
			iface, bucket5m, d.RxBytes, d.TxBytes,
		); err != nil {
			return err
		}

		if _, err := tx.Exec(`
			INSERT INTO traffic_hourly (iface, bucket_ts, rx_bytes, tx_bytes)
			VALUES (?, ?, ?, ?)
			ON CONFLICT(iface, bucket_ts) DO UPDATE SET
				rx_bytes = rx_bytes + excluded.rx_bytes,
				tx_bytes = tx_bytes + excluded.tx_bytes`,
			iface, bucketHour, d.RxBytes, d.TxBytes,
		); err != nil {
			return err
		}

		if _, err := tx.Exec(`
			INSERT INTO traffic_daily (iface, day_date, bucket_ts, rx_bytes, tx_bytes)
			VALUES (?, ?, ?, ?, ?)
			ON CONFLICT(iface, day_date) DO UPDATE SET
				rx_bytes = rx_bytes + excluded.rx_bytes,
				tx_bytes = tx_bytes + excluded.tx_bytes`,
			iface, dayDate, bucketDay, d.RxBytes, d.TxBytes,
		); err != nil {
			return err
		}

		if _, err := tx.Exec(`
			INSERT INTO traffic_monthly (iface, month_ym, bucket_ts, rx_bytes, tx_bytes)
			VALUES (?, ?, ?, ?, ?)
			ON CONFLICT(iface, month_ym) DO UPDATE SET
				rx_bytes = rx_bytes + excluded.rx_bytes,
				tx_bytes = tx_bytes + excluded.tx_bytes`,
			iface, monthYM, bucketMonth, d.RxBytes, d.TxBytes,
		); err != nil {
			return err
		}
	}
	return tx.Commit()
}

// MergeVnstatPoints 幂等合并外部导入的流量序列（同一时间桶取较大值，防止重复导入翻倍）。
func (s *Store) MergeVnstatPoints(iface string, fiveMin, hourly, daily, monthly []model.TrafficPoint) (int, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return 0, errors.New("数据库已关闭")
	}

	tx, err := s.db.Begin()
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()

	merged := 0
	for _, p := range fiveMin {
		if _, err := tx.Exec(`
			INSERT INTO traffic_5m (iface, bucket_ts, rx_bytes, tx_bytes)
			VALUES (?, ?, ?, ?)
			ON CONFLICT(iface, bucket_ts) DO UPDATE SET
				rx_bytes = MAX(rx_bytes, excluded.rx_bytes),
				tx_bytes = MAX(tx_bytes, excluded.tx_bytes)`,
			iface, p.Timestamp, p.RxBytes, p.TxBytes,
		); err != nil {
			return 0, err
		}
		merged++
	}
	for _, p := range hourly {
		if _, err := tx.Exec(`
			INSERT INTO traffic_hourly (iface, bucket_ts, rx_bytes, tx_bytes)
			VALUES (?, ?, ?, ?)
			ON CONFLICT(iface, bucket_ts) DO UPDATE SET
				rx_bytes = MAX(rx_bytes, excluded.rx_bytes),
				tx_bytes = MAX(tx_bytes, excluded.tx_bytes)`,
			iface, p.Timestamp, p.RxBytes, p.TxBytes,
		); err != nil {
			return 0, err
		}
		merged++
	}
	for _, p := range daily {
		dayDate := time.Unix(p.Timestamp, 0).In(time.Local).Format("2006-01-02")
		if len(p.Label) == 10 && p.Label[4] == '-' {
			dayDate = p.Label
		}
		if _, err := tx.Exec(`
			INSERT INTO traffic_daily (iface, day_date, bucket_ts, rx_bytes, tx_bytes)
			VALUES (?, ?, ?, ?, ?)
			ON CONFLICT(iface, day_date) DO UPDATE SET
				rx_bytes = MAX(rx_bytes, excluded.rx_bytes),
				tx_bytes = MAX(tx_bytes, excluded.tx_bytes)`,
			iface, dayDate, p.Timestamp, p.RxBytes, p.TxBytes,
		); err != nil {
			return 0, err
		}
		merged++
	}
	for _, p := range monthly {
		monthYM := time.Unix(p.Timestamp, 0).In(time.Local).Format("2006-01")
		if len(p.Label) == 7 && p.Label[4] == '-' {
			monthYM = p.Label
		}
		if _, err := tx.Exec(`
			INSERT INTO traffic_monthly (iface, month_ym, bucket_ts, rx_bytes, tx_bytes)
			VALUES (?, ?, ?, ?, ?)
			ON CONFLICT(iface, month_ym) DO UPDATE SET
				rx_bytes = MAX(rx_bytes, excluded.rx_bytes),
				tx_bytes = MAX(tx_bytes, excluded.tx_bytes)`,
			iface, monthYM, p.Timestamp, p.RxBytes, p.TxBytes,
		); err != nil {
			return 0, err
		}
		merged++
	}

	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return merged, nil
}

// QueryStats 从 SQLite 查询指定周期序列（5 / h / d / m / y）。
func (s *Store) QueryStats(iface, period string, limit int) ([]model.TrafficPoint, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return nil, errors.New("数据库已关闭")
	}

	switch period {
	case "5":
		if limit <= 0 {
			limit = 288 // 默认最近 24 小时 (288 * 5m)
		}
		rows, err := s.db.Query(`
			SELECT bucket_ts, rx_bytes, tx_bytes FROM traffic_5m
			WHERE iface = ? ORDER BY bucket_ts DESC LIMIT ?`, iface, limit)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var pts []model.TrafficPoint
		for rows.Next() {
			var ts, rx, tx int64
			if err := rows.Scan(&ts, &rx, &tx); err != nil {
				return nil, err
			}
			tm := time.Unix(ts, 0).In(time.Local)
			tot := rx + tx
			pts = append(pts, model.TrafficPoint{
				Label:      tm.Format("15:04"),
				Timestamp:  ts,
				RxBytes:    rx,
				TxBytes:    tx,
				TotalBytes: tot,
				AvgBps:     float64(tot*8) / 300.0,
			})
		}
		reversePoints(pts)
		return pts, nil

	case "h":
		if limit <= 0 {
			limit = 72 // 默认最近 72 小时
		}
		rows, err := s.db.Query(`
			SELECT bucket_ts, rx_bytes, tx_bytes FROM traffic_hourly
			WHERE iface = ? ORDER BY bucket_ts DESC LIMIT ?`, iface, limit)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var pts []model.TrafficPoint
		for rows.Next() {
			var ts, rx, tx int64
			if err := rows.Scan(&ts, &rx, &tx); err != nil {
				return nil, err
			}
			tm := time.Unix(ts, 0).In(time.Local)
			tot := rx + tx
			pts = append(pts, model.TrafficPoint{
				Label:      tm.Format("01-02 15:00"),
				Timestamp:  ts,
				RxBytes:    rx,
				TxBytes:    tx,
				TotalBytes: tot,
				AvgBps:     float64(tot*8) / 3600.0,
			})
		}
		reversePoints(pts)
		return pts, nil

	case "d":
		if limit <= 0 {
			limit = 90 // 默认最近 90 天
		}
		rows, err := s.db.Query(`
			SELECT day_date, bucket_ts, rx_bytes, tx_bytes FROM traffic_daily
			WHERE iface = ? ORDER BY day_date DESC LIMIT ?`, iface, limit)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var pts []model.TrafficPoint
		for rows.Next() {
			var label string
			var ts, rx, tx int64
			if err := rows.Scan(&label, &ts, &rx, &tx); err != nil {
				return nil, err
			}
			tot := rx + tx
			pts = append(pts, model.TrafficPoint{
				Label:      label,
				Timestamp:  ts,
				RxBytes:    rx,
				TxBytes:    tx,
				TotalBytes: tot,
				AvgBps:     float64(tot*8) / 86400.0,
			})
		}
		reversePoints(pts)
		return pts, nil

	case "m":
		if limit <= 0 {
			limit = 36
		}
		rows, err := s.db.Query(`
			SELECT month_ym, bucket_ts, rx_bytes, tx_bytes FROM traffic_monthly
			WHERE iface = ? ORDER BY month_ym DESC LIMIT ?`, iface, limit)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var pts []model.TrafficPoint
		for rows.Next() {
			var label string
			var ts, rx, tx int64
			if err := rows.Scan(&label, &ts, &rx, &tx); err != nil {
				return nil, err
			}
			tm := time.Unix(ts, 0).In(time.Local)
			days := time.Date(tm.Year(), tm.Month()+1, 0, 0, 0, 0, 0, time.Local).Day()
			tot := rx + tx
			pts = append(pts, model.TrafficPoint{
				Label:      label,
				Timestamp:  ts,
				RxBytes:    rx,
				TxBytes:    tx,
				TotalBytes: tot,
				AvgBps:     float64(tot*8) / (float64(days) * 86400.0),
			})
		}
		reversePoints(pts)
		return pts, nil

	case "y":
		rows, err := s.db.Query(`
			SELECT substr(month_ym, 1, 4) AS yr, SUM(rx_bytes), SUM(tx_bytes)
			FROM traffic_monthly
			WHERE iface = ?
			GROUP BY yr
			ORDER BY yr ASC`, iface)
		if err != nil {
			return nil, err
		}
		defer rows.Close()
		var pts []model.TrafficPoint
		for rows.Next() {
			var yr string
			var rx, tx int64
			if err := rows.Scan(&yr, &rx, &tx); err != nil {
				return nil, err
			}
			tm, _ := time.ParseInLocation("2006", yr, time.Local)
			days := 365
			yNum := tm.Year()
			if (yNum%4 == 0 && yNum%100 != 0) || yNum%400 == 0 {
				days = 366
			}
			tot := rx + tx
			pts = append(pts, model.TrafficPoint{
				Label:      yr,
				Timestamp:  tm.Unix(),
				RxBytes:    rx,
				TxBytes:    tx,
				TotalBytes: tot,
				AvgBps:     float64(tot*8) / (float64(days) * 86400.0),
			})
		}
		return pts, nil
	default:
		return nil, fmt.Errorf("不支持的统计周期: %s", period)
	}
}

func reversePoints(pts []model.TrafficPoint) {
	for i, j := 0, len(pts)-1; i < j; i, j = i+1, j-1 {
		pts[i], pts[j] = pts[j], pts[i]
	}
}

// QueryDateRange 查询指定起止日期（含首尾 YYYY-MM-DD）的按天流量明细。
func (s *Store) QueryDateRange(iface, startDate, endDate string) ([]model.TrafficPoint, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return nil, errors.New("数据库已关闭")
	}
	rows, err := s.db.Query(`
		SELECT day_date, bucket_ts, rx_bytes, tx_bytes
		FROM traffic_daily
		WHERE iface = ? AND day_date >= ? AND day_date <= ?
		ORDER BY day_date ASC`, iface, startDate, endDate)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var pts []model.TrafficPoint
	for rows.Next() {
		var label string
		var ts, rx, tx int64
		if err := rows.Scan(&label, &ts, &rx, &tx); err != nil {
			return nil, err
		}
		tot := rx + tx
		pts = append(pts, model.TrafficPoint{
			Label:      label,
			Timestamp:  ts,
			RxBytes:    rx,
			TxBytes:    tx,
			TotalBytes: tot,
			AvgBps:     float64(tot*8) / 86400.0,
		})
	}
	return pts, nil
}

// SumDailyInRange 汇总一个或多个网卡在指定日期闭区间内的累计收发字节数。
func (s *Store) SumDailyInRange(ifaces []string, startDate, endDate string) (rxTotal, txTotal int64, err error) {
	if len(ifaces) == 0 {
		return 0, 0, nil
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return 0, 0, errors.New("数据库已关闭")
	}

	for _, iface := range ifaces {
		var rx, tx sql.NullInt64
		qErr := s.db.QueryRow(`
			SELECT SUM(rx_bytes), SUM(tx_bytes)
			FROM traffic_daily
			WHERE iface = ? AND day_date >= ? AND day_date <= ?`,
			iface, startDate, endDate,
		).Scan(&rx, &tx)
		if qErr != nil {
			return 0, 0, qErr
		}
		rxTotal += rx.Int64
		txTotal += tx.Int64
	}
	return rxTotal, txTotal, nil
}

// ListTrackedInterfaces 返回 SQLite 中已有流量记录的所有网卡集合。
func (s *Store) ListTrackedInterfaces() ([]string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return nil, errors.New("数据库已关闭")
	}
	rows, err := s.db.Query(`
		SELECT DISTINCT iface FROM (
			SELECT iface FROM traffic_daily
			UNION
			SELECT iface FROM traffic_5m
		)`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var out []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err == nil && name != "" {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out, nil
}

// PruneExpired 按配置保留天数清理过期细粒度数据，防止长期运行体积膨胀。
func (s *Store) PruneExpired(settings model.SystemSettings, now time.Time) error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return nil
	}
	if settings.Retention5mDays > 0 {
		cutoff := now.AddDate(0, 0, -settings.Retention5mDays).Unix()
		_, _ = s.db.Exec("DELETE FROM traffic_5m WHERE bucket_ts < ?", cutoff)
	}
	if settings.RetentionHourlyDays > 0 {
		cutoff := now.AddDate(0, 0, -settings.RetentionHourlyDays).Unix()
		_, _ = s.db.Exec("DELETE FROM traffic_hourly WHERE bucket_ts < ?", cutoff)
	}
	if settings.RetentionDailyDays > 0 {
		cutoffDate := now.In(time.Local).AddDate(0, 0, -settings.RetentionDailyDays).Format("2006-01-02")
		_, _ = s.db.Exec("DELETE FROM traffic_daily WHERE day_date < ?", cutoffDate)
	}
	return nil
}

// ResetInterfaceTraffic 清空指定网卡（或全部内置 SQLite 统计）数据；调用前上层须先创建保护备份。
func (s *Store) ResetInterfaceTraffic(iface string) error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return errors.New("数据库已关闭")
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	tables := []string{"traffic_5m", "traffic_hourly", "traffic_daily", "traffic_monthly"}
	for _, tbl := range tables {
		if iface == "" || iface == "__all__" {
			if _, err := tx.Exec("DELETE FROM " + tbl); err != nil {
				return err
			}
		} else {
			if _, err := tx.Exec("DELETE FROM "+tbl+" WHERE iface = ?", iface); err != nil {
				return err
			}
		}
	}
	return tx.Commit()
}

func (s *Store) getJSONSetting(key string, target any) (bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return false, errors.New("数据库已关闭")
	}
	var raw string
	err := s.db.QueryRow("SELECT value FROM kv_settings WHERE key = ?", key).Scan(&raw)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if err := json.Unmarshal([]byte(raw), target); err != nil {
		return false, err
	}
	return true, nil
}

func (s *Store) setJSONSetting(key string, val any) error {
	encoded, err := json.Marshal(val)
	if err != nil {
		return err
	}
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return errors.New("数据库已关闭")
	}
	_, err = s.db.Exec(`
		INSERT INTO kv_settings (key, value, updated_at)
		VALUES (?, ?, ?)
		ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
		key, string(encoded), time.Now().Unix(),
	)
	return err
}

func (s *Store) GetSystemSettings() model.SystemSettings {
	cfg := model.DefaultSystemSettings()
	hasExplicitHubMode := false

	s.mu.RLock()
	if s.db != nil {
		var raw string
		if err := s.db.QueryRow("SELECT value FROM kv_settings WHERE key = ?", keySystemSettings).Scan(&raw); err == nil {
			_ = json.Unmarshal([]byte(raw), &cfg)
			var rawMap map[string]json.RawMessage
			if json.Unmarshal([]byte(raw), &rawMap) == nil {
				_, hasExplicitHubMode = rawMap["hubModeEnabled"]
			}
		}
		// 兼容旧版主控平滑升级：若从未显式配置过 hubModeEnabled，但库中已注册过被控节点，则自动延续开启主控模式。
		if !hasExplicitHubMode && !cfg.HubModeEnabled {
			var nodeCount int
			if err := s.db.QueryRow("SELECT COUNT(1) FROM cluster_nodes").Scan(&nodeCount); err == nil && nodeCount > 0 {
				cfg.HubModeEnabled = true
			}
		}
	}
	s.mu.RUnlock()

	if cfg.DataSourceMode != model.SourceModeHybrid && cfg.DataSourceMode != model.SourceModeSQLite && cfg.DataSourceMode != model.SourceModeVnstat {
		cfg.DataSourceMode = model.SourceModeHybrid
	}
	if cfg.SiteTitle == "" {
		cfg.SiteTitle = "FlowMaster 流量监控"
	}
	if cfg.MaxBackups < 1 {
		cfg.MaxBackups = 20
	}
	if cfg.MaxProtectSnapshots < 1 {
		cfg.MaxProtectSnapshots = 10
	}
	return cfg
}

func (s *Store) SaveSystemSettings(cfg model.SystemSettings) error {
	return s.setJSONSetting(keySystemSettings, cfg)
}

func (s *Store) GetQuotaConfig() model.QuotaConfig {
	cfg := model.DefaultQuotaConfig()
	_, _ = s.getJSONSetting(keyQuotaConfig, &cfg)
	if cfg.ResetDay < 1 || cfg.ResetDay > 31 {
		cfg.ResetDay = 1
	}
	if cfg.WarnPercent < 1 || cfg.WarnPercent > 99 {
		cfg.WarnPercent = 80
	}
	return cfg
}

func (s *Store) SaveQuotaConfig(cfg model.QuotaConfig) error {
	return s.setJSONSetting(keyQuotaConfig, cfg)
}

func (s *Store) GetAlertConfig() model.AlertConfig {
	cfg := model.AlertConfig{
		NotifyOnWarn:  true,
		NotifyOnLimit: true,
	}
	_, _ = s.getJSONSetting(keyAlertConfig, &cfg)
	return cfg
}

func (s *Store) SaveAlertConfig(cfg model.AlertConfig) error {
	return s.setJSONSetting(keyAlertConfig, cfg)
}

func (s *Store) GetAdminPasswordHash() string {
	var hash string
	_, _ = s.getJSONSetting(keyAdminPassHash, &hash)
	return hash
}

func (s *Store) SaveAdminPasswordHash(hash string) error {
	return s.setJSONSetting(keyAdminPassHash, hash)
}

func (s *Store) GetAlertDedupeState() map[string]int64 {
	state := make(map[string]int64)
	_, _ = s.getJSONSetting(keyAlertState, &state)
	return state
}

func (s *Store) SaveAlertDedupeState(state map[string]int64) error {
	return s.setJSONSetting(keyAlertState, state)
}

// GetInterfaceOverrides 读取所有管理员自定义的网卡别名与显隐覆盖规则。
func (s *Store) GetInterfaceOverrides() (map[string]model.InterfaceOverride, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return nil, errors.New("数据库已关闭")
	}
	rows, err := s.db.Query("SELECT name, alias, visible FROM interface_meta")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make(map[string]model.InterfaceOverride)
	for rows.Next() {
		var name, alias string
		var vis sql.NullInt64
		if err := rows.Scan(&name, &alias, &vis); err != nil {
			continue
		}
		ov := model.InterfaceOverride{
			Name:  name,
			Alias: alias,
		}
		if vis.Valid {
			v := vis.Int64 != 0
			ov.Visible = &v
		}
		out[name] = ov
	}
	return out, nil
}

// SaveInterfaceOverride 更新单个网卡的备注别名与显隐状态。
func (s *Store) SaveInterfaceOverride(ov model.InterfaceOverride) error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return errors.New("数据库已关闭")
	}
	var vis any
	if ov.Visible != nil {
		if *ov.Visible {
			vis = 1
		} else {
			vis = 0
		}
	}
	_, err := s.db.Exec(`
		INSERT INTO interface_meta (name, alias, visible, updated_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(name) DO UPDATE SET
			alias = excluded.alias,
			visible = excluded.visible,
			updated_at = excluded.updated_at`,
		ov.Name, ov.Alias, vis, time.Now().Unix(),
	)
	return err
}

// ConfigExportBundle 用于跨环境导出/导入非敏感配置（不含密钥与密码哈希）。
type ConfigExportBundle struct {
	ExportedAt string                    `json:"exportedAt"`
	AppVersion string                    `json:"appVersion"`
	System     model.SystemSettings      `json:"system"`
	Quota      model.QuotaConfig         `json:"quota"`
	Interfaces []model.InterfaceOverride `json:"interfaces"`
}

func (s *Store) ExportConfig(appVer string) (ConfigExportBundle, error) {
	ovs, err := s.GetInterfaceOverrides()
	if err != nil {
		return ConfigExportBundle{}, err
	}
	list := make([]model.InterfaceOverride, 0, len(ovs))
	for _, v := range ovs {
		list = append(list, v)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Name < list[j].Name })
	return ConfigExportBundle{
		ExportedAt: time.Now().Format(time.RFC3339),
		AppVersion: appVer,
		System:     s.GetSystemSettings(),
		Quota:      s.GetQuotaConfig(),
		Interfaces: list,
	}, nil
}

func (s *Store) ImportConfig(bundle ConfigExportBundle) error {
	if err := s.SaveSystemSettings(bundle.System); err != nil {
		return err
	}
	if err := s.SaveQuotaConfig(bundle.Quota); err != nil {
		return err
	}
	for _, ov := range bundle.Interfaces {
		if ov.Name != "" {
			if err := s.SaveInterfaceOverride(ov); err != nil {
				return err
			}
		}
	}
	return nil
}
