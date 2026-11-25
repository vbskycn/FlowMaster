package collector

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/vbskycn/flowmaster/internal/model"
)

// ErrVnstatUnavailable 表示当前环境未安装 vnstat 或命令执行不可用。
var ErrVnstatUnavailable = errors.New("vnstat unavailable")

// ExecFunc 抽象子进程执行以便单元测试注入。
type ExecFunc func(ctx context.Context, bin string, args []string) (string, error)

// VnstatClient 封装带并发信号量、显式超时与参数数组调用的 vnstat 客户端。
type VnstatClient struct {
	bin     string
	dbDir   string
	timeout time.Duration
	sem     chan struct{}
	execFn  ExecFunc
}

// NewVnstatClient 创建安全的 vnstat 客户端实例。
func NewVnstatClient(bin, dbDir string, timeout time.Duration, maxConcurrency int, customExec ExecFunc) *VnstatClient {
	if bin == "" {
		bin = "vnstat"
	}
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	if maxConcurrency <= 0 {
		maxConcurrency = 4
	}
	fn := customExec
	if fn == nil {
		fn = defaultExecVnstat
	}
	return &VnstatClient{
		bin:     bin,
		dbDir:   strings.TrimSpace(dbDir),
		timeout: timeout,
		sem:     make(chan struct{}, maxConcurrency),
		execFn:  fn,
	}
}

func defaultExecVnstat(ctx context.Context, bin string, args []string) (string, error) {
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Env = append(cmd.Environ(), "LC_ALL=C", "LANG=C")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return stdout.String(), nil
}

func (c *VnstatClient) withDBDir(args ...string) []string {
	if c.dbDir == "" {
		return args
	}
	out := make([]string, 0, len(args)+2)
	out = append(out, "--dbdir", c.dbDir)
	out = append(out, args...)
	return out
}

// Run 受全局信号量与超时保护执行 vnstat 命令。
func (c *VnstatClient) Run(parent context.Context, args ...string) (string, error) {
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, c.timeout)
	defer cancel()

	select {
	case c.sem <- struct{}{}:
		defer func() { <-c.sem }()
	case <-ctx.Done():
		return "", ctx.Err()
	}
	return c.execFn(ctx, c.bin, c.withDBDir(args...))
}

// Version 检测 vnstat 是否可用并返回版本字符串。
func (c *VnstatClient) Version(ctx context.Context) (string, error) {
	cctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := c.Run(cctx, "--version")
	if err != nil {
		return "", fmt.Errorf("%w: %v", ErrVnstatUnavailable, err)
	}
	return strings.TrimSpace(out), nil
}

// ListInterfaces 优先通过 vnstat --dbiflist 1 获取已建库接口，旧版回退 --iflist + --oneline 验证。
func (c *VnstatClient) ListInterfaces(ctx context.Context) ([]string, error) {
	if out, err := c.Run(ctx, "--dbiflist", "1"); err == nil {
		return ParseDBInterfaceList(out), nil
	}
	iflistOut, err := c.Run(ctx, "--iflist")
	if err != nil {
		return nil, err
	}
	candidates := ParseAvailableInterfaceList(iflistOut)
	var verified []string
	for _, iface := range candidates {
		if out, vErr := c.Run(ctx, "-i", iface, "--oneline"); vErr == nil && strings.TrimSpace(out) != "" {
			verified = append(verified, iface)
		}
	}
	return verified, nil
}

// ParseDBInterfaceList 解析 vnstat --dbiflist 1 输出。
func ParseDBInterfaceList(output string) []string {
	seen := make(map[string]struct{})
	var list []string
	for _, line := range strings.Split(output, "\n") {
		name := strings.TrimSpace(line)
		if name == "" || name == "lo" || !IsValidInterfaceName(name) {
			continue
		}
		if _, exists := seen[name]; !exists {
			seen[name] = struct{}{}
			list = append(list, name)
		}
	}
	return list
}

// ParseAvailableInterfaceList 解析旧版 vnstat --iflist 输出并忽略括号内的速率描述。
func ParseAvailableInterfaceList(output string) []string {
	for _, line := range strings.Split(output, "\n") {
		if !strings.Contains(line, "Available interfaces:") {
			continue
		}
		idx := strings.Index(line, "Available interfaces:")
		rest := strings.TrimSpace(line[idx+len("Available interfaces:"):])
		tokens := strings.Fields(rest)
		var result []string
		inParen := false
		for _, tok := range tokens {
			if strings.HasPrefix(tok, "(") {
				inParen = true
			}
			if !inParen && tok != "lo" && IsValidInterfaceName(tok) {
				result = append(result, tok)
			}
			if inParen && strings.HasSuffix(tok, ")") {
				inParen = false
			}
		}
		return result
	}
	return nil
}

