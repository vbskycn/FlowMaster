package config

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Config 保存服务启动期的运行环境配置（含单机/主控双栈监听与可选被控上报配置）。
type Config struct {
	Host                 string
	Port                 int
	DisableWeb           bool
	DataDir              string
	ProcNetDevPath       string
	SysClassNetPath      string
	VnstatBin            string
	VnstatDBDir          string
	VnstatTimeoutMs      int
	VnstatMaxConcurrency int
	RealtimeIntervalMs   int
	MaxRangeDays         int
	RateLimitWindowMs    int
	RateLimitMax         int
	RateLimitMaxClients  int
	CORSOrigins          []string
	AdminPassword        string
	AdminToken           string
	AllowAnonymousAdmin  bool
	TrustProxy           bool
	InstanceToken        string
	SessionSecret        []byte

	// 被控节点连接到主控中心的可选参数（非空时自动启动 Agent 主动长连接/心跳上报）
	HubURL    string
	HubToken  string
	NodeName  string
}

// ListenAddr 生成双栈友好的 HTTP 监听地址：
// - 当 HOST 为空、"::"、"[::]" 或 "0.0.0.0" 时返回 ":PORT"，使 Linux Go net.Listen 默认启用 IPv4+IPv6 双栈监听；
// - 当 HOST 为特定 IPv4 或特定 IPv6（如 "127.0.0.1" 或 "::1"）时使用 net.JoinHostPort 规范拼接。
func (c *Config) ListenAddr() string {
	h := strings.TrimSpace(c.Host)
	if h == "" || h == "::" || h == "[::]" || h == "0.0.0.0" {
		return fmt.Sprintf(":%d", c.Port)
	}
	h = strings.Trim(h, "[]")
	return net.JoinHostPort(h, strconv.Itoa(c.Port))
}

// DisplayListenAddr 返回用于启动日志展示的可读监听地址。
func (c *Config) DisplayListenAddr() string {
	addr := c.ListenAddr()
	if strings.HasPrefix(addr, ":") {
		return "[::]" + addr + " (IPv4/IPv6 双栈)"
	}
	return addr
}

// LoadDotEnv 从指定路径加载 .env 文件，不覆盖进程已存在的环境变量。
func LoadDotEnv(dotEnvPath string) {
	file, err := os.Open(dotEnvPath)
	if err != nil {
		return
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		idx := strings.IndexByte(line, '=')
		if idx <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		val := strings.TrimSpace(line[idx+1:])
		if len(val) >= 2 {
			if (val[0] == '"' && val[len(val)-1] == '"') || (val[0] == '\'' && val[len(val)-1] == '\'') {
				val = val[1 : len(val)-1]
			} else if hashIdx := strings.Index(val, " #"); hashIdx >= 0 {
				val = strings.TrimSpace(val[:hashIdx])
			}
		}
		if key != "" {
			if _, exists := os.LookupEnv(key); !exists {
				_ = os.Setenv(key, val)
			}
		}
	}
}

// ParseIntInRange 解析带上下界的非负十进制整数配置，越界或非法时回退默认值。
func ParseIntInRange(raw string, fallback, minVal, maxVal int) int {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return fallback
	}
	for i := 0; i < len(trimmed); i++ {
		if trimmed[i] < '0' || trimmed[i] > '9' {
			return fallback
		}
	}
	parsed, err := strconv.Atoi(trimmed)
	if err != nil || parsed < minVal || parsed > maxVal {
		return fallback
	}
	return parsed
}

// ParseBool 解析严格的 true/false 布尔配置。
func ParseBool(raw string, fallback bool) bool {
	switch strings.ToLower(strings.TrimSpace(raw)) {
	case "true", "1", "yes":
		return true
	case "false", "0", "no":
		return false
	default:
		return fallback
	}
}

