package cluster

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"runtime"
	"sort"
	"strings"
	"sync"
	"time"

	flowmaster "github.com/vbskycn/flowmaster"
	"github.com/vbskycn/flowmaster/internal/collector"
	"github.com/vbskycn/flowmaster/internal/config"
	"github.com/vbskycn/flowmaster/internal/logger"
	"github.com/vbskycn/flowmaster/internal/model"
	"github.com/vbskycn/flowmaster/internal/quota"
	"github.com/vbskycn/flowmaster/internal/store"
	"github.com/vbskycn/flowmaster/internal/updater"
)

const (
	nodeOnlineTTL        = 15 * time.Second
	remoteRealtimeMaxLen = 60
)

type liveNodeSession struct {
	lastReport      model.AgentHeartbeatReport
	lastSeen        time.Time
	endpointIP      string
	realtimeHistory map[string][]model.RealtimeSample
	cmdQueue        chan model.ClusterRPCRequest
	subscribers     map[chan map[string]model.RealtimeSample]struct{}
}

// Hub 管理本机 + 所有远程被控节点的实时状态汇聚、SSE 转发、反向长轮询 RPC 与批量远程升级。
type Hub struct {
	cfg       *config.Config
	store     *store.Store
	engine    *collector.Engine
	quotaSvc    *quota.Service
	updater     *updater.Manager
	hostSampler *collector.HostMetricsSampler
	log         *logger.Manager
	startedAt   time.Time

	mu              sync.RWMutex
	sessions        map[string]*liveNodeSession
	localPublicIPv4 string

	rpcMu   sync.Mutex
	pending map[string]chan model.ClusterRPCResponse
}

func NewHub(
	cfg *config.Config,
	st *store.Store,
	eng *collector.Engine,
	qs *quota.Service,
	up *updater.Manager,
	log *logger.Manager,
) *Hub {
	h := &Hub{
		cfg:       cfg,
		store:     st,
		engine:    eng,
		quotaSvc:    qs,
		updater:     up,
		hostSampler: collector.NewHostMetricsSampler(),
		log:         log,
		startedAt: time.Now(),
		sessions:  make(map[string]*liveNodeSession),
		pending:   make(map[string]chan model.ClusterRPCResponse),
	}
	go h.detectLocalPublicIPv4Once()
	return h
}

// detectLocalPublicIPv4Once 后台静默探测主控本机公网 IPv4（仅当网卡无公网 IPv4 时用于前端优先展示），失败不影响启动。
func (h *Hub) detectLocalPublicIPv4Once() {
	endpoints := []string{
		"https://api4.ipify.org",
		"https://ipv4.icanhazip.com",
		"https://4.ident.me",
	}
	client := &http.Client{Timeout: 3 * time.Second}
	for _, ep := range endpoints {
		req, err := http.NewRequest(http.MethodGet, ep, nil)
		if err != nil {
			continue
		}
		req.Header.Set("User-Agent", "FlowMaster-PublicIP-Probe")
		resp, err := client.Do(req)
		if err != nil {
			continue
		}
		raw, _ := io.ReadAll(io.LimitReader(resp.Body, 128))
		_ = resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			continue
		}
		cand := strings.TrimSpace(string(raw))
		if ip := net.ParseIP(cand); ip != nil && ip.To4() != nil && !ip.IsPrivate() && !ip.IsLoopback() {
			h.mu.Lock()
			h.localPublicIPv4 = ip.String()
			h.mu.Unlock()
			return
		}
	}
}

// HashNodeToken 计算节点接入密钥的 SHA-256 摘要。
func HashNodeToken(rawToken string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(rawToken)))
	return hex.EncodeToString(sum[:])
}

