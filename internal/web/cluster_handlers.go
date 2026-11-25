package web

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	flowmaster "github.com/vbskycn/flowmaster"
	"github.com/vbskycn/flowmaster/internal/collector"
	"github.com/vbskycn/flowmaster/internal/config"
	"github.com/vbskycn/flowmaster/internal/model"
)

func (s *Server) registerClusterRoutes(mux *http.ServeMux) {
	// 被控节点主动上报与反向长轮询通道（使用独立节点 Bearer Token 认证）
	mux.HandleFunc("POST /api/v1/cluster/agent/heartbeat", s.handleAgentHeartbeat)
	mux.HandleFunc("GET /api/v1/cluster/agent/poll", s.handleAgentPoll)
	mux.HandleFunc("POST /api/v1/cluster/agent/reply", s.handleAgentReply)

	// 主控机安装包与脚本中转分发通道（免连 GitHub / 防代理失效，需合法节点 Token 或管理员登录）
	mux.HandleFunc("GET /api/v1/cluster/dist/install.sh", s.handleClusterDistInstallScript)
	mux.HandleFunc("GET /api/v1/cluster/dist/version", s.handleClusterDistVersion)
	mux.HandleFunc("GET /api/v1/cluster/dist/{version}/SHA256SUMS", s.handleClusterDistSums)
	mux.HandleFunc("GET /api/v1/cluster/dist/{version}/{filename}", s.handleClusterDistArchive)

	// 前台多机总览、横向对比与单机下钻查看接口
	mux.HandleFunc("GET /api/v1/cluster/nodes", s.requireViewAccess(s.handleListClusterNodes))
	mux.HandleFunc("GET /api/v1/cluster/nodes/{id}/interfaces", s.requireViewAccess(s.handleClusterNodeInterfaces))
	mux.HandleFunc("GET /api/v1/cluster/nodes/{id}/realtime/{interface}", s.requireViewAccess(s.handleClusterNodeRealtime))
	mux.HandleFunc("GET /api/v1/cluster/nodes/{id}/stats/{interface}/{period}", s.requireViewAccess(s.handleClusterNodeStats))
	mux.HandleFunc("GET /api/v1/cluster/nodes/{id}/stats/{interface}/range/{startDate}/{endDate}", s.requireViewAccess(s.handleClusterNodeRange))
	mux.HandleFunc("GET /api/v1/cluster/nodes/{id}/quota", s.requireViewAccess(s.handleClusterNodeQuota))

	// 管理后台：节点注册、一键命令生成、远程配额/网卡管理与批量远程升级
	mux.HandleFunc("POST /api/v1/admin/cluster/nodes", s.requireAdmin(s.handleAdminCreateNode))
	mux.HandleFunc("PUT /api/v1/admin/cluster/nodes/{id}", s.requireAdmin(s.handleAdminUpdateNodeMeta))
	mux.HandleFunc("DELETE /api/v1/admin/cluster/nodes/{id}", s.requireAdmin(s.handleAdminDeleteNode))
	mux.HandleFunc("GET /api/v1/admin/cluster/nodes/{id}/config", s.requireAdmin(s.handleAdminGetRemoteNodeConfig))
	mux.HandleFunc("PUT /api/v1/admin/cluster/nodes/{id}/config", s.requireAdmin(s.handleAdminSaveRemoteNodeConfig))
	mux.HandleFunc("PUT /api/v1/admin/cluster/nodes/{id}/interfaces/{name}", s.requireAdmin(s.handleAdminUpdateRemoteNodeInterface))
	mux.HandleFunc("POST /api/v1/admin/cluster/nodes/{id}/vnstat/import", s.requireAdmin(s.handleAdminRemoteImportVnstat))
	mux.HandleFunc("GET /api/v1/admin/cluster/releases/latest", s.requireAdmin(s.handleAdminCheckLatestRelease))
	mux.HandleFunc("POST /api/v1/admin/cluster/upgrade", s.requireAdmin(s.handleAdminUpgradeNodes))
}

func (s *Server) requireAgentAuth(w http.ResponseWriter, r *http.Request) (model.ClusterNodeRecord, bool) {
	rec, ok := s.hub.AuthenticateAgent(r.Header.Get("Authorization"))
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "无效的节点接入密钥"})
		return model.ClusterNodeRecord{}, false
	}
	return rec, true
}