// vnstat 2.x JSON 输出结构定义。
type vnstatJSONRoot struct {
	VnstatVersion string                `json:"vnstatversion"`
	JSONVersion   string                `json:"jsonversion"`
	Interfaces    []vnstatJSONInterface `json:"interfaces"`
}

type vnstatJSONInterface struct {
	Name    string            `json:"name"`
	Alias   string            `json:"alias"`
	Traffic vnstatJSONTraffic `json:"traffic"`
}

type vnstatJSONTraffic struct {
	FiveMinute []vnstatJSONEntry `json:"fiveminute"`
	Hour       []vnstatJSONEntry `json:"hour"`
	Day        []vnstatJSONEntry `json:"day"`
	Month      []vnstatJSONEntry `json:"month"`
	Year       []vnstatJSONEntry `json:"year"`
}

type vnstatJSONEntry struct {
	Date vnstatJSONDate  `json:"date"`
	Time *vnstatJSONTime `json:"time,omitempty"`
	Rx   int64           `json:"rx"`
	Tx   int64           `json:"tx"`
}

type vnstatJSONDate struct {
	Year  int `json:"year"`
	Month int `json:"month"`
	Day   int `json:"day"`
}

type vnstatJSONTime struct {
	Hour   int `json:"hour"`
	Minute int `json:"minute"`
}

// VnstatInterfaceDump 保存从 vnstat --json 提取的单个接口全周期历史数据。
type VnstatInterfaceDump struct {
	Name       string
	Alias      string
	FiveMinute []model.TrafficPoint
	Hour       []model.TrafficPoint
	Day        []model.TrafficPoint
	Month      []model.TrafficPoint
	Year       []model.TrafficPoint
}

// DumpAllJSON 调用 vnstat --json 读取所有已建库接口的结构化流量账本。
func (c *VnstatClient) DumpAllJSON(ctx context.Context, iface string) ([]VnstatInterfaceDump, error) {
	var args []string
	if iface != "" {
		if !IsValidInterfaceName(iface) {
			return nil, fmt.Errorf("非法网卡名称: %s", iface)
		}
		args = []string{"--json", "a", "-i", iface}
	} else {
		args = []string{"--json", "a"}
	}
	raw, err := c.Run(ctx, args...)
	if err != nil {
		return nil, err
	}
	return ParseVnstatJSON(raw)
}

// ParseVnstatJSON 解析 vnstat 2.x JSON（rx/tx 在 JSON v2 中单位为字节，JSON v1 为 KiB，此处自动兼容）。
func ParseVnstatJSON(raw string) ([]VnstatInterfaceDump, error) {
	var root vnstatJSONRoot
	if err := json.Unmarshal([]byte(raw), &root); err != nil {
		return nil, fmt.Errorf("解析 vnstat JSON 失败: %w", err)
	}
	multiplier := int64(1)
	if strings.TrimSpace(root.JSONVersion) == "1" {
		multiplier = 1024
	}

	loc := time.Local
	var dumps []VnstatInterfaceDump
	for _, item := range root.Interfaces {
		if item.Name == "" || item.Name == "lo" {
			continue
		}
		dump := VnstatInterfaceDump{
			Name:       item.Name,
			Alias:      item.Alias,
			FiveMinute: convertVnstatEntries(item.Traffic.FiveMinute, "5", multiplier, loc),
			Hour:       convertVnstatEntries(item.Traffic.Hour, "h", multiplier, loc),
			Day:        convertVnstatEntries(item.Traffic.Day, "d", multiplier, loc),
			Month:      convertVnstatEntries(item.Traffic.Month, "m", multiplier, loc),
			Year:       convertVnstatEntries(item.Traffic.Year, "y", multiplier, loc),
		}
		dumps = append(dumps, dump)
	}
	return dumps, nil
}