func generateHexID(bytesLen int) (string, error) {
	b := make([]byte, bytesLen)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// CreateNode 注册一台新的被控节点并返回一次性明文接入 Token。
func (h *Hub) CreateNode(name, groupName, remark string) (model.ClusterNodeRecord, string, error) {
	nodeID, err := generateHexID(8)
	if err != nil {
		return model.ClusterNodeRecord{}, "", err
	}
	sec, err := generateHexID(24)
	if err != nil {
		return model.ClusterNodeRecord{}, "", err
	}
	plainToken := "fm_" + sec
	mask := plainToken[:7] + "****" + plainToken[len(plainToken)-4:]

	cleanName := strings.TrimSpace(name)
	if cleanName == "" {
		cleanName = "待接入节点-" + nodeID[:4]
	}

	rec := model.ClusterNodeRecord{
		ID:        nodeID,
		Name:      cleanName,
		GroupName: strings.TrimSpace(groupName),
		Remark:    strings.TrimSpace(remark),
		TokenHash: HashNodeToken(plainToken),
		TokenMask: mask,
		CreatedAt: time.Now().Unix(),
	}
	if err := h.store.CreateClusterNode(rec); err != nil {
		return model.ClusterNodeRecord{}, "", err
	}
	return rec, plainToken, nil
}

// DeleteNode 删除指定节点并清理内存会话。
func (h *Hub) DeleteNode(nodeID string) error {
	if nodeID == "local" {
		return errors.New("主控本机节点不可删除")
	}
	if err := h.store.DeleteClusterNode(nodeID); err != nil {
		return err
	}
	h.mu.Lock()
	if sess, ok := h.sessions[nodeID]; ok {
		for sub := range sess.subscribers {
			close(sub)
		}
		delete(h.sessions, nodeID)
	}
	h.mu.Unlock()
	return nil
}

// AuthenticateAgent 校验被控端 Bearer Token 并返回节点记录。
func (h *Hub) AuthenticateAgent(bearerToken string) (model.ClusterNodeRecord, bool) {
	tok := strings.TrimSpace(strings.TrimPrefix(bearerToken, "Bearer "))
	if tok == "" {
		return model.ClusterNodeRecord{}, false
	}
	rec, ok, err := h.store.AuthenticateClusterNodeByHash(HashNodeToken(tok))
	if err != nil || !ok {
		return model.ClusterNodeRecord{}, false
	}
	return rec, true
}

// IngestHeartbeat 接收被控端上报的心跳与实时速率样本，并广播给正在查看该节点的浏览器 SSE。
func (h *Hub) IngestHeartbeat(rec model.ClusterNodeRecord, remoteIP string, report model.AgentHeartbeatReport) {
	now := time.Now()
	report.ReportedAt = now.UnixMilli()

	_ = h.store.TouchClusterNodeHeartbeat(
		rec.ID, rec.Name, report.NodeName, remoteIP,
		report.Version, report.Hostname, report.OS, report.Arch, now.Unix(),
	)

	h.mu.Lock()
	sess := h.ensureSessionLocked(rec.ID)
	sess.lastReport = report
	sess.lastSeen = now
	sess.endpointIP = remoteIP

	for iface, sample := range report.RealtimeByIface {
		if sample.Timestamp <= 0 {
			sample.Timestamp = report.ReportedAt
		}
		hist := sess.realtimeHistory[iface]
		if len(hist) == 0 || hist[len(hist)-1].Timestamp != sample.Timestamp {
			hist = append(hist, sample)
			if len(hist) > remoteRealtimeMaxLen {
				hist = hist[len(hist)-remoteRealtimeMaxLen:]
			}
			sess.realtimeHistory[iface] = hist
		}
	}

	if len(report.RealtimeByIface) > 0 {
		for sub := range sess.subscribers {
			select {
			case sub <- report.RealtimeByIface:
			default:
			}
		}
	}
	h.mu.Unlock()
}

func (h *Hub) ensureSessionLocked(nodeID string) *liveNodeSession {
	sess, ok := h.sessions[nodeID]
	if !ok {
		sess = &liveNodeSession{
			realtimeHistory: make(map[string][]model.RealtimeSample),
			cmdQueue:        make(chan model.ClusterRPCRequest, 16),
			subscribers:     make(map[chan map[string]model.RealtimeSample]struct{}),
		}
		h.sessions[nodeID] = sess
	}
	return sess
}

// WaitNextAgentCommand 供被控端长轮询挂起等待主控指令（最长挂起 maxWait）。
func (h *Hub) WaitNextAgentCommand(ctx context.Context, nodeID string, maxWait time.Duration) (model.ClusterRPCRequest, bool) {
	h.mu.Lock()
	sess := h.ensureSessionLocked(nodeID)
	ch := sess.cmdQueue
	h.mu.Unlock()

	timer := time.NewTimer(maxWait)
	defer timer.Stop()

	select {
	case <-ctx.Done():
		return model.ClusterRPCRequest{}, false
	case <-timer.C:
		return model.ClusterRPCRequest{}, false
	case req := <-ch:
		return req, true
	}
}

// DeliverAgentReply 接收被控端返回的 RPC 执行结果并唤醒主控等待协程。
func (h *Hub) DeliverAgentReply(resp model.ClusterRPCResponse) {
	h.rpcMu.Lock()
	waitCh, ok := h.pending[resp.RequestID]
	if ok {
		delete(h.pending, resp.RequestID)
	}
	h.rpcMu.Unlock()
	if ok {
		select {
		case waitCh <- resp:
		default:
		}
	}
}

// CallNode 向在线被控节点发起一次受控类型化 RPC 调用并等待响应。
func (h *Hub) CallNode(ctx context.Context, nodeID, action string, params map[string]string, payload any) ([]byte, error) {
	h.mu.RLock()
	sess, ok := h.sessions[nodeID]
	online := ok && time.Since(sess.lastSeen) <= nodeOnlineTTL
	h.mu.RUnlock()
	if !online {
		return nil, errors.New("目标节点当前不在线，请稍后重试")
	}

	reqID, err := generateHexID(12)
	if err != nil {
		return nil, err
	}
	var rawPayload []byte
	if payload != nil {
		rawPayload, err = json.Marshal(payload)
		if err != nil {
			return nil, err
		}
	}

	replyCh := make(chan model.ClusterRPCResponse, 1)
	h.rpcMu.Lock()
	h.pending[reqID] = replyCh
	h.rpcMu.Unlock()
	defer func() {
		h.rpcMu.Lock()
		delete(h.pending, reqID)
		h.rpcMu.Unlock()
	}()

	req := model.ClusterRPCRequest{
		RequestID: reqID,
		Action:    action,
		Params:    params,
		Payload:   rawPayload,
	}

	select {
	case sess.cmdQueue <- req:
	default:
		return nil, errors.New("节点指令队列繁忙，请稍后重试")
	}

	callCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	select {
	case <-callCtx.Done():
		return nil, errors.New("等待远程节点响应超时")
	case resp := <-replyCh:
		if !resp.Success {
			if resp.Error != "" {
				return nil, errors.New(resp.Error)
			}
			return nil, errors.New("远程节点执行请求失败")
		}
		return resp.Payload, nil
	}
}

// GetRemoteRealtimeHistory 返回远程节点指定网卡缓存的最近实时曲线样本。
func (h *Hub) GetRemoteRealtimeHistory(nodeID, iface string) ([]model.RealtimeSample, model.RealtimeSample, error) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	sess, ok := h.sessions[nodeID]
	if !ok || time.Since(sess.lastSeen) > nodeOnlineTTL {
		return nil, model.RealtimeSample{}, errors.New("远程节点当前离线")
	}
	hist := make([]model.RealtimeSample, len(sess.realtimeHistory[iface]))
	copy(hist, sess.realtimeHistory[iface])
	if len(hist) == 0 {
		if s, exists := sess.lastReport.RealtimeByIface[iface]; exists {
			return []model.RealtimeSample{s}, s, nil
		}
		return []model.RealtimeSample{}, model.RealtimeSample{Interface: iface, Timestamp: time.Now().UnixMilli()}, nil
	}
	latest := hist[len(hist)-1]
	latest.AgeMs = max(0, time.Now().UnixMilli()-latest.Timestamp)
	latest.Stale = latest.AgeMs > 15000
	return hist, latest, nil
}

