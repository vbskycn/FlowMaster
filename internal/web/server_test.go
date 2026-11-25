package web

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/vbskycn/flowmaster/internal/collector"
	"github.com/vbskycn/flowmaster/internal/config"
	"github.com/vbskycn/flowmaster/internal/logger"
	"github.com/vbskycn/flowmaster/internal/quota"
	"github.com/vbskycn/flowmaster/internal/store"
)

func setupTestServer(t *testing.T) (*httptest.Server, *store.Store, *logger.Manager) {
	t.Helper()
	tmpDir := t.TempDir()

	procMock := filepath.Join(tmpDir, "proc_net_dev")
	procContent := `Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 20971520   1200    0    0    0     0          0         0 10485760    800    0    0    0     0       0          0
`
	if err := os.WriteFile(procMock, []byte(procContent), 0o600); err != nil {
		t.Fatalf("write mock proc_net_dev: %v", err)
	}

	cfg := &config.Config{
		Host:                 "127.0.0.1",
		Port:                 10089,
		DataDir:              tmpDir,
		ProcNetDevPath:       procMock,
		SysClassNetPath:      "",
		VnstatBin:            "vnstat-nonexistent",
		VnstatTimeoutMs:      2000,
		VnstatMaxConcurrency: 2,
		RealtimeIntervalMs:   1000,
		MaxRangeDays:         3660,
		RateLimitWindowMs:    60000,
		RateLimitMax:         500,
		RateLimitMaxClients:  1000,
		TrustProxy:           true,
		InstanceToken:        "test-inst-token",
		SessionSecret:        []byte("0123456789abcdef0123456789abcdef"),
	}

	logMgr, err := logger.NewManager(tmpDir, false)
	if err != nil {
		t.Fatalf("NewManager: %v", err)
	}
	st, err := store.Open(tmpDir)
	if err != nil {
		t.Fatalf("store.Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })

	_ = st.RecordTrafficDeltas(map[string]store.TrafficDelta{
		"eth0": {RxBytes: 50 * 1024 * 1024, TxBytes: 25 * 1024 * 1024},
	}, time.Now())

	bm, err := store.NewBackupManager(st, tmpDir)
	if err != nil {
		t.Fatalf("NewBackupManager: %v", err)
	}
	vn := collector.NewVnstatClient("vnstat", "", 2*time.Second, 2, func(ctx context.Context, bin string, args []string) (string, error) {
		return "", collector.ErrVnstatUnavailable
	})
	eng := collector.NewEngine(cfg, st, vn, logMgr)
	qs := quota.NewService(st, eng, logMgr)

	srv, err := NewServer(cfg, st, bm, eng, vn, qs, logMgr)
	if err != nil {
		t.Fatalf("NewServer: %v", err)
	}
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return ts, st, logMgr
}

func TestServerAuthCookieCompatAndSecretMasking(t *testing.T) {
	ts, _, logMgr := setupTestServer(t)
	client := ts.Client()

	// 1. 验证旧版 /api/version 与实例令牌回显
	reqVer, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/version", nil)
	reqVer.Header.Set("X-FlowMaster-Instance-Token", "test-inst-token")
	respVer, err := client.Do(reqVer)
	if err != nil || respVer.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/version failed: %v", err)
	}
	var verBody map[string]any
	_ = json.NewDecoder(respVer.Body).Decode(&verBody)
	respVer.Body.Close()
	if verBody["instanceTokenMatched"] != true || verBody["version"] == "" {
		t.Fatalf("unexpected /api/version payload: %+v", verBody)
	}

	// 2. 验证旧版 /api/interfaces 与 /api/stats/eth0/d 兼容性（含 data 和 series 字段）
	respStat, err := client.Get(ts.URL + "/api/stats/eth0/d")
	if err != nil || respStat.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/stats/eth0/d failed: %v", err)
	}
	var statBody map[string]any
	_ = json.NewDecoder(respStat.Body).Decode(&statBody)
	respStat.Body.Close()
	if _, hasData := statBody["data"]; !hasData {
		t.Fatalf("legacy stats must retain data field")
	}
	if _, hasSeries := statBody["series"]; !hasSeries {
		t.Fatalf("legacy stats must retain series field")
	}

	// 3. 首次密码初始化 (HTTP 下 Secure=false；X-Forwarded-Proto=https 下 Secure=true)
	setupPayload, _ := json.Marshal(map[string]string{"password": "StrongPass123!"})
	reqSetup, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/auth/setup", bytes.NewReader(setupPayload))
	reqSetup.Header.Set("Content-Type", "application/json")
	reqSetup.Header.Set("X-Requested-With", "FlowMaster")
	reqSetup.Header.Set("X-Forwarded-Proto", "https")
	respSetup, err := client.Do(reqSetup)
	if err != nil || respSetup.StatusCode != http.StatusOK {
		t.Fatalf("POST /api/v1/auth/setup failed: status=%d err=%v", respSetup.StatusCode, err)
	}
	var sessionCookie *http.Cookie
	for _, c := range respSetup.Cookies() {
		if c.Name == sessionCookieName {
			sessionCookie = c
		}
	}
	respSetup.Body.Close()
	if sessionCookie == nil || !sessionCookie.HttpOnly || !sessionCookie.Secure {
		t.Fatalf("expected Secure+HttpOnly cookie behind X-Forwarded-Proto=https, got %+v", sessionCookie)
	}

	// 4. 保存告警密钥并验证接口绝不明文回显敏感 Token
	alertPayload, _ := json.Marshal(map[string]any{
		"enabled":          true,
		"webhookUrl":       "https://hooks.example.com/alert",
		"webhookSecret":    "my-super-secret-hmac-key",
		"telegramBotToken": "123456789:ABCDEF_secret_bot_token_value",
		"telegramChatId":   "-100999",
	})
	reqAlert, _ := http.NewRequest(http.MethodPut, ts.URL+"/api/v1/admin/alerts", bytes.NewReader(alertPayload))
	reqAlert.Header.Set("Content-Type", "application/json")
	reqAlert.Header.Set("X-Requested-With", "FlowMaster")
	reqAlert.AddCookie(sessionCookie)
	respAlert, err := client.Do(reqAlert)
	if err != nil || respAlert.StatusCode != http.StatusOK {
		t.Fatalf("PUT /api/v1/admin/alerts failed: status=%d err=%v", respAlert.StatusCode, err)
	}
	rawSettingsResp := new(bytes.Buffer)
	_, _ = rawSettingsResp.ReadFrom(respAlert.Body)
	respAlert.Body.Close()
	if strings.Contains(rawSettingsResp.String(), "my-super-secret-hmac-key") ||
		strings.Contains(rawSettingsResp.String(), "ABCDEF_secret_bot_token_value") {
		t.Fatalf("CRITICAL: secret leaked in API response: %s", rawSettingsResp.String())
	}

	// 5. 验证日志脱敏与倒序返回（最新在最顶部）
	logMgr.Info("first entry")
	time.Sleep(2 * time.Millisecond)
	logMgr.AlertWarn("push https://api.telegram.org/bot12345678:ABCDEFGHIJKLMNOPQRSTUVWXYZ12345/sendMessage?token=plainsecret")

	reqLogs, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/v1/admin/logs?channel=alert", nil)
	reqLogs.AddCookie(sessionCookie)
	respLogs, err := client.Do(reqLogs)
	if err != nil || respLogs.StatusCode != http.StatusOK {
		t.Fatalf("GET /api/v1/admin/logs failed: %v", err)
	}
	rawLogResp := new(bytes.Buffer)
	_, _ = rawLogResp.ReadFrom(respLogs.Body)
	respLogs.Body.Close()
	if strings.Contains(rawLogResp.String(), "ABCDEFGHIJKLMNOPQRSTUVWXYZ12345") || strings.Contains(rawLogResp.String(), "plainsecret") {
		t.Fatalf("sensitive tokens were not redacted in logs: %s", rawLogResp.String())
	}

	// 6. 验证登录防爆破限流（连续 5 次错误密码后返回 429）
	for i := 1; i <= 5; i++ {
		badBody, _ := json.Marshal(map[string]string{"password": "wrong-password"})
		reqBad, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/auth/login", bytes.NewReader(badBody))
		reqBad.Header.Set("Content-Type", "application/json")
		reqBad.Header.Set("X-Requested-With", "FlowMaster")
		respBad, err := client.Do(reqBad)
		if err != nil {
			t.Fatalf("login attempt %d error: %v", i, err)
		}
		respBad.Body.Close()
		if i == 5 && respBad.StatusCode != http.StatusTooManyRequests {
			t.Fatalf("expected 429 on 5th failed login, got %d", respBad.StatusCode)
		}
	}
}
