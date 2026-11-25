package model

// 数据源引擎模式常量。
const (
	SourceModeHybrid = "hybrid"
	SourceModeSQLite = "sqlite"
	SourceModeVnstat = "vnstat"
)

// 流量计费方向常量。
const (
	QuotaDirBoth = "both" // 双向合计 (RX + TX)
	QuotaDirTX   = "tx"   // 仅出站上行 (TX)
	QuotaDirRX   = "rx"   // 仅入站下行 (RX)
	QuotaDirMax  = "max"  // 单向取较大值 max(RX, TX)
)

// InterfaceInfo 表示单个网络接口的元数据与实时状态。
type InterfaceInfo struct {
	Name          string   `json:"name"`
	Alias         string   `json:"alias"`
	IsVirtual     bool     `json:"isVirtual"`
	Visible       bool     `json:"visible"`
	OperState     string   `json:"operState"`
	SpeedMbps     int      `json:"speedMbps"`
	MAC           string   `json:"mac"`
	IPv4          []string `json:"ipv4"`
	RxBytesKernel uint64   `json:"rxBytesKernel"`
	TxBytesKernel uint64   `json:"txBytesKernel"`
	HasSQLiteData bool     `json:"hasSqliteData"`
	HasVnstatData bool     `json:"hasVnstatData"`
}

// InterfaceOverride 存储管理员对特定网卡的显隐与备注配置。
type InterfaceOverride struct {
	Name    string `json:"name"`
	Alias   string `json:"alias"`
	Visible *bool  `json:"visible,omitempty"`
}

// RealtimeSample 表示单次实时流量与包速率采样结果。
type RealtimeSample struct {
	Interface       string  `json:"interface"`
	Timestamp       int64   `json:"timestamp"`
	RxBytesPerSec   float64 `json:"rxBytesPerSec"`
	TxBytesPerSec   float64 `json:"txBytesPerSec"`
	RxMbps          float64 `json:"rxMbps"`
	TxMbps          float64 `json:"txMbps"`
	RxPacketsPerSec float64 `json:"rxPacketsPerSec"`
	TxPacketsPerSec float64 `json:"txPacketsPerSec"`
	Stale           bool    `json:"stale"`
	AgeMs           int64   `json:"ageMs"`
	Source          string  `json:"source"`
}

// TrafficPoint 表示时间序列中的单个聚合桶（精确到字节）。
type TrafficPoint struct {
	Label      string  `json:"label"`
	Timestamp  int64   `json:"timestamp"`
	RxBytes    int64   `json:"rxBytes"`
	TxBytes    int64   `json:"txBytes"`
	TotalBytes int64   `json:"totalBytes"`
	AvgBps     float64 `json:"avgBps"`
}

// TrafficSummary 汇总当前查询区间内的总量与峰值。
type TrafficSummary struct {
	TotalRxBytes int64   `json:"totalRxBytes"`
	TotalTxBytes int64   `json:"totalTxBytes"`
	TotalBytes   int64   `json:"totalBytes"`
	PeakRxBytes  int64   `json:"peakRxBytes"`
	PeakTxBytes  int64   `json:"peakTxBytes"`
	PeakLabel    string  `json:"peakLabel"`
	AvgBps       float64 `json:"avgBps"`
	PointCount   int     `json:"pointCount"`
}

// StatsQueryResult 为现代结构化统计查询结果。
type StatsQueryResult struct {
	Interface string         `json:"interface"`
	Period    string         `json:"period"`
	Source    string         `json:"source"`
	Points    []TrafficPoint `json:"points"`
	Summary   TrafficSummary `json:"summary"`
	UpdatedAt int64          `json:"updatedAt"`
}

// SystemSettings 为可在后台可视化调整的通用系统参数。
type SystemSettings struct {
	SiteTitle             string `json:"siteTitle"`
	RequireLoginForView   bool   `json:"requireLoginForView"`
	DataSourceMode        string `json:"dataSourceMode"`
	HideVirtualInterfaces bool   `json:"hideVirtualInterfaces"`
	DefaultInterface      string `json:"defaultInterface"`
	Retention5mDays       int    `json:"retention5mDays"`
	RetentionHourlyDays   int    `json:"retentionHourlyDays"`
	RetentionDailyDays    int    `json:"retentionDailyDays"`
	MaxBackups            int    `json:"maxBackups"`
	MaxProtectSnapshots   int    `json:"maxProtectSnapshots"`
}