// SubscribeRemoteRealtime 订阅指定远程节点的实时流量广播。
func (h *Hub) SubscribeRemoteRealtime(nodeID string) chan map[string]model.RealtimeSample {
	ch := make(chan map[string]model.RealtimeSample, 4)
	h.mu.Lock()
	sess := h.ensureSessionLocked(nodeID)
	sess.subscribers[ch] = struct{}{}
	h.mu.Unlock()
	return ch
}

// UnsubscribeRemoteRealtime 取消远程节点实时流量订阅。
func (h *Hub) UnsubscribeRemoteRealtime(nodeID string, ch chan map[string]model.RealtimeSample) {
	h.mu.Lock()
	if sess, ok := h.sessions[nodeID]; ok {
		if _, exists := sess.subscribers[ch]; exists {
			delete(sess.subscribers, ch)
			close(ch)
		}
	}
	h.mu.Unlock()
}

// ListNodeSummaries 返回包含主控本机 (id="local") 与全部被控节点的实时概览与对比数据。
func (h *Hub) ListNodeSummaries(ctx context.Context, targetLatestVer string) ([]model.ClusterNodeSummary, error) {
	if targetLatestVer == "" {
		targetLatestVer = flowmaster.AppVersion()
	}

	localSum := h.buildLocalSummary(ctx, targetLatestVer)
	records, err := h.store.ListClusterNodes()
	if err != nil {
		return []model.ClusterNodeSummary{localSum}, err
	}

	now := time.Now()
	out := make([]model.ClusterNodeSummary, 0, 1+len(records))
	out = append(out, localSum)

	h.mu.RLock()
	defer h.mu.RUnlock()

	for _, rec := range records {
		sess, hasSess := h.sessions[rec.ID]
		online := hasSess && now.Sub(sess.lastSeen) <= nodeOnlineTTL

		sum := model.ClusterNodeSummary{
			ID:         rec.ID,
			IsLocal:    false,
			Name:       rec.Name,
			GroupName:  rec.GroupName,
			Remark:     rec.Remark,
			Online:     online,
			LastSeen:   rec.LastSeen,
			EndpointIP: rec.LastIP,
			Version:    rec.Version,
			Hostname:   rec.Hostname,
			OS:         rec.OS,
			Arch:       rec.Arch,
		}

		if hasSess {
			rep := sess.lastReport
			if sess.lastSeen.Unix() > sum.LastSeen {
				sum.LastSeen = sess.lastSeen.Unix()
			}
			if sess.endpointIP != "" {
				sum.EndpointIP = sess.endpointIP
			}
			if rep.Version != "" {
				sum.Version = rep.Version
			}
			if rep.Hostname != "" {
				sum.Hostname = rep.Hostname
			}
			sum.DeployMode = rep.DeployMode
			sum.CanSelfUpgrade = rep.CanSelfUpgrade
			sum.UpgradeState = rep.UpgradeState
			sum.UpgradeMessage = rep.UpgradeMessage
			sum.UptimeSeconds = rep.UptimeSeconds
			sum.PanelPort = rep.PanelPort
			sum.Host = rep.Host
			sum.PrimaryInterface = rep.PrimaryInterface
			sum.Interfaces = rep.Interfaces
			sum.IPv4, sum.IPv6 = collectUniqueIPs(rep.Interfaces)
			if online {
				if rt, ok := rep.RealtimeByIface[rep.PrimaryInterface]; ok {
					sum.RxBytesPerSec = rt.RxBytesPerSec
					sum.TxBytesPerSec = rt.TxBytesPerSec
				}
			}
			sum.TodayRxBytes = rep.TodayRxBytes
			sum.TodayTxBytes = rep.TodayTxBytes
			sum.TodayTotalBytes = rep.TodayRxBytes + rep.TodayTxBytes
			sum.MonthRxBytes = rep.MonthRxBytes
			sum.MonthTxBytes = rep.MonthTxBytes
			sum.MonthTotalBytes = rep.MonthRxBytes + rep.MonthTxBytes
			sum.Quota = rep.Quota
		}

		if sum.Version != "" && updater.CompareSemver(sum.Version, targetLatestVer) < 0 {
			sum.UpgradeOutdated = true
		}
		out = append(out, sum)
	}

	return out, nil
}

