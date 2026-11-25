package quota

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/vbskycn/flowmaster/internal/collector"
	"github.com/vbskycn/flowmaster/internal/logger"
	"github.com/vbskycn/flowmaster/internal/model"
	"github.com/vbskycn/flowmaster/internal/store"
)

// Service 负责计算 VPS 月度账单流量进度并触发防重、防 SSRF 的超额告警推送。
type Service struct {
	store  *store.Store
	engine *collector.Engine
	log    *logger.Manager
}

func NewService(st *store.Store, eng *collector.Engine, log *logger.Manager) *Service {
	return &Service{
		store:  st,
		engine: eng,
		log:    log,
	}
}

// ComputeCycleWindow 根据重置日 (1..31) 计算当前账单周期的起止时刻（左闭右闭日期范围）。
func ComputeCycleWindow(now time.Time, resetDay int) (start time.Time, end time.Time, daysTotal int, daysElapsed float64) {
	if resetDay < 1 || resetDay > 31 {
		resetDay = 1
	}
	loc := now.Location()
	clampDay := func(year int, month time.Month, day int) time.Time {
		lastDay := time.Date(year, month+1, 0, 0, 0, 0, 0, loc).Day()
		if day > lastDay {
			day = lastDay
		}
		return time.Date(year, month, day, 0, 0, 0, 0, loc)
	}

	thisMonthReset := clampDay(now.Year(), now.Month(), resetDay)
	var nextReset time.Time
	if !now.Before(thisMonthReset) {
		start = thisMonthReset
		nextMonth := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, loc).AddDate(0, 1, 0)
		nextReset = clampDay(nextMonth.Year(), nextMonth.Month(), resetDay)
	} else {
		prevMonth := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, loc).AddDate(0, -1, 0)
		start = clampDay(prevMonth.Year(), prevMonth.Month(), resetDay)
		nextReset = thisMonthReset
	}
	end = nextReset.AddDate(0, 0, -1)
	totalHours := nextReset.Sub(start).Hours()
	daysTotal = max(1, int(math.Round(totalHours/24.0)))
	daysElapsed = max(0.01, now.Sub(start).Hours()/24.0)
	return start, end, daysTotal, daysElapsed
}

// Evaluate 计算当前月度流量账单状态。
func (s *Service) Evaluate(ctx context.Context, now time.Time) (model.QuotaStatus, error) {
	cfg := s.store.GetQuotaConfig()
	start, end, daysTotal, daysElapsed := ComputeCycleWindow(now.In(time.Local), cfg.ResetDay)
	startStr := start.Format("2006-01-02")
	endStr := end.Format("2006-01-02")
	todayStr := now.In(time.Local).Format("2006-01-02")

	ifaces, _ := s.engine.ListInterfaces(ctx, false)
	var targetIfaces []string
	displayIface := cfg.Interface

	if cfg.Interface == "__all__" {
		for _, item := range ifaces {
			targetIfaces = append(targetIfaces, item.Name)
		}
	} else if cfg.Interface != "" {
		targetIfaces = []string{cfg.Interface}
	} else if len(ifaces) > 0 {
		targetIfaces = []string{ifaces[0].Name}
		displayIface = ifaces[0].Name
	}

	var rxBytes, txBytes int64
	for _, name := range targetIfaces {
		res, err := s.engine.QueryRange(ctx, name, startStr, todayStr, "")
		if err != nil {
			continue
		}
		rxBytes += res.Summary.TotalRxBytes
		txBytes += res.Summary.TotalTxBytes
	}

	var used int64
	switch cfg.Direction {
	case model.QuotaDirTX:
		used = txBytes
	case model.QuotaDirRX:
		used = rxBytes
	case model.QuotaDirMax:
		used = max(rxBytes, txBytes)
	default:
		cfg.Direction = model.QuotaDirBoth
		used = rxBytes + txBytes
	}

	var pct float64
	var rem int64
	if cfg.MonthlyLimitBytes > 0 {
		pct = math.Round((float64(used)/float64(cfg.MonthlyLimitBytes))*10000) / 100
		rem = max(0, cfg.MonthlyLimitBytes-used)
	}
	projected := int64(float64(used) / daysElapsed * float64(daysTotal))

	status := model.QuotaStatus{
		Enabled:        cfg.Enabled,
		Interface:      displayIface,
		Direction:      cfg.Direction,
		ResetDay:       cfg.ResetDay,
		CycleStart:     startStr,
		CycleEnd:       endStr,
		DaysElapsed:    math.Round(daysElapsed*10) / 10,
		DaysTotal:      daysTotal,
		RxBytes:        rxBytes,
		TxBytes:        txBytes,
		UsedBytes:      used,
		LimitBytes:     cfg.MonthlyLimitBytes,
		RemainingBytes: rem,
		UsagePercent:   pct,
		ProjectedBytes: projected,
		WarnPercent:    cfg.WarnPercent,
		OverWarn:       cfg.Enabled && cfg.MonthlyLimitBytes > 0 && pct >= float64(cfg.WarnPercent),
		OverLimit:      cfg.Enabled && cfg.MonthlyLimitBytes > 0 && used >= cfg.MonthlyLimitBytes,
	}
	return status, nil
}