// DefaultSystemSettings 返回开箱即用的安全默认系统参数。
func DefaultSystemSettings() SystemSettings {
	return SystemSettings{
		SiteTitle:             "FlowMaster 流量监控",
		RequireLoginForView:   false,
		DataSourceMode:        SourceModeHybrid,
		HideVirtualInterfaces: true,
		DefaultInterface:      "",
		Retention5mDays:       7,
		RetentionHourlyDays:   90,
		RetentionDailyDays:    3660,
		MaxBackups:            20,
		MaxProtectSnapshots:   10,
	}
}

// QuotaConfig 定义 VPS 月度流量账单周期与额度规则。
type QuotaConfig struct {
	Enabled           bool   `json:"enabled"`
	Interface         string `json:"interface"` // 空表示跟随默认物理网卡，"__all__" 表示汇总所有可见网卡
	ResetDay          int    `json:"resetDay"`  // 1..31
	Direction         string `json:"direction"` // both | tx | rx | max
	MonthlyLimitBytes int64  `json:"monthlyLimitBytes"`
	WarnPercent       int    `json:"warnPercent"` // 1..99
}

// DefaultQuotaConfig 返回默认月度配额配置。
func DefaultQuotaConfig() QuotaConfig {
	return QuotaConfig{
		Enabled:           false,
		Interface:         "",
		ResetDay:          1,
		Direction:         QuotaDirBoth,
		MonthlyLimitBytes: 1000 * 1024 * 1024 * 1024, // 默认示例 1000 GiB
		WarnPercent:       80,
	}
}

// QuotaStatus 表示实时计算出的当前计费周期流量使用进度。
type QuotaStatus struct {
	Enabled        bool    `json:"enabled"`
	Interface      string  `json:"interface"`
	Direction      string  `json:"direction"`
	ResetDay       int     `json:"resetDay"`
	CycleStart     string  `json:"cycleStart"`
	CycleEnd       string  `json:"cycleEnd"`
	DaysElapsed    float64 `json:"daysElapsed"`
	DaysTotal      int     `json:"daysTotal"`
	RxBytes        int64   `json:"rxBytes"`
	TxBytes        int64   `json:"txBytes"`
	UsedBytes      int64   `json:"usedBytes"`
	LimitBytes     int64   `json:"limitBytes"`
	RemainingBytes int64   `json:"remainingBytes"`
	UsagePercent   float64 `json:"usagePercent"`
	ProjectedBytes int64   `json:"projectedBytes"`
	WarnPercent    int     `json:"warnPercent"`
	OverWarn       bool    `json:"overWarn"`
	OverLimit      bool    `json:"overLimit"`
}

// AlertConfig 存储外部告警推送配置（含敏感凭据，仅服务端内部使用）。
type AlertConfig struct {
	Enabled             bool   `json:"enabled"`
	WebhookURL          string `json:"webhookUrl"`
	WebhookSecret       string `json:"webhookSecret"`
	TelegramBotToken    string `json:"telegramBotToken"`
	TelegramChatID      string `json:"telegramChatId"`
	AllowPrivateNetwork bool   `json:"allowPrivateNetwork"`
	NotifyOnWarn        bool   `json:"notifyOnWarn"`
	NotifyOnLimit       bool   `json:"notifyOnLimit"`
}

// AlertConfigView 为面向前端展示的脱敏配置视图（密钥只写不回显）。
type AlertConfigView struct {
	Enabled               bool   `json:"enabled"`
	WebhookURL            string `json:"webhookUrl"`
	HasWebhookSecret      bool   `json:"hasWebhookSecret"`
	WebhookSecretMask     string `json:"webhookSecretMask"`
	HasTelegramBotToken   bool   `json:"hasTelegramBotToken"`
	TelegramBotTokenMask  string `json:"telegramBotTokenMask"`
	TelegramChatID        string `json:"telegramChatId"`
	AllowPrivateNetwork   bool   `json:"allowPrivateNetwork"`
	NotifyOnWarn          bool   `json:"notifyOnWarn"`
	NotifyOnLimit         bool   `json:"notifyOnLimit"`
}

// BackupInfo 描述单个备份快照归档元数据。
type BackupInfo struct {
	Name       string `json:"name"`
	CreatedAt  string `json:"createdAt"`
	Timestamp  int64  `json:"timestamp"`
	SizeBytes  int64  `json:"sizeBytes"`
	Kind       string `json:"kind"` // manual | pre_restore
	SHA256     string `json:"sha256"`
	AppVersion string `json:"appVersion"`
	Note       string `json:"note,omitempty"`
}
