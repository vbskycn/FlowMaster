package web

import (
	"bytes"
	"encoding/json"
	"io"
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

	// 验证管理员查询主控多架构分发缓存状态返回 amd64 + arm64 列表
	reqDistStatus, _ := http.NewRequest(http.MethodGet, hubTS.URL+"/api/v1/admin/cluster/dist/status", nil)
	reqDistStatus.AddCookie(adminCookie)
	respDistStatus, err := client.Do(reqDistStatus)
	if err != nil || respDistStatus.StatusCode != http.StatusOK {
		t.Fatalf("admin dist status failed: status=%d err=%v", respDistStatus.StatusCode, err)
	}
	var distStatus struct {
		Items []struct {
			Arch string `json:"arch"`
		} `json:"items"`
	}
	_ = json.NewDecoder(respDistStatus.Body).Decode(&distStatus)
	respDistStatus.Body.Close()
	if len(distStatus.Items) < 2 {
		t.Fatalf("expected at least 2 dist architectures (amd64/arm64), got %+v", distStatus.Items)
	}

	// 2c. 验证 TRUST_PROXY=true 时优先提取 CF-Connecting-IP，且本机回环反代下即使 TRUST_PROXY=false 也能准确提取节点真实出口 IP
	cfReq, _ := http.NewRequest(http.MethodGet, "http://example.com/", nil)
	cfReq.RemoteAddr = "127.0.0.1:45678"
	cfReq.Header.Set("CF-Connecting-IP", "203.0.113.88")
	cfReq.Header.Set("X-Forwarded-For", "172.68.1.1")
	if gotIP := extractClientIP(cfReq, true); gotIP != "203.0.113.88" {
		t.Fatalf("expected CF-Connecting-IP 203.0.113.88, got %s", gotIP)
	}
	loopbackProxyReq, _ := http.NewRequest(http.MethodPost, "http://127.0.0.1:10089/api/v1/cluster/agent/heartbeat", nil)
	loopbackProxyReq.RemoteAddr = "127.0.0.1:51234"
	loopbackProxyReq.Header.Set("X-Real-IP", "158.178.205.137")
	if gotEP := extractAgentEndpointIP(loopbackProxyReq, false); gotEP != "158.178.205.137" {
		t.Fatalf("expected loopback proxy endpoint IP 158.178.205.137, got %s", gotEP)
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
	agentBM, err := store.NewBackupManager(agentSt, agentDir)
	if err != nil {
		t.Fatalf("init agent backup manager: %v", err)
	}
	agent := cluster.NewAgent(agentCfg, agentSt, agentEng, agentQuota, agentUp, agentLog)
	agent.SetBackupManager(agentBM)
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

	// 4. 验证访客模式下节点敏感 IP/端口已脱敏，且禁止未登录下钻查看远程节点详情；管理员登录后可正常下钻读取
	guestNodesResp, err := client.Get(hubTS.URL + "/api/v1/cluster/nodes")
	if err != nil || guestNodesResp.StatusCode != http.StatusOK {
		t.Fatalf("guest list cluster nodes failed: %v", err)
	}
	var guestList struct {
		PublicHubURL string `json:"publicHubUrl"`
		Nodes        []struct {
			ID         string   `json:"id"`
			EndpointIP string   `json:"endpointIp"`
			IPv4       []string `json:"ipv4"`
			PanelPort  int      `json:"panelPort"`
		} `json:"nodes"`
	}
	_ = json.NewDecoder(guestNodesResp.Body).Decode(&guestList)
	guestNodesResp.Body.Close()
	if guestList.PublicHubURL != "" {
		t.Fatalf("expected guest publicHubUrl to be redacted, got %q", guestList.PublicHubURL)
	}
	for _, n := range guestList.Nodes {
		if n.EndpointIP != "" || len(n.IPv4) > 0 || n.PanelPort != 0 {
			t.Fatalf("expected guest node sensitive fields to be redacted: %+v", n)
		}
	}

	guestDrillResp, err := client.Get(hubTS.URL + "/api/v1/cluster/nodes/" + createRes.Node.ID + "/stats/ens3/d")
	if err != nil || guestDrillResp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401 for guest remote drill-down, got %v", guestDrillResp)
	}
	guestDrillResp.Body.Close()

	reqDrill, _ := http.NewRequest(http.MethodGet, hubTS.URL+"/api/v1/cluster/nodes/"+createRes.Node.ID+"/stats/ens3/d", nil)
	reqDrill.AddCookie(adminCookie)
	respDrill, err := client.Do(reqDrill)
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

	// 6. 验证后台重命名分组、删除分组（清空归属但不删节点）以及删除节点
	renameBody, _ := json.Marshal(map[string]string{"oldName": "US-West", "newName": "北美节点"})
	reqRename, _ := http.NewRequest(http.MethodPut, hubTS.URL+"/api/v1/admin/cluster/groups", bytes.NewReader(renameBody))
	reqRename.Header.Set("Content-Type", "application/json")
	reqRename.Header.Set("X-Requested-With", "FlowMaster")
	reqRename.AddCookie(adminCookie)
	respRename, err := client.Do(reqRename)
	if err != nil || respRename.StatusCode != http.StatusOK {
		t.Fatalf("rename cluster group failed: status=%d err=%v", respRename.StatusCode, err)
	}
	respRename.Body.Close()

	reqDelGrp, _ := http.NewRequest(http.MethodDelete, hubTS.URL+"/api/v1/admin/cluster/groups/%E5%8C%97%E7%BE%8E%E8%8A%82%E7%82%B9", nil)
	reqDelGrp.Header.Set("X-Requested-With", "FlowMaster")
	reqDelGrp.AddCookie(adminCookie)
	respDelGrp, err := client.Do(reqDelGrp)
	if err != nil || respDelGrp.StatusCode != http.StatusOK {
		t.Fatalf("delete cluster group failed: status=%d err=%v", respDelGrp.StatusCode, err)
	}
	respDelGrp.Body.Close()

	// 7. 验证 v2.5.0 批量分组、批量下发配额、远程日志查看、远程备份下载与批量删除
	batchGrpBody, _ := json.Marshal(map[string]any{
		"nodeIds":   []string{createRes.Node.ID},
		"groupName": "欧洲骨干",
	})
	reqBatchGrp, _ := http.NewRequest(http.MethodPost, hubTS.URL+"/api/v1/admin/cluster/batch/group", bytes.NewReader(batchGrpBody))
	reqBatchGrp.Header.Set("Content-Type", "application/json")
	reqBatchGrp.Header.Set("X-Requested-With", "FlowMaster")
	reqBatchGrp.AddCookie(adminCookie)
	respBatchGrp, err := client.Do(reqBatchGrp)
	if err != nil || respBatchGrp.StatusCode != http.StatusOK {
		t.Fatalf("batch group failed: status=%d err=%v", respBatchGrp.StatusCode, err)
	}
	respBatchGrp.Body.Close()

	batchQuotaBody, _ := json.Marshal(map[string]any{
		"nodeIds": []string{createRes.Node.ID},
		"quota": map[string]any{
			"enabled":           true,
			"interface":         "ens3",
			"resetDay":          1,
			"direction":         "tx",
			"monthlyLimitBytes": int64(200 * 1024 * 1024 * 1024),
			"warnPercent":       75,
		},
	})
	reqBatchQuota, _ := http.NewRequest(http.MethodPost, hubTS.URL+"/api/v1/admin/cluster/batch/quota", bytes.NewReader(batchQuotaBody))
	reqBatchQuota.Header.Set("Content-Type", "application/json")
	reqBatchQuota.Header.Set("X-Requested-With", "FlowMaster")
	reqBatchQuota.AddCookie(adminCookie)
	respBatchQuota, err := client.Do(reqBatchQuota)
	if err != nil || respBatchQuota.StatusCode != http.StatusOK {
		t.Fatalf("batch quota failed: status=%d err=%v", respBatchQuota.StatusCode, err)
	}
	respBatchQuota.Body.Close()
	if gotQ := agentSt.GetQuotaConfig(); gotQ.WarnPercent != 75 || gotQ.Direction != "tx" {
		t.Fatalf("agent quota not updated by batch quota: %+v", gotQ)
	}

	// 远程日志查看（通过隧道）
	reqLogs, _ := http.NewRequest(http.MethodGet, hubTS.URL+"/api/v1/admin/cluster/nodes/"+createRes.Node.ID+"/logs?channel=system&limit=20", nil)
	reqLogs.AddCookie(adminCookie)
	respLogs, err := client.Do(reqLogs)
	if err != nil || respLogs.StatusCode != http.StatusOK {
		t.Fatalf("remote node logs failed: status=%d err=%v", respLogs.StatusCode, err)
	}
	var logsPayload struct {
		Channel string `json:"channel"`
	}
	_ = json.NewDecoder(respLogs.Body).Decode(&logsPayload)
	respLogs.Body.Close()
	if logsPayload.Channel != "system" {
		t.Fatalf("unexpected remote logs channel: %+v", logsPayload)
	}

	// 远程 SQLite 一致性备份下载（通过隧道返回 .tar.gz 与 SHA-256 头）
	reqBackup, _ := http.NewRequest(http.MethodPost, hubTS.URL+"/api/v1/admin/cluster/nodes/"+createRes.Node.ID+"/backup/download", nil)
	reqBackup.Header.Set("X-Requested-With", "FlowMaster")
	reqBackup.AddCookie(adminCookie)
	respBackup, err := client.Do(reqBackup)
	if err != nil || respBackup.StatusCode != http.StatusOK {
		t.Fatalf("remote node backup download failed: status=%d err=%v", respBackup.StatusCode, err)
	}
	archiveBytes, _ := io.ReadAll(respBackup.Body)
	respBackup.Body.Close()
	if len(archiveBytes) < 32 || archiveBytes[0] != 0x1f || archiveBytes[1] != 0x8b {
		t.Fatalf("expected valid gzip archive from remote backup, got len=%d", len(archiveBytes))
	}
	if respBackup.Header.Get("X-Checksum-Sha256") == "" {
		t.Fatalf("expected non-empty X-Checksum-Sha256 header on remote backup")
	}

	// 批量删除未确认应被拒绝，确认后成功移除
	batchDelRejectBody, _ := json.Marshal(map[string]any{"nodeIds": []string{createRes.Node.ID}, "confirm": false})
	reqBatchDelReject, _ := http.NewRequest(http.MethodPost, hubTS.URL+"/api/v1/admin/cluster/batch/delete", bytes.NewReader(batchDelRejectBody))
	reqBatchDelReject.Header.Set("Content-Type", "application/json")
	reqBatchDelReject.Header.Set("X-Requested-With", "FlowMaster")
	reqBatchDelReject.AddCookie(adminCookie)
	respBatchDelReject, err := client.Do(reqBatchDelReject)
	if err != nil || respBatchDelReject.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 for unconfirmed batch delete, got %v", respBatchDelReject)
	}
	respBatchDelReject.Body.Close()

	batchDelBody, _ := json.Marshal(map[string]any{"nodeIds": []string{createRes.Node.ID}, "confirm": true})
	reqBatchDel, _ := http.NewRequest(http.MethodPost, hubTS.URL+"/api/v1/admin/cluster/batch/delete", bytes.NewReader(batchDelBody))
	reqBatchDel.Header.Set("Content-Type", "application/json")
	reqBatchDel.Header.Set("X-Requested-With", "FlowMaster")
	reqBatchDel.AddCookie(adminCookie)
	respBatchDel, err := client.Do(reqBatchDel)
	if err != nil || respBatchDel.StatusCode != http.StatusOK {
		t.Fatalf("batch delete node failed: status=%d err=%v", respBatchDel.StatusCode, err)
	}
	respBatchDel.Body.Close()
}