// CheckAndNotify 定期检查流量阈值，满足告警条件且本周期尚未推送时执行通知。
func (s *Service) CheckAndNotify(ctx context.Context) {
	qCfg := s.store.GetQuotaConfig()
	aCfg := s.store.GetAlertConfig()
	if !qCfg.Enabled || !aCfg.Enabled || qCfg.MonthlyLimitBytes <= 0 {
		return
	}

	status, err := s.Evaluate(ctx, time.Now())
	if err != nil {
		return
	}

	dedupe := s.store.GetAlertDedupeState()
	limitKey := fmt.Sprintf("%s:%s:limit", status.CycleStart, status.Interface)
	warnKey := fmt.Sprintf("%s:%s:warn:%d", status.CycleStart, status.Interface, status.WarnPercent)

	if status.OverLimit && aCfg.NotifyOnLimit && dedupe[limitKey] == 0 {
		title := "🚨 FlowMaster 月度流量已超额"
		text := formatQuotaMessage(title, status)
		if err := s.dispatchAlert(ctx, aCfg, "quota_exceeded", title, text, status); err == nil {
			dedupe[limitKey] = time.Now().Unix()
			_ = s.store.SaveAlertDedupeState(dedupe)
		}
		return
	}

	if status.OverWarn && aCfg.NotifyOnWarn && dedupe[warnKey] == 0 {
		title := fmt.Sprintf("⚠️ FlowMaster 流量已达预警线 (%d%%)", status.WarnPercent)
		text := formatQuotaMessage(title, status)
		if err := s.dispatchAlert(ctx, aCfg, "quota_warning", title, text, status); err == nil {
			dedupe[warnKey] = time.Now().Unix()
			_ = s.store.SaveAlertDedupeState(dedupe)
		}
	}
}

// SendTestAlert 供管理后台手动触发告警连通性验证。
func (s *Service) SendTestAlert(ctx context.Context) error {
	aCfg := s.store.GetAlertConfig()
	if strings.TrimSpace(aCfg.WebhookURL) == "" && (strings.TrimSpace(aCfg.TelegramBotToken) == "" || strings.TrimSpace(aCfg.TelegramChatID) == "") {
		return errors.New("请先配置至少一种告警通道（Webhook URL 或 Telegram Bot）并保存")
	}
	status, _ := s.Evaluate(ctx, time.Now())
	title := "✅ FlowMaster 告警通道连通性测试"
	text := fmt.Sprintf("%s\n时间：%s\n当前周期：%s ~ %s\n当前已用：%.2f GiB (%.2f%%)",
		title,
		time.Now().Format("2006-01-02 15:04:05"),
		status.CycleStart, status.CycleEnd,
		float64(status.UsedBytes)/(1024*1024*1024),
		status.UsagePercent,
	)
	return s.dispatchAlert(ctx, aCfg, "test", title, text, status)
}

// DispatchClusterAlert 供主控集群监控循环复用同一防 SSRF 推送通道发送节点掉线/恢复、配额或硬件预警。
func (s *Service) DispatchClusterAlert(ctx context.Context, event, title, text string) error {
	aCfg := s.store.GetAlertConfig()
	if !aCfg.Enabled {
		return nil
	}
	return s.dispatchAlert(ctx, aCfg, event, title, text, model.QuotaStatus{})
}

func formatQuotaMessage(title string, st model.QuotaStatus) string {
	giB := float64(1024 * 1024 * 1024)
	return fmt.Sprintf("%s\n监控接口：%s\n计费周期：%s ~ %s\n已用流量：%.2f GiB / %.2f GiB (%.2f%%)\n预计周期末：%.2f GiB",
		title,
		st.Interface,
		st.CycleStart, st.CycleEnd,
		float64(st.UsedBytes)/giB, float64(st.LimitBytes)/giB, st.UsagePercent,
		float64(st.ProjectedBytes)/giB,
	)
}

