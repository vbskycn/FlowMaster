package web

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/vbskycn/flowmaster/internal/cluster"
	"github.com/vbskycn/flowmaster/internal/collector"
	"github.com/vbskycn/flowmaster/internal/config"
	"github.com/vbskycn/flowmaster/internal/logger"
	"github.com/vbskycn/flowmaster/internal/quota"
	"github.com/vbskycn/flowmaster/internal/store"
	"github.com/vbskycn/flowmaster/internal/updater"
)

func TestDualStackListenAddr(t *testing.T) {
	c1 := &config.Config{Host: "::", Port: 10089}
	if got := c1.ListenAddr(); got != ":10089" {
		t.Fatalf("expected dual-stack ':10089', got %q", got)
	}
	c2 := &config.Config{Host: "::1", Port: 10089}
	if got := c2.ListenAddr(); got != "[::1]:10089" {
		t.Fatalf("expected '[::1]:10089', got %q", got)
	}
	c3 := &config.Config{Host: "127.0.0.1", Port: 10089}
	if got := c3.ListenAddr(); got != "127.0.0.1:10089" {
		t.Fatalf("expected '127.0.0.1:10089', got %q", got)
	}
}

func TestClusterHubAndAgentEndToEndDrillDownAndRemoteQuota(t *testing.T) {
	hubTS, _, _ := setupTestServer(t)
	client := hubTS.Client()

	// 1. 初始化 Hub 管理员密码以获取会话 Cookie
	setupBody, _ := json.Marshal(map[string]string{"password": "HubAdminPass123!"})
	reqSetup, _ := http.NewRequest(http.MethodPost, hubTS.URL+"/api/v1/auth/setup", bytes.NewReader(setupBody))
	reqSetup.Header.Set("Content-Type", "application/json")
	reqSetup.Header.Set("X-Requested-With", "FlowMaster")
	respSetup, err := client.Do(reqSetup)
	if err != nil || respSetup.StatusCode != http.StatusOK {
		t.Fatalf("hub auth setup failed: %v", err)
	}
	var adminCookie *http.Cookie
	for _, c := range respSetup.Cookies() {
		if c.Name == sessionCookieName {
			adminCookie = c
		}
	}
	respSetup.Body.Close()

	// 2. 在 Hub 创建一台受控节点并校验一键接入命令
	createBody, _ := json.Marshal(map[string]string{
		"name":      "Oracle-ARM-Node1",
		"groupName": "US-West",
		"remark":    "Test node",
	})
	reqCreate, _ := http.NewRequest(http.MethodPost, hubTS.URL+"/api/v1/admin/cluster/nodes", bytes.NewReader(createBody))
	reqCreate.Header.Set("Content-Type", "application/json")
	reqCreate.Header.Set("X-Requested-With", "FlowMaster")
	reqCreate.AddCookie(adminCookie)
	respCreate, err := client.Do(reqCreate)
	if err != nil || respCreate.StatusCode != http.StatusOK {
		t.Fatalf("create cluster node failed: status=%d err=%v", respCreate.StatusCode, err)
	}
	var createRes struct {
		Node struct {
			ID string `json:"id"`
		} `json:"node"`
		Token             string `json:"token"`
		UseHubMirror      bool   `json:"useHubMirror"`
		JoinCommand       string `json:"joinCommand"`
		JoinCommandGithub string `json:"joinCommandGithub"`
	}
	_ = json.NewDecoder(respCreate.Body).Decode(&createRes)
	respCreate.Body.Close()
	if createRes.Node.ID == "" || !strings.HasPrefix(createRes.Token, "fm_") || !createRes.UseHubMirror {
		t.Fatalf("unexpected create node response: %+v", createRes)
	}
	if !strings.Contains(createRes.JoinCommand, "/api/v1/cluster/dist/install.sh") || !strings.Contains(createRes.JoinCommand, "--mirror-hub") {
		t.Fatalf("expected default joinCommand to use Hub distribution, got: %s", createRes.JoinCommand)
	}
	if !strings.Contains(createRes.JoinCommandGithub, "raw.githubusercontent.com") || strings.Contains(createRes.JoinCommandGithub, "--mirror-hub") {
		t.Fatalf("expected github fallback joinCommand without --mirror-hub, got: %s", createRes.JoinCommandGithub)
	}

	// 2b. 验证主控分发端点鉴权保护与内嵌脚本/版本下发
	unauthDist, err := client.Get(hubTS.URL + "/api/v1/cluster/dist/install.sh")
	if err != nil || unauthDist.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 for unauthenticated dist download, got %v", unauthDist)
	}
	unauthDist.Body.Close()

	authScriptResp, err := client.Get(hubTS.URL + "/api/v1/cluster/dist/install.sh?token=" + createRes.Token)
	if err != nil || authScriptResp.StatusCode != http.StatusOK {
		t.Fatalf("authenticated dist install.sh failed: status=%d err=%v", authScriptResp.StatusCode, err)
	}
	authScriptResp.Body.Close()

	reqDistVer, _ := http.NewRequest(http.MethodGet, hubTS.URL+"/api/v1/cluster/dist/version", nil)
	reqDistVer.Header.Set("Authorization", "Bearer "+createRes.Token)
	respDistVer, err := client.Do(reqDistVer)
	if err != nil || respDistVer.StatusCode != http.StatusOK {
		t.Fatalf("authenticated dist version failed: status=%d err=%v", respDistVer.StatusCode, err)
	}
	respDistVer.Body.Close()

	// 2c. 验证 TRUST_PROXY=true 时优先提取 CF-Connecting-IP
	cfReq, _ := http.NewRequest(http.MethodGet, "http://example.com/", nil)
	cfReq.RemoteAddr = "127.0.0.1:45678"
	cfReq.Header.Set("CF-Connecting-IP", "203.0.113.88")
	cfReq.Header.Set("X-Forwarded-For", "172.68.1.1")
	if gotIP := extractClientIP(cfReq, true); gotIP != "203.0.113.88" {
		t.Fatalf("expected CF-Connecting-IP 203.0.113.88, got %s", gotIP)
	}

	// 3. 启动一个真实的被控 Agent 实例主动连接 Hub
	agentDir := t.TempDir()
	agentSt, err := store.Open(agentDir)
	if err != nil {
		t.Fatalf("open agent store: %v", err)
	}
	defer agentSt.Close()

	_ = agentSt.RecordTrafficDeltas(map[string]store.TrafficDelta{
		"ens3": {RxBytes: 300 * 1024 * 1024, TxBytes: 120 * 1024 * 1024},
	}, time.Now())

	agentCfg := &config.Config{
		Port:               10089,
		DataDir:            agentDir,
		RealtimeIntervalMs: 1000,
		HubURL:             hubTS.URL,
		HubToken:           createRes.Token,
		NodeName:           "Oracle-ARM-Node1",
	}
	agentLog, _ := logger.NewManager(agentDir, false)
	agentVn := collector.NewVnstatClient("vnstat-none", "", time.Second, 1, nil)
	agentEng := collector.NewEngine(agentCfg, agentSt, agentVn, agentLog)
	agentQuota := quota.NewService(agentSt, agentEng, agentLog)
	agentUp := updater.NewManager(agentLog, nil)
	agent := cluster.NewAgent(agentCfg, agentSt, agentEng, agentQuota, agentUp, agentLog)
	agent.Start()
	defer agent.Stop()

	// 等待首帧心跳上报与长轮询通道就绪
	var foundOnline bool
	for range 25 {
		respNodes, nErr := client.Get(hubTS.URL + "/api/v1/cluster/nodes")
		if nErr == nil {
			var listPayload struct {
				Nodes []struct {
					ID     string `json:"id"`
					Online bool   `json:"online"`
				} `json:"nodes"`
			}
			_ = json.NewDecoder(respNodes.Body).Decode(&listPayload)
			respNodes.Body.Close()
			for _, n := range listPayload.Nodes {
				if n.ID == createRes.Node.ID && n.Online {
					foundOnline = true
					break
				}
			}
		}
		if foundOnline {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if !foundOnline {
		t.Fatalf("expected agent node %s to report online", createRes.Node.ID)
	}

	// 4. 验证通过 Hub 下钻读取远程被控节点的按天流量明细（反向长轮询隧道 RPC）
	respDrill, err := client.Get(hubTS.URL + "/api/v1/cluster/nodes/" + createRes.Node.ID + "/stats/ens3/d")
	if err != nil || respDrill.StatusCode != http.StatusOK {
		t.Fatalf("remote drill-down stats failed: status=%d err=%v", respDrill.StatusCode, err)
	}
	var drillBody struct {
		Summary struct {
			TotalRxBytes int64 `json:"totalRxBytes"`
		} `json:"summary"`
	}
	_ = json.NewDecoder(respDrill.Body).Decode(&drillBody)
	respDrill.Body.Close()
	if drillBody.Summary.TotalRxBytes != 300*1024*1024 {
		t.Fatalf("expected 300MiB remote rxBytes via Hub tunnel, got %d", drillBody.Summary.TotalRxBytes)
	}

	// 5. 验证管理员从 Hub 远程修改该被控节点的月度流量包配额并持久化生效
	remoteQuotaBody, _ := json.Marshal(map[string]any{
		"quota": map[string]any{
			"enabled":           true,
			"interface":         "ens3",
			"resetDay":          15,
			"direction":         "both",
			"monthlyLimitBytes": int64(500 * 1024 * 1024 * 1024),
			"warnPercent":       85,
		},
	})
	reqSaveRemote, _ := http.NewRequest(http.MethodPut, hubTS.URL+"/api/v1/admin/cluster/nodes/"+createRes.Node.ID+"/config", bytes.NewReader(remoteQuotaBody))
	reqSaveRemote.Header.Set("Content-Type", "application/json")
	reqSaveRemote.Header.Set("X-Requested-With", "FlowMaster")
	reqSaveRemote.AddCookie(adminCookie)
	respSaveRemote, err := client.Do(reqSaveRemote)
	if err != nil || respSaveRemote.StatusCode != http.StatusOK {
		t.Fatalf("save remote node quota failed: status=%d err=%v", respSaveRemote.StatusCode, err)
	}
	respSaveRemote.Body.Close()

	savedOnAgent := agentSt.GetQuotaConfig()
	if !savedOnAgent.Enabled || savedOnAgent.ResetDay != 15 || savedOnAgent.WarnPercent != 85 {
		t.Fatalf("agent SQLite did not receive remote quota update: %+v", savedOnAgent)
	}
}