func (s *Server) handleAgentHeartbeat(w http.ResponseWriter, r *http.Request) {
	rec, ok := s.requireAgentAuth(w, r)
	if !ok {
		return
	}
	var report model.AgentHeartbeatReport
	if err := readJSONBody(r, &report, 256*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	remoteIP := extractAgentEndpointIP(r, s.cfg.TrustProxy)
	s.hub.IngestHeartbeat(rec, remoteIP, report)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleAgentPoll(w http.ResponseWriter, r *http.Request) {
	rec, ok := s.requireAgentAuth(w, r)
	if !ok {
		return
	}
	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Time{})

	cmd, hasCmd := s.hub.WaitNextAgentCommand(r.Context(), rec.ID, 25*time.Second)
	if !hasCmd {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	writeJSON(w, http.StatusOK, cmd)
}

func (s *Server) handleAgentReply(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireAgentAuth(w, r); !ok {
		return
	}
	var resp model.ClusterRPCResponse
	if err := readJSONBody(r, &resp, 2*1024*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	s.hub.DeliverAgentReply(resp)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) resolvePublicHubBaseURL(r *http.Request) string {
	settings := s.store.GetSystemSettings()
	if custom := strings.TrimRight(strings.TrimSpace(settings.PublicHubURL), "/"); custom != "" {
		return custom
	}
	scheme := "http"
	if isRequestHTTPS(r, s.cfg.TrustProxy) {
		scheme = "https"
	}
	return fmt.Sprintf("%s://%s", scheme, r.Host)
}

func buildJoinShellCommand(hubBaseURL, token, name string, noWeb, mirrorHub bool) string {
	escapedHub := strings.ReplaceAll(hubBaseURL, "'", "")
	escapedTok := strings.ReplaceAll(token, "'", "")
	escapedName := strings.ReplaceAll(strings.TrimSpace(name), "'", "")
	extra := ""
	if mirrorHub {
		extra += " --mirror-hub"
	}
	if escapedName != "" {
		extra += fmt.Sprintf(" --name '%s'", escapedName)
	}
	if noWeb {
		extra += " --no-web"
	}
	if mirrorHub {
		return fmt.Sprintf(
			"curl -fsSL '%s/api/v1/cluster/dist/install.sh?token=%s' -o install.sh && "+
				"chmod +x install.sh && sudo ./install.sh join --hub '%s' --token '%s'%s",
			escapedHub, url.QueryEscape(escapedTok), escapedHub, escapedTok, extra,
		)
	}
	return fmt.Sprintf(
		"curl -fsSL --connect-timeout 5 https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh -o install.sh || "+
			"curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/FlowMaster/main/install.sh -o install.sh && "+
			"chmod +x install.sh && sudo ./install.sh join --hub '%s' --token '%s'%s",
		escapedHub, escapedTok, extra,
	)
}

func (s *Server) requireDistAccess(w http.ResponseWriter, r *http.Request) bool {
	if _, ok := s.hub.AuthenticateAgent(r.Header.Get("Authorization")); ok {
		return true
	}
	if xTok := strings.TrimSpace(r.Header.Get("X-Agent-Token")); xTok != "" {
		if _, ok := s.hub.AuthenticateAgent("Bearer " + xTok); ok {
			return true
		}
	}
	if qTok := strings.TrimSpace(r.URL.Query().Get("token")); qTok != "" {
		if _, ok := s.hub.AuthenticateAgent("Bearer " + qTok); ok {
			return true
		}
	}
	if authed, _ := s.isAuthenticated(r); authed {
		return true
	}
	writeJSON(w, http.StatusUnauthorized, map[string]any{"error": "下载主控分发文件需要有效的节点接入密钥或管理员权限"})
	return false
}

func (s *Server) handleClusterDistInstallScript(w http.ResponseWriter, r *http.Request) {
	if !s.requireDistAccess(w, r) {
		return
	}
	script := flowmaster.InstallScript()
	if len(script) == 0 {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "内置安装脚本不可用"})
		return
	}
	w.Header().Set("Content-Type", "text/x-shellscript; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(script)
}

func (s *Server) handleClusterDistVersion(w http.ResponseWriter, r *http.Request) {
	if !s.requireDistAccess(w, r) {
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"version": flowmaster.AppVersion()})
}

func (s *Server) handleClusterDistSums(w http.ResponseWriter, r *http.Request) {
	if !s.requireDistAccess(w, r) {
		return
	}
	sums, err := s.updater.ResolveDistSums(r.Context(), r.PathValue("version"))
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(sums)
}

func (s *Server) handleClusterDistArchive(w http.ResponseWriter, r *http.Request) {
	if !s.requireDistAccess(w, r) {
		return
	}
	fn := strings.TrimSpace(r.PathValue("filename"))
	var arch string
	switch fn {
	case "flowmaster-linux-amd64.tar.gz":
		arch = "amd64"
	case "flowmaster-linux-arm64.tar.gz":
		arch = "arm64"
	default:
		writeJSON(w, http.StatusNotFound, map[string]any{"error": "不支持的分发文件名"})
		return
	}

	rc := http.NewResponseController(w)
	_ = rc.SetWriteDeadline(time.Now().Add(5 * time.Minute))

	data, _, sha256Hex, err := s.updater.ResolveDistArchive(r.Context(), r.PathValue("version"), arch)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/gzip")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Checksum-Sha256", sha256Hex)
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (s *Server) handleListClusterNodes(w http.ResponseWriter, r *http.Request) {
	latestVer, _ := s.updater.FetchLatestVersion(r.Context(), false)
	if latestVer == "" {
		latestVer = flowmaster.AppVersion()
	}
	nodes, err := s.hub.ListNodeSummaries(r.Context(), latestVer)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "读取集群节点列表失败"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"hubVersion":           flowmaster.AppVersion(),
		"latestReleaseVersion": latestVer,
		"publicHubUrl":         s.resolvePublicHubBaseURL(r),
		"nodes":                nodes,
	})
}