func (s *Service) dispatchAlert(ctx context.Context, cfg model.AlertConfig, event, title, text string, status model.QuotaStatus) error {
	client := newSafeHTTPClient(cfg.AllowPrivateNetwork)
	var errs []string
	sentCount := 0

	if strings.TrimSpace(cfg.WebhookURL) != "" {
		if err := sendWebhook(ctx, client, cfg.WebhookURL, cfg.WebhookSecret, event, title, text, status, cfg.AllowPrivateNetwork); err != nil {
			s.log.AlertError("Webhook 推送失败 (%s): %v", event, err)
			errs = append(errs, "Webhook: "+err.Error())
		} else {
			s.log.AlertInfo("Webhook 推送成功 (%s)", event)
			sentCount++
		}
	}

	if strings.TrimSpace(cfg.TelegramBotToken) != "" && strings.TrimSpace(cfg.TelegramChatID) != "" {
		if err := sendTelegram(ctx, client, cfg.TelegramBotToken, cfg.TelegramChatID, text); err != nil {
			s.log.AlertError("Telegram 推送失败 (%s): %v", event, err)
			errs = append(errs, "Telegram: "+err.Error())
		} else {
			s.log.AlertInfo("Telegram 推送成功 (%s -> Chat %s)", event, cfg.TelegramChatID)
			sentCount++
		}
	}

	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	if sentCount == 0 {
		return errors.New("未启用有效的推送目标")
	}
	return nil
}

func validateTargetURL(rawURL string, allowPrivate bool) (*url.URL, error) {
	u, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" {
		return nil, errors.New("仅支持有效的 http/https URL")
	}
	if !allowPrivate && isDisallowedHost(u.Hostname()) {
		return nil, errors.New("目标地址属于内网或本地保留网段，如需推送内网服务请开启“允许内网地址”")
	}
	return u, nil
}

func isDisallowedIP(ip net.IP) bool {
	if ip == nil {
		return true
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified()
}

func isDisallowedHost(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return isDisallowedIP(ip)
	}
	return false
}

// newSafeHTTPClient 构造禁止无校验重定向、带 Dial 层内网 SSRF 拦截与 10s 超时的安全客户端。
func newSafeHTTPClient(allowPrivate bool) *http.Client {
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			ips, err := net.DefaultResolver.LookupIPAddr(ctx, host)
			if err != nil || len(ips) == 0 {
				return nil, fmt.Errorf("DNS 解析失败: %w", err)
			}
			for _, ipAddr := range ips {
				if !allowPrivate && isDisallowedIP(ipAddr.IP) {
					return nil, errors.New("拒绝连接内网或保留地址 (SSRF 防护)")
				}
			}
			return dialer.DialContext(ctx, network, net.JoinHostPort(ips[0].IP.String(), port))
		},
	}
	return &http.Client{
		Timeout:   10 * time.Second,
		Transport: transport,
		// 禁止自动跟随重定向，防止公网地址 302 跳转至内网元数据服务。
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func sendWebhook(ctx context.Context, client *http.Client, rawURL, secret, event, title, text string, status model.QuotaStatus, allowPrivate bool) error {
	if _, err := validateTargetURL(rawURL, allowPrivate); err != nil {
		return err
	}
	payload := map[string]any{
		"event":     event,
		"title":     title,
		"text":      text,
		"content":   text,
		"msgtype":   "text",
		"timestamp": time.Now().Format(time.RFC3339),
		"quota":     status,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, rawURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "FlowMaster-Alert/1.0")
	if strings.TrimSpace(secret) != "" {
		mac := hmac.New(sha256.New, []byte(secret))
		_, _ = mac.Write(body)
		req.Header.Set("X-FlowMaster-Signature", "sha256="+hex.EncodeToString(mac.Sum(nil)))
	}

	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64*1024))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("HTTP 状态码 %d", resp.StatusCode)
	}
	return nil
}

func sendTelegram(ctx context.Context, client *http.Client, botToken, chatID, text string) error {
	apiURL := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", url.PathEscape(strings.TrimSpace(botToken)))
	body, _ := json.Marshal(map[string]any{
		"chat_id": strings.TrimSpace(chatID),
		"text":    text,
	})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiURL, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64*1024))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("Telegram API 状态码 %d", resp.StatusCode)
	}
	return nil
}

// MaskSecret 生成脱敏掩码供后台回显（只指示已配置，绝不泄露真实明文）。
func MaskSecret(secret string) string {
	trimmed := strings.TrimSpace(secret)
	if trimmed == "" {
		return ""
	}
	if len(trimmed) <= 8 {
		return "********"
	}
	return trimmed[:3] + "****" + trimmed[len(trimmed)-3:]
}