func (h *Hub) buildLocalSummary(ctx context.Context, targetLatestVer string) model.ClusterNodeSummary {
	hostname, _ := os.Hostname()
	settings := h.store.GetSystemSettings()
	ifaces, _ := h.engine.ListInterfaces(ctx, false)
	primary := ""
	if len(ifaces) > 0 {
		primary = ifaces[0].Name
	}

	var rxBps, txBps float64
	var todayRx, todayTx, monthRx, monthTx int64
	if primary != "" {
		if _, latest, err := h.engine.GetRealtimeHistory(ctx, primary); err == nil {
			rxBps = latest.RxBytesPerSec
			txBps = latest.TxBytesPerSec
		}
		todayStr := time.Now().In(time.Local).Format("2006-01-02")
		if dayRes, err := h.engine.QueryStats(ctx, primary, "d", "", 2); err == nil {
			for _, p := range dayRes.Points {
				if p.Label == todayStr {
					todayRx, todayTx = p.RxBytes, p.TxBytes
				}
			}
		}
		ymStr := todayStr[:7]
		if mRes, err := h.engine.QueryStats(ctx, primary, "m", "", 2); err == nil {
			for _, p := range mRes.Points {
				if p.Label == ymStr {
					monthRx, monthTx = p.RxBytes, p.TxBytes
				}
			}
		}
	}

	qStatus, _ := h.quotaSvc.Evaluate(ctx, time.Now())
	upState, upMsg := h.updater.Status()
	ipv4s, ipv6s := collectUniqueIPs(ifaces)
	ver := flowmaster.AppVersion()

	localName := settings.SiteTitle
	if localName == "" || localName == "FlowMaster 流量监控" {
		if hostname != "" {
			localName = fmt.Sprintf("主控本机 (%s)", hostname)
		} else {
			localName = "主控本机"
		}
	}

	h.mu.RLock()
	localPubIP := h.localPublicIPv4
	h.mu.RUnlock()

	return model.ClusterNodeSummary{
		ID:               "local",
		IsLocal:          true,
		Name:             localName,
		GroupName:        "主控中心",
		Online:           true,
		LastSeen:         time.Now().Unix(),
		EndpointIP:       localPubIP,
		IPv4:             ipv4s,
		IPv6:             ipv6s,
		PanelPort:        h.cfg.Port,
		Version:          ver,
		Hostname:         hostname,
		OS:               runtime.GOOS,
		Arch:             runtime.GOARCH,
		DeployMode:       h.updater.DeployMode(),
		CanSelfUpgrade:   h.updater.CanSelfUpgrade(),
		UpgradeOutdated:  updater.CompareSemver(ver, targetLatestVer) < 0,
		UpgradeState:     upState,
		UpgradeMessage:   upMsg,
		UptimeSeconds:    int64(time.Since(h.startedAt).Seconds()),
		Host:             h.hostSampler.Sample(),
		PrimaryInterface: primary,
		Interfaces:       ifaces,
		RxBytesPerSec:    rxBps,
		TxBytesPerSec:    txBps,
		TodayRxBytes:     todayRx,
		TodayTxBytes:     todayTx,
		TodayTotalBytes:  todayRx + todayTx,
		MonthRxBytes:     monthRx,
		MonthTxBytes:     monthTx,
		MonthTotalBytes:  monthRx + monthTx,
		Quota:            qStatus,
	}
}