func (s *Server) handleClusterNodeInterfaces(w http.ResponseWriter, r *http.Request) {
	nodeID := r.PathValue("id")
	if nodeID == "" || nodeID == "local" {
		s.handleV1Interfaces(w, r)
		return
	}
	nodes, err := s.hub.ListNodeSummaries(r.Context(), "")
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "读取节点状态失败"})
		return
	}
	for _, n := range nodes {
		if n.ID == nodeID {
			ifaces := n.Interfaces
			if ifaces == nil {
				ifaces = []model.InterfaceInfo{}
			}
			writeJSON(w, http.StatusOK, map[string]any{"interfaces": ifaces})
			return
		}
	}
	writeJSON(w, http.StatusNotFound, map[string]any{"error": "节点不存在"})
}

func (s *Server) handleClusterNodeRealtime(w http.ResponseWriter, r *http.Request) {
	nodeID := r.PathValue("id")
	if nodeID == "" || nodeID == "local" {
		s.handleV1Realtime(w, r)
		return
	}
	iface := r.PathValue("interface")
	if !collector.IsValidInterfaceName(iface) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的接口名称"})
		return
	}
	hist, latest, err := s.hub.GetRemoteRealtimeHistory(nodeID, iface)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"interface": iface,
		"latest":    latest,
		"history":   hist,
	})
}

func (s *Server) handleClusterNodeStats(w http.ResponseWriter, r *http.Request) {
	nodeID := r.PathValue("id")
	if nodeID == "" || nodeID == "local" {
		s.handleV1Stats(w, r)
		return
	}
	iface := r.PathValue("interface")
	period := r.PathValue("period")
	if !collector.IsValidInterfaceName(iface) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的接口名称"})
		return
	}
	switch period {
	case "5", "h", "d", "m", "y":
	default:
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的时间周期"})
		return
	}
	limit := config.ParseIntInRange(r.URL.Query().Get("limit"), 0, 1, 5000)
	raw, err := s.hub.CallNode(r.Context(), nodeID, "query_stats", map[string]string{
		"interface": iface,
		"period":    period,
		"source":    strings.TrimSpace(r.URL.Query().Get("source")),
		"limit":     strconv.Itoa(limit),
	}, nil)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(raw)
}