func convertVnstatEntries(entries []vnstatJSONEntry, period string, mult int64, loc *time.Location) []model.TrafficPoint {
	points := make([]model.TrafficPoint, 0, len(entries))
	for _, e := range entries {
		rx := e.Rx * mult
		tx := e.Tx * mult
		total := rx + tx
		var ts time.Time
		var label string
		var seconds float64

		switch period {
		case "5":
			hr, mn := 0, 0
			if e.Time != nil {
				hr, mn = e.Time.Hour, e.Time.Minute
			}
			ts = time.Date(e.Date.Year, time.Month(max(1, e.Date.Month)), max(1, e.Date.Day), hr, mn, 0, 0, loc)
			label = fmt.Sprintf("%02d:%02d", hr, mn)
			seconds = 300
		case "h":
			hr := 0
			if e.Time != nil {
				hr = e.Time.Hour
			}
			ts = time.Date(e.Date.Year, time.Month(max(1, e.Date.Month)), max(1, e.Date.Day), hr, 0, 0, 0, loc)
			label = fmt.Sprintf("%02d:00", hr)
			seconds = 3600
		case "d":
			ts = time.Date(e.Date.Year, time.Month(max(1, e.Date.Month)), max(1, e.Date.Day), 0, 0, 0, 0, loc)
			label = fmt.Sprintf("%04d-%02d-%02d", e.Date.Year, e.Date.Month, e.Date.Day)
			seconds = 86400
		case "m":
			ts = time.Date(e.Date.Year, time.Month(max(1, e.Date.Month)), 1, 0, 0, 0, 0, loc)
			label = fmt.Sprintf("%04d-%02d", e.Date.Year, e.Date.Month)
			daysInMonth := time.Date(e.Date.Year, time.Month(max(1, e.Date.Month))+1, 0, 0, 0, 0, 0, loc).Day()
			seconds = float64(daysInMonth) * 86400
		case "y":
			ts = time.Date(e.Date.Year, 1, 1, 0, 0, 0, 0, loc)
			label = fmt.Sprintf("%04d", e.Date.Year)
			daysInYear := 365
			if (e.Date.Year%4 == 0 && e.Date.Year%100 != 0) || e.Date.Year%400 == 0 {
				daysInYear = 366
			}
			seconds = float64(daysInYear) * 86400
		}

		avgBps := 0.0
		if seconds > 0 {
			avgBps = float64(total*8) / seconds
		}
		points = append(points, model.TrafficPoint{
			Label:      label,
			Timestamp:  ts.Unix(),
			RxBytes:    rx,
			TxBytes:    tx,
			TotalBytes: total,
			AvgBps:     avgBps,
		})
	}
	sort.Slice(points, func(i, j int) bool {
		return points[i].Timestamp < points[j].Timestamp
	})
	return points
}

var trRateRegex = regexp.MustCompile(`(?i)^\s*(rx|tx)\s+([\d.]+)\s*([a-z]+/s)\s+(\d+)\s*packets/s`)

// SampleRealtimeFallback 在无 /proc/net/dev 的环境回退调用 vnstat -tr 2 -i <iface> 采样。
func (c *VnstatClient) SampleRealtimeFallback(ctx context.Context, iface string) (model.RealtimeSample, error) {
	if !IsValidInterfaceName(iface) {
		return model.RealtimeSample{}, fmt.Errorf("非法网卡名称: %s", iface)
	}
	out, err := c.Run(ctx, "-tr", "2", "-i", iface)
	if err != nil {
		return model.RealtimeSample{}, err
	}
	return ParseVnstatRealtimeOutput(iface, out, time.Now().UnixMilli())
}

// ParseVnstatRealtimeOutput 解析 vnstat -tr 文本输出为结构化实时样本。
func ParseVnstatRealtimeOutput(iface, output string, nowMs int64) (model.RealtimeSample, error) {
	sample := model.RealtimeSample{
		Interface: iface,
		Timestamp: nowMs,
		Source:    "vnstat",
	}
	matched := 0
	for _, line := range strings.Split(output, "\n") {
		m := trRateRegex.FindStringSubmatch(line)
		if len(m) != 5 {
			continue
		}
		val, err1 := strconv.ParseFloat(m[2], 64)
		pkts, err2 := strconv.ParseFloat(m[4], 64)
		if err1 != nil || err2 != nil {
			continue
		}
		bps := rateUnitToBytesPerSec(val, m[3])
		mbps := (bps * 8) / 1_000_000.0
		if strings.EqualFold(m[1], "rx") {
			sample.RxBytesPerSec = bps
			sample.RxMbps = mbps
			sample.RxPacketsPerSec = pkts
			matched++
		} else {
			sample.TxBytesPerSec = bps
			sample.TxMbps = mbps
			sample.TxPacketsPerSec = pkts
			matched++
		}
	}
	if matched < 2 {
		return model.RealtimeSample{}, errors.New("无法解析 vnstat -tr 输出")
	}
	return sample, nil
}

func rateUnitToBytesPerSec(val float64, unit string) float64 {
	switch unit {
	case "bit/s", "bits/s":
		return val / 8
	case "kbit/s":
		return val * 1_000 / 8
	case "Mbit/s":
		return val * 1_000_000 / 8
	case "Gbit/s":
		return val * 1_000_000_000 / 8
	case "Kibit/s":
		return val * 1024 / 8
	case "Mibit/s":
		return val * 1024 * 1024 / 8
	case "Gibit/s":
		return val * 1024 * 1024 * 1024 / 8
	case "B/s":
		return val
	case "KiB/s":
		return val * 1024
	case "MiB/s":
		return val * 1024 * 1024
	case "GiB/s":
		return val * 1024 * 1024 * 1024
	default:
		return 0
	}
}
