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

// InterfaceInfo 表示单个网络接口的元数据与实时状态（原生支持 IPv4 与全局 IPv6）。
type InterfaceInfo struct {
	Name          string   `json:"name"`
	Alias         string   `json:"alias"`
	IsVirtual     bool     `json:"isVirtual"`
	Visible       bool     `json:"visible"`
	OperState     string   `json:"operState"`
	SpeedMbps     int      `json:"speedMbps"`
	MAC           string   `json:"mac"`
	IPv4          []string `json:"ipv4"`
	IPv6          []string `json:"ipv6"`
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
	PublicHubURL          string `json:"publicHubUrl"`
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
		PublicHubURL:          "",
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
		MonthlyLimitBytes: 1000 * 1024 * 1024 * 1024,
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

	// 主控统一集群告警托管配置（配置一次即可覆盖全集群所有节点的掉线/恢复、流量超额与硬盘/内存高负载）
	ClusterMonitorEnabled bool `json:"clusterMonitorEnabled"`
	NotifyNodeOffline     bool `json:"notifyNodeOffline"`
	OfflineGraceSec       int  `json:"offlineGraceSec"`
	NotifyRemoteQuota     bool `json:"notifyRemoteQuota"`
	DiskWarnPercent       int  `json:"diskWarnPercent"`
	MemWarnPercent        int  `json:"memWarnPercent"`
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
	ClusterMonitorEnabled bool   `json:"clusterMonitorEnabled"`
	NotifyNodeOffline     bool   `json:"notifyNodeOffline"`
	OfflineGraceSec       int    `json:"offlineGraceSec"`
	NotifyRemoteQuota     bool   `json:"notifyRemoteQuota"`
	DiskWarnPercent       int    `json:"diskWarnPercent"`
	MemWarnPercent        int    `json:"memWarnPercent"`
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

// ClusterNodeRecord 表示主控数据库中注册的被控服务器节点记录。
type ClusterNodeRecord struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	GroupName string `json:"groupName"`
	Remark    string `json:"remark"`
	TokenHash string `json:"-"`
	TokenMask string `json:"tokenMask"`
	CreatedAt int64  `json:"createdAt"`
	LastSeen  int64  `json:"lastSeen"`
	LastIP    string `json:"lastIp"`
	Version   string `json:"version"`
	Hostname  string `json:"hostname"`
	OS        string `json:"os"`
	Arch      string `json:"arch"`
}

// HostMetrics 表示主机的 CPU、内存与根分区硬盘实时占用情况。
type HostMetrics struct {
	CPUPercent     float64 `json:"cpuPercent"`
	CPUCores       int     `json:"cpuCores"`
	MemUsedBytes   uint64  `json:"memUsedBytes"`
	MemTotalBytes  uint64  `json:"memTotalBytes"`
	MemPercent     float64 `json:"memPercent"`
	DiskUsedBytes  uint64  `json:"diskUsedBytes"`
	DiskTotalBytes uint64  `json:"diskTotalBytes"`
	DiskPercent    float64 `json:"diskPercent"`
}

// AgentHeartbeatReport 为被控节点每 3 秒上报给主控中心的实时快照。
type AgentHeartbeatReport struct {
	NodeName         string                      `json:"nodeName,omitempty"`
	Version          string                      `json:"version"`
	Hostname         string                      `json:"hostname"`
	OS               string                      `json:"os"`
	Arch             string                      `json:"arch"`
	DeployMode       string                      `json:"deployMode"` // binary | docker
	CanSelfUpgrade   bool                        `json:"canSelfUpgrade"`
	UptimeSeconds    int64                       `json:"uptimeSeconds"`
	PanelPort        int                         `json:"panelPort"`
	Host             HostMetrics                 `json:"host"`
	PrimaryInterface string                      `json:"primaryInterface"`
	Interfaces       []InterfaceInfo             `json:"interfaces"`
	RealtimeByIface  map[string]RealtimeSample   `json:"realtimeByIface"`
	TodayRxBytes     int64                       `json:"todayRxBytes"`
	TodayTxBytes     int64                       `json:"todayTxBytes"`
	MonthRxBytes     int64                       `json:"monthRxBytes"`
	MonthTxBytes     int64                       `json:"monthTxBytes"`
	Quota            QuotaStatus                 `json:"quota"`
	UpgradeState     string                      `json:"upgradeState"`
	UpgradeMessage   string                      `json:"upgradeMessage"`
	ReportedAt       int64                       `json:"reportedAt"`
}

// ClusterNodeSummary 为主控多机总览墙与横向对比接口返回的单节点综合视图（含 local 主控本机）。
type ClusterNodeSummary struct {
	ID               string          `json:"id"`
	IsLocal          bool            `json:"isLocal"`
	Name             string          `json:"name"`
	GroupName        string          `json:"groupName"`
	Remark           string          `json:"remark"`
	Online           bool            `json:"online"`
	LastSeen         int64           `json:"lastSeen"`
	EndpointIP       string          `json:"endpointIp"`
	IPv4             []string        `json:"ipv4"`
	IPv6             []string        `json:"ipv6"`
	PanelPort        int             `json:"panelPort"`
	Version          string          `json:"version"`
	Hostname         string          `json:"hostname"`
	OS               string          `json:"os"`
	Arch             string          `json:"arch"`
	DeployMode       string          `json:"deployMode"`
	CanSelfUpgrade   bool            `json:"canSelfUpgrade"`
	UpgradeOutdated  bool            `json:"upgradeOutdated"`
	UpgradeState     string          `json:"upgradeState"`
	UpgradeMessage   string          `json:"upgradeMessage"`
	UptimeSeconds    int64           `json:"uptimeSeconds"`
	Host             HostMetrics     `json:"host"`
	PrimaryInterface string          `json:"primaryInterface"`
	Interfaces       []InterfaceInfo `json:"interfaces"`
	RxBytesPerSec    float64         `json:"rxBytesPerSec"`
	TxBytesPerSec    float64         `json:"txBytesPerSec"`
	TodayRxBytes     int64           `json:"todayRxBytes"`
	TodayTxBytes     int64           `json:"todayTxBytes"`
	TodayTotalBytes  int64           `json:"todayTotalBytes"`
	MonthRxBytes     int64           `json:"monthRxBytes"`
	MonthTxBytes     int64           `json:"monthTxBytes"`
	MonthTotalBytes  int64           `json:"monthTotalBytes"`
	Quota            QuotaStatus     `json:"quota"`
}

// ClusterRPCRequest 为主控向已连接被控节点下发的受控类型化指令（严禁任意 Shell 命令）。
type ClusterRPCRequest struct {
	RequestID string            `json:"requestId"`
	Action    string            `json:"action"` // query_stats | query_range | get_settings | save_settings | update_interface | import_vnstat | self_upgrade
	Params    map[string]string `json:"params,omitempty"`
	Payload   []byte            `json:"payload,omitempty"`
}

// ClusterRPCResponse 为被控节点执行类型化指令后的响应。
type ClusterRPCResponse struct {
	RequestID string `json:"requestId"`
	Success   bool   `json:"success"`
	Error     string `json:"error,omitempty"`
	Payload   []byte `json:"payload,omitempty"`
}