func (s *Server) handleClusterNodeRange(w http.ResponseWriter, r *http.Request) {
	nodeID := r.PathValue("id")
	if nodeID == "" || nodeID == "local" {
		s.handleV1Range(w, r)
		return
	}
	iface := r.PathValue("interface")
	startStr := r.PathValue("startDate")
	endStr := r.PathValue("endDate")
	if !collector.IsValidInterfaceName(iface) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的接口名称"})
		return
	}
	startDate, ok1 := parseStrictISODate(startStr)
	endDate, ok2 := parseStrictISODate(endStr)
	if !ok1 || !ok2 || startDate.After(endDate) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的起止日期范围"})
		return
	}
	raw, err := s.hub.CallNode(r.Context(), nodeID, "query_range", map[string]string{
		"interface": iface,
		"start":     startStr,
		"end":       endStr,
		"source":    strings.TrimSpace(r.URL.Query().Get("source")),
	}, nil)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(raw)
}

func (s *Server) handleClusterNodeQuota(w http.ResponseWriter, r *http.Request) {
	nodeID := r.PathValue("id")
	if nodeID == "" || nodeID == "local" {
		s.handleV1QuotaStatus(w, r)
		return
	}
	nodes, err := s.hub.ListNodeSummaries(r.Context(), "")
	if err == nil {
		for _, n := range nodes {
			if n.ID == nodeID {
				writeJSON(w, http.StatusOK, n.Quota)
				return
			}
		}
	}
	writeJSON(w, http.StatusNotFound, map[string]any{"error": "节点不存在"})
}

func (s *Server) handleAdminCreateNode(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name         string `json:"name"`
		GroupName    string `json:"groupName"`
		Remark       string `json:"remark"`
		HubURL       string `json:"hubUrl"`
		UseHubMirror *bool  `json:"useHubMirror"`
	}
	if err := readJSONBody(r, &req, 16*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	useHubMirror := true
	if req.UseHubMirror != nil {
		useHubMirror = *req.UseHubMirror
	}
	if len([]rune(req.Name)) > 48 {
		req.Name = string([]rune(req.Name)[:48])
	}
	if len([]rune(req.GroupName)) > 32 {
		req.GroupName = string([]rune(req.GroupName)[:32])
	}
	if len([]rune(req.Remark)) > 80 {
		req.Remark = string([]rune(req.Remark)[:80])
	}

	if customHub := strings.TrimRight(strings.TrimSpace(req.HubURL), "/"); customHub != "" {
		sys := s.store.GetSystemSettings()
		if sys.PublicHubURL != customHub {
			sys.PublicHubURL = customHub
			_ = s.store.SaveSystemSettings(sys)
		}
	}

	rec, plainToken, err := s.hub.CreateNode(req.Name, req.GroupName, req.Remark)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "创建节点记录失败"})
		return
	}

	baseURL := s.resolvePublicHubBaseURL(r)
	s.log.Info("管理员新增了集群受控节点: %s (%s)", rec.Name, rec.ID)
	writeJSON(w, http.StatusOK, map[string]any{
		"node":                   rec,
		"token":                  plainToken,
		"hubUrl":                 baseURL,
		"useHubMirror":           useHubMirror,
		"joinCommand":            buildJoinShellCommand(baseURL, plainToken, req.Name, false, useHubMirror),
		"joinCommandNoWeb":       buildJoinShellCommand(baseURL, plainToken, req.Name, true, useHubMirror),
		"joinCommandHub":         buildJoinShellCommand(baseURL, plainToken, req.Name, false, true),
		"joinCommandHubNoWeb":    buildJoinShellCommand(baseURL, plainToken, req.Name, true, true),
		"joinCommandGithub":      buildJoinShellCommand(baseURL, plainToken, req.Name, false, false),
		"joinCommandGithubNoWeb": buildJoinShellCommand(baseURL, plainToken, req.Name, true, false),
	})
}

