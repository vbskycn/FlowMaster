package quota

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestComputeCycleWindowClampAndRollover(t *testing.T) {
	loc := time.Local
	// 当前 3 月 10 日，重置日 15 号 -> 周期应为 2月15日 ~ 3月14日
	now1 := time.Date(2026, 3, 10, 12, 0, 0, 0, loc)
	s1, e1, total1, _ := ComputeCycleWindow(now1, 15)
	if s1.Format("2006-01-02") != "2026-02-15" || e1.Format("2006-01-02") != "2026-03-14" || total1 != 28 {
		t.Fatalf("unexpected cycle 1: %s ~ %s (%d days)", s1.Format("2006-01-02"), e1.Format("2006-01-02"), total1)
	}

	// 重置日 31 号在 2 月（平年 28 天）自动收敛为 2月28日
	now2 := time.Date(2026, 2, 28, 8, 0, 0, 0, loc)
	s2, e2, _, _ := ComputeCycleWindow(now2, 31)
	if s2.Format("2006-01-02") != "2026-02-28" || e2.Format("2006-01-02") != "2026-03-30" {
		t.Fatalf("unexpected clamped cycle 2: %s ~ %s", s2.Format("2006-01-02"), e2.Format("2006-01-02"))
	}
}

func TestSSRFTargetValidation(t *testing.T) {
	if _, err := validateTargetURL("http://127.0.0.1:8080/hook", false); err == nil {
		t.Fatalf("loopback URL should be blocked when allowPrivate=false")
	}
	if _, err := validateTargetURL("http://169.254.169.254/latest/meta-data/", false); err == nil {
		t.Fatalf("cloud metadata link-local IP should be blocked")
	}
	if _, err := validateTargetURL("http://192.168.1.50:9000/hook", false); err == nil {
		t.Fatalf("RFC1918 LAN IP should be blocked by default")
	}
	if _, err := validateTargetURL("http://192.168.1.50:9000/hook", true); err != nil {
		t.Fatalf("RFC1918 LAN IP should be allowed when allowPrivate=true: %v", err)
	}
	if _, err := validateTargetURL("https://hooks.example.com/notify", false); err != nil {
		t.Fatalf("public HTTPS URL should pass: %v", err)
	}
}

func TestWeComAndFeishuBotDeliveryAndMasking(t *testing.T) {
	var wecomMsgType, wecomContent string
	wecomErrCode := 0
	wecomSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			MsgType string `json:"msgtype"`
			Text    struct {
				Content string `json:"content"`
			} `json:"text"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		wecomMsgType = body.MsgType
		wecomContent = body.Text.Content
		_ = json.NewEncoder(w).Encode(map[string]any{"errcode": wecomErrCode, "errmsg": "mock"})
	}))
	defer wecomSrv.Close()

	var feishuMsgType, feishuText, feishuTS, feishuSign string
	feishuCode := 0
	feishuSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			MsgType   string `json:"msg_type"`
			Timestamp string `json:"timestamp"`
			Sign      string `json:"sign"`
			Content   struct {
				Text string `json:"text"`
			} `json:"content"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		feishuMsgType = body.MsgType
		feishuText = body.Content.Text
		feishuTS = body.Timestamp
		feishuSign = body.Sign
		_ = json.NewEncoder(w).Encode(map[string]any{"code": feishuCode, "msg": "mock"})
	}))
	defer feishuSrv.Close()

	client := newSafeHTTPClient(true)
	if err := sendWeCom(context.Background(), client, wecomSrv.URL+"?key=secret-key", "FlowMaster 测试企微", true); err != nil {
		t.Fatalf("sendWeCom should succeed: %v", err)
	}
	if wecomMsgType != "text" || wecomContent != "FlowMaster 测试企微" {
		t.Fatalf("unexpected wecom payload: msgtype=%q content=%q", wecomMsgType, wecomContent)
	}

	wecomErrCode = 93000
	if err := sendWeCom(context.Background(), client, wecomSrv.URL+"?key=secret-key", "fail case", true); err == nil {
		t.Fatalf("sendWeCom should fail when errcode != 0")
	}

	if err := sendFeishu(context.Background(), client, feishuSrv.URL, "my-feishu-secret", "FlowMaster 测试飞书", true); err != nil {
		t.Fatalf("sendFeishu should succeed: %v", err)
	}
	if feishuMsgType != "text" || feishuText != "FlowMaster 测试飞书" || feishuTS == "" || feishuSign != computeFeishuSign(feishuTS, "my-feishu-secret") {
		t.Fatalf("unexpected feishu payload/sign: type=%q text=%q ts=%q sign=%q", feishuMsgType, feishuText, feishuTS, feishuSign)
	}

	feishuCode = 19021
	if err := sendFeishu(context.Background(), client, feishuSrv.URL, "my-feishu-secret", "fail case", true); err == nil {
		t.Fatalf("sendFeishu should fail when code != 0")
	}

	maskedWeCom := MaskWebhookURL("https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=abc123456")
	if maskedWeCom != "https://qyapi.weixin.qq.com/****" || strings.Contains(maskedWeCom, "abc123456") {
		t.Fatalf("unexpected masked wecom URL: %q", maskedWeCom)
	}
	maskedFeishu := MaskWebhookURL("https://open.feishu.cn/open-apis/bot/v2/hook/xyz987654")
	if maskedFeishu != "https://open.feishu.cn/****" || strings.Contains(maskedFeishu, "xyz987654") {
		t.Fatalf("unexpected masked feishu URL: %q", maskedFeishu)
	}
}