// UpgradeNodes 批量向指定的在线被控节点（及可选主控本机）下发原子自升级指令。
func (h *Hub) UpgradeNodes(ctx context.Context, nodeIDs []string, targetVersion string) map[string]string {
	results := make(map[string]string, len(nodeIDs))
	var wg sync.WaitGroup
	var resMu sync.Mutex

	recordResult := func(id, msg string) {
		resMu.Lock()
		results[id] = msg
		resMu.Unlock()
	}

	for _, rawID := range nodeIDs {
		id := strings.TrimSpace(rawID)
		if id == "" {
			continue
		}
		if id == "local" {
			if err := h.updater.TriggerUpgrade(targetVersion); err != nil {
				recordResult("local", "失败: "+err.Error())
			} else {
				recordResult("local", "已启动自升级")
			}
			continue
		}

		wg.Add(1)
		go func(nodeID string) {
			defer wg.Done()
			_, err := h.CallNode(ctx, nodeID, "self_upgrade", map[string]string{"version": targetVersion}, nil)
			if err != nil {
				recordResult(nodeID, "失败: "+err.Error())
			} else {
				recordResult(nodeID, "已下发升级指令")
			}
		}(id)
	}
	wg.Wait()
	return results
}

func collectUniqueIPs(ifaces []model.InterfaceInfo) (ipv4s []string, ipv6s []string) {
	v4Set := make(map[string]bool)
	v6Set := make(map[string]bool)
	for _, nic := range ifaces {
		for _, ip := range nic.IPv4 {
			if !v4Set[ip] {
				v4Set[ip] = true
				ipv4s = append(ipv4s, ip)
			}
		}
		for _, ip := range nic.IPv6 {
			if !v6Set[ip] {
				v6Set[ip] = true
				ipv6s = append(ipv6s, ip)
			}
		}
	}
	sort.Strings(ipv4s)
	sort.Strings(ipv6s)
	return ipv4s, ipv6s
}