func (s *Server) handleAdminUpdateNodeMeta(w http.ResponseWriter, r *http.Request) {
	nodeID := r.PathValue("id")
	var req struct {
		Name      string `json:"name"`
		GroupName string `json:"groupName"`
		Remark    string `json:"remark"`
	}
	if err := readJSONBody(r, &req, 16*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	name := strings.TrimSpace(req.Name)
	if name == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "节点名称不能为空"})
		return
	}
	if err := s.store.UpdateClusterNodeMeta(nodeID, name, strings.TrimSpace(req.GroupName), strings.TrimSpace(req.Remark)); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"message": "节点信息已更新"})
}

func (s *Server) handleAdminDeleteNode(w http.ResponseWriter, r *http.Request) {
	nodeID := r.PathValue("id")
	if err := s.hub.DeleteNode(nodeID); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	s.log.Info("管理员移除了集群受控节点: %s", nodeID)
	writeJSON(w, http.StatusOK, map[string]any{"message": "节点已移除"})
}

func (s *Server) handleAdminGetRemoteNodeConfig(w http.ResponseWriter, r *http.Request) {
	nodeID := r.PathValue("id")
	raw, err := s.hub.CallNode(r.Context(), nodeID, "get_node_config", nil, nil)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": err.Error()})
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(raw)
}

func (s *Server) handleAdminSaveRemoteNodeConfig(w http.ResponseWriter, r *http.Request) {
	nodeID := r.PathValue("id")
	var body map[string]any
	if err := readJSONBody(r, &body, 64*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	if _, err := s.hub.CallNode(r.Context(), nodeID, "save_node_config", nil, body); err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error()})
		return
	}
	s.log.Info("管理员远程更新了节点 %s 的配置与月度流量配额", nodeID)
	writeJSON(w, http.StatusOK, map[string]any{"message": "远程节点配置已保存生效"})
}

func (s *Server) handleAdminUpdateRemoteNodeInterface(w http.ResponseWriter, r *http.Request) {
	nodeID := r.PathValue("id")
	ifName := r.PathValue("name")
	if !collector.IsValidInterfaceName(ifName) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的接口名称"})
		return
	}
	var req struct {
		Alias   string `json:"alias"`
		Visible *bool  `json:"visible"`
	}
	if err := readJSONBody(r, &req, 16*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	ov := model.InterfaceOverride{
		Name:    ifName,
		Alias:   strings.TrimSpace(req.Alias),
		Visible: req.Visible,
	}
	if _, err := s.hub.CallNode(r.Context(), nodeID, "update_interface", nil, ov); err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"message": "远程网卡显隐/备注已更新"})
}

func (s *Server) handleAdminRemoteImportVnstat(w http.ResponseWriter, r *http.Request) {
	nodeID := r.PathValue("id")
	raw, err := s.hub.CallNode(r.Context(), nodeID, "import_vnstat", nil, nil)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error()})
		return
	}
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	writeJSON(w, http.StatusOK, map[string]any{
		"message":  "远程节点已合并导入系统 vnstat 历史数据",
		"imported": out["imported"],
	})
}

func (s *Server) handleAdminCheckLatestRelease(w http.ResponseWriter, r *http.Request) {
	ver, err := s.updater.FetchLatestVersion(r.Context(), true)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error(), "version": ver})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"version": ver})
}

func (s *Server) handleAdminUpgradeNodes(w http.ResponseWriter, r *http.Request) {
	var req struct {
		NodeIDs       []string `json:"nodeIds"`
		TargetVersion string   `json:"targetVersion"`
	}
	if err := readJSONBody(r, &req, 32*1024); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
		return
	}
	if len(req.NodeIDs) == 0 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "请至少选择一台需要升级的节点"})
		return
	}

	targetVer := strings.TrimPrefix(strings.TrimSpace(req.TargetVersion), "v")
	if targetVer == "" {
		latest, _ := s.updater.FetchLatestVersion(r.Context(), true)
		if latest != "" {
			targetVer = latest
		} else {
			targetVer = flowmaster.AppVersion()
		}
	}

	results := s.hub.UpgradeNodes(r.Context(), req.NodeIDs, targetVer)
	s.log.Warn("管理员发起了节点远程自升级 (目标版本: v%s, 节点数: %d)", targetVer, len(req.NodeIDs))
	writeJSON(w, http.StatusOK, map[string]any{
		"targetVersion": targetVer,
		"results":       results,
	})
}