// Load 从当前环境变量读取配置，并确保数据目录与高强度会话密钥就绪。
func Load() (*Config, error) {
	dataDir := strings.TrimSpace(os.Getenv("DATA_DIR"))
	if dataDir == "" {
		dataDir = "./data"
	}
	absDataDir, err := filepath.Abs(dataDir)
	if err != nil {
		return nil, fmt.Errorf("解析 DATA_DIR 失败: %w", err)
	}
	if err := os.MkdirAll(absDataDir, 0o750); err != nil {
		return nil, fmt.Errorf("创建数据目录失败: %w", err)
	}

	host := strings.TrimSpace(os.Getenv("HOST"))
	if host == "" {
		host = "::"
	}

	procNetPath := strings.TrimSpace(os.Getenv("PROC_NET_DEV_PATH"))
	if procNetPath == "" {
		procNetPath = "/proc/net/dev"
	}
	sysClassPath := strings.TrimSpace(os.Getenv("SYS_CLASS_NET_PATH"))
	if sysClassPath == "" {
		sysClassPath = "/sys/class/net"
	}
	vnstatBin := strings.TrimSpace(os.Getenv("VNSTAT_BIN"))
	if vnstatBin == "" {
		vnstatBin = "vnstat"
	}

	var corsOrigins []string
	for _, part := range strings.Split(os.Getenv("CORS_ORIGINS"), ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			corsOrigins = append(corsOrigins, trimmed)
		}
	}

	secret, err := loadOrCreateSessionSecret(absDataDir, os.Getenv("SESSION_SECRET"))
	if err != nil {
		return nil, err
	}

	return &Config{
		Host:                 host,
		Port:                 ParseIntInRange(os.Getenv("PORT"), 10089, 1, 65535),
		DisableWeb:           ParseBool(os.Getenv("DISABLE_WEB"), false),
		DataDir:              absDataDir,
		ProcNetDevPath:       procNetPath,
		SysClassNetPath:      sysClassPath,
		VnstatBin:            vnstatBin,
		VnstatDBDir:          strings.TrimSpace(os.Getenv("VNSTAT_DB_DIR")),
		VnstatTimeoutMs:      ParseIntInRange(os.Getenv("VNSTAT_COMMAND_TIMEOUT_MS"), 15000, 1000, 120000),
		VnstatMaxConcurrency: ParseIntInRange(os.Getenv("VNSTAT_MAX_CONCURRENCY"), 4, 1, 32),
		RealtimeIntervalMs:   ParseIntInRange(os.Getenv("REALTIME_INTERVAL_MS"), 1000, 1000, 60000),
		MaxRangeDays:         ParseIntInRange(os.Getenv("MAX_RANGE_DAYS"), 3660, 1, 36525),
		RateLimitWindowMs:    ParseIntInRange(os.Getenv("RATE_LIMIT_WINDOW_MS"), 60000, 1000, 3600000),
		RateLimitMax:         ParseIntInRange(os.Getenv("RATE_LIMIT_MAX"), 300, 1, 1000000),
		RateLimitMaxClients:  ParseIntInRange(os.Getenv("RATE_LIMIT_MAX_CLIENTS"), 10000, 1, 1000000),
		CORSOrigins:          corsOrigins,
		AdminPassword:        strings.TrimSpace(os.Getenv("ADMIN_PASSWORD")),
		AdminToken:           strings.TrimSpace(os.Getenv("ADMIN_TOKEN")),
		AllowAnonymousAdmin:  ParseBool(os.Getenv("ALLOW_ANONYMOUS_ADMIN"), false),
		TrustProxy:           ParseBool(os.Getenv("TRUST_PROXY"), false),
		InstanceToken:        strings.TrimSpace(os.Getenv("FLOWMASTER_INSTANCE_TOKEN")),
		SessionSecret:        secret,
		HubURL:               strings.TrimRight(strings.TrimSpace(os.Getenv("HUB_URL")), "/"),
		HubToken:             strings.TrimSpace(os.Getenv("HUB_TOKEN")),
		NodeName:             strings.TrimSpace(os.Getenv("NODE_NAME")),
	}, nil
}

// isWeakOrPlaceholderSecret 拒绝弱口令或常见示例占位符作为会话签名密钥。
func isWeakOrPlaceholderSecret(raw string) bool {
	trimmed := strings.TrimSpace(raw)
	if len(trimmed) < 32 {
		return true
	}
	lower := strings.ToLower(trimmed)
	placeholders := []string{"changeme", "replace", "example", "secret", "password", "123456", "请替换"}
	for _, p := range placeholders {
		if strings.Contains(lower, p) {
			return true
		}
	}
	return false
}

func loadOrCreateSessionSecret(dataDir, envSecret string) ([]byte, error) {
	if !isWeakOrPlaceholderSecret(envSecret) {
		return []byte(strings.TrimSpace(envSecret)), nil
	}

	keyPath := filepath.Join(dataDir, "session.key")
	if existing, err := os.ReadFile(keyPath); err == nil {
		trimmed := strings.TrimSpace(string(existing))
		if decoded, decErr := hex.DecodeString(trimmed); decErr == nil && len(decoded) >= 32 {
			return decoded, nil
		}
	}

	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return nil, fmt.Errorf("生成随机会话密钥失败: %w", err)
	}
	encoded := hex.EncodeToString(buf)
	tmpPath := keyPath + ".tmp"
	if err := os.WriteFile(tmpPath, []byte(encoded+"\n"), 0o600); err != nil {
		return nil, fmt.Errorf("写入会话密钥文件失败: %w", err)
	}
	if err := os.Rename(tmpPath, keyPath); err != nil {
		_ = os.Remove(tmpPath)
		return nil, fmt.Errorf("原子保存会话密钥失败: %w", err)
	}
	_ = os.Chmod(keyPath, 0o600)
	return buf, nil
}
