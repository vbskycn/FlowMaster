package cluster

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"runtime"
	"strconv"
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

// Agent 在配置了 HUB_URL 与 HUB_TOKEN 时主动向主控中心维持心跳上报与反向长轮询指令通道。
type Agent struct {
	cfg       *config.Config
	store     *store.Store
	engine    *collector.Engine
	quotaSvc  *quota.Service
	updater   *updater.Manager
	log       *logger.Manager
	startedAt time.Time

	hbClient   *http.Client
	pollClient *http.Client
	triggerHb  chan struct{}

	stopCh chan struct{}
	wg     sync.WaitGroup
	once   sync.Once
}

func NewAgent(
	cfg *config.Config,
	st *store.Store,
	eng *collector.Engine,
	qs *quota.Service,
	up *updater.Manager,
	log *logger.Manager,
) *Agent {
	return &Agent{
		cfg:        cfg,
		store:      st,
		engine:     eng,
		quotaSvc:   qs,
		updater:    up,
		log:        log,
		startedAt:  time.Now(),
		hbClient:   &http.Client{Timeout: 8 * time.Second},
		pollClient: &http.Client{Timeout: 35 * time.Second},
		triggerHb:  make(chan struct{}, 1),
		stopCh:     make(chan struct{}),
	}
}

// Enabled 判断当前实例是否配置了连接主控中心的探针参数。
func (a *Agent) Enabled() bool {
	return a.cfg.HubURL != "" && a.cfg.HubToken != ""
}

// Start 启动后台心跳上报与长轮询监听协程。
func (a *Agent) Start() {
	if !a.Enabled() {
		return
	}
	a.log.Info("已启用集群被控上报模式，正在连接主控中心: %s", a.cfg.HubURL)

	a.wg.Add(2)
	go a.heartbeatLoop()
	go a.longPollLoop()
}

// Stop 优雅停止后台上报与长轮询协程。
func (a *Agent) Stop() {
	a.once.Do(func() {
		close(a.stopCh)
		a.wg.Wait()
	})
}

// SendImmediateHeartbeat 立即发送一次最新状态快照（例如配置变更或自升级重启前）。
func (a *Agent) SendImmediateHeartbeat() {
	if !a.Enabled() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	_ = a.pushHeartbeatOnce(ctx)
}

func (a *Agent) heartbeatLoop() {
	defer a.wg.Done()
	// 启动后立即推送首帧心跳使主控秒级上线
	_ = a.pushHeartbeatOnce(context.Background())

	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-a.stopCh:
			return
		case <-a.triggerHb:
			_ = a.pushHeartbeatOnce(context.Background())
		case <-ticker.C:
			_ = a.pushHeartbeatOnce(context.Background())
		}
	}
}

func (a *Agent) pushHeartbeatOnce(parent context.Context) error {
	ctx, cancel := context.WithTimeout(parent, 6*time.Second)
	defer cancel()

	report := a.buildReport(ctx)
	body, err := json.Marshal(report)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.cfg.HubURL+"/api/v1/cluster/agent/heartbeat", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+a.cfg.HubToken)

	resp, err := a.hbClient.Do(req)
	if err != nil {
		return err
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 8*1024))
	_ = resp.Body.Close()
	return nil
}

func (a *Agent) buildReport(ctx context.Context) model.AgentHeartbeatReport {
	hostname, _ := os.Hostname()
	ifaces, _ := a.engine.ListInterfaces(ctx, false)
	primary := ""
	if len(ifaces) > 0 {
		primary = ifaces[0].Name
	}

	rtMap := make(map[string]model.RealtimeSample, len(ifaces))
	for _, nic := range ifaces {
		if _, latest, err := a.engine.GetRealtimeHistory(ctx, nic.Name); err == nil {
			rtMap[nic.Name] = latest
		}
	}

	var todayRx, todayTx, monthRx, monthTx int64
	if primary != "" {
		todayStr := time.Now().In(time.Local).Format("2006-01-02")
		if dayRes, err := a.engine.QueryStats(ctx, primary, "d", "", 2); err == nil {
			for _, p := range dayRes.Points {
				if p.Label == todayStr {
					todayRx, todayTx = p.RxBytes, p.TxBytes
				}
			}
		}
		ymStr := todayStr[:7]
		if mRes, err := a.engine.QueryStats(ctx, primary, "m", "", 2); err == nil {
			for _, p := range mRes.Points {
				if p.Label == ymStr {
					monthRx, monthTx = p.RxBytes, p.TxBytes
				}
			}
		}
	}

	qStatus, _ := a.quotaSvc.Evaluate(ctx, time.Now())
	upState, upMsg := a.updater.Status()
	panelPort := a.cfg.Port
	if a.cfg.DisableWeb {
		panelPort = 0
	}

	return model.AgentHeartbeatReport{
		NodeName:         a.cfg.NodeName,
		Version:          flowmaster.AppVersion(),
		Hostname:         hostname,
		OS:               runtime.GOOS,
		Arch:             runtime.GOARCH,
		DeployMode:       a.updater.DeployMode(),
		CanSelfUpgrade:   a.updater.CanSelfUpgrade(),
		UptimeSeconds:    int64(time.Since(a.startedAt).Seconds()),
		PanelPort:        panelPort,
		PrimaryInterface: primary,
		Interfaces:       ifaces,
		RealtimeByIface:  rtMap,
		TodayRxBytes:     todayRx,
		TodayTxBytes:     todayTx,
		MonthRxBytes:     monthRx,
		MonthTxBytes:     monthTx,
		Quota:            qStatus,
		UpgradeState:     upState,
		UpgradeMessage:   upMsg,
	}
}

func (a *Agent) longPollLoop() {
	defer a.wg.Done()
	backoff := time.Second

	for {
		select {
		case <-a.stopCh:
			return
		default:
		}

		reqCtx, cancel := context.WithCancel(context.Background())
		stopWatch := make(chan struct{})
		go func() {
			select {
			case <-a.stopCh:
				cancel()
			case <-stopWatch:
			}
		}()

		req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, a.cfg.HubURL+"/api/v1/cluster/agent/poll", nil)
		if err != nil {
			close(stopWatch)
			cancel()
			time.Sleep(3 * time.Second)
			continue
		}
		req.Header.Set("Authorization", "Bearer "+a.cfg.HubToken)

		resp, err := a.pollClient.Do(req)
		close(stopWatch)
		cancel()

		if err != nil {
			select {
			case <-a.stopCh:
				return
			case <-time.After(backoff):
			}
			backoff = min(15*time.Second, backoff*2)
			continue
		}

		backoff = time.Second
		if resp.StatusCode == http.StatusNoContent {
			_ = resp.Body.Close()
			continue
		}
		if resp.StatusCode != http.StatusOK {
			_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 8*1024))
			_ = resp.Body.Close()
			time.Sleep(3 * time.Second)
			continue
		}

		raw, rErr := io.ReadAll(io.LimitReader(resp.Body, 256*1024))
		_ = resp.Body.Close()
		if rErr != nil {
			continue
		}

		var rpcReq model.ClusterRPCRequest
		if json.Unmarshal(raw, &rpcReq) == nil && rpcReq.RequestID != "" {
			go a.handleRPCRequest(rpcReq)
		}
	}
}

func (a *Agent) handleRPCRequest(req model.ClusterRPCRequest) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	payload, err := a.executeWhitelistedAction(ctx, req)
	reply := model.ClusterRPCResponse{
		RequestID: req.RequestID,
		Success:   err == nil,
		Payload:   payload,
	}
	if err != nil {
		reply.Error = err.Error()
	}

	encoded, _ := json.Marshal(reply)
	httpReq, rErr := http.NewRequestWithContext(ctx, http.MethodPost, a.cfg.HubURL+"/api/v1/cluster/agent/reply", bytes.NewReader(encoded))
	if rErr == nil {
		httpReq.Header.Set("Content-Type", "application/json")
		httpReq.Header.Set("Authorization", "Bearer "+a.cfg.HubToken)
		if resp, dErr := a.hbClient.Do(httpReq); dErr == nil {
			_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 8*1024))
			_ = resp.Body.Close()
		}
	}

	select {
	case a.triggerHb <- struct{}{}:
	default:
	}
}

// executeWhitelistedAction 严格仅执行内置固定白名单业务动作，杜绝远程任意代码/Shell 执行。
func (a *Agent) executeWhitelistedAction(ctx context.Context, req model.ClusterRPCRequest) ([]byte, error) {
	switch req.Action {
	case "query_stats":
		iface := req.Params["interface"]
		period := req.Params["period"]
		source := req.Params["source"]
		limit, _ := strconv.Atoi(req.Params["limit"])
		res, err := a.engine.QueryStats(ctx, iface, period, source, limit)
		if err != nil {
			return nil, err
		}
		return json.Marshal(res)

	case "query_range":
		iface := req.Params["interface"]
		start := req.Params["start"]
		end := req.Params["end"]
		source := req.Params["source"]
		res, err := a.engine.QueryRange(ctx, iface, start, end, source)
		if err != nil {
			return nil, err
		}
		return json.Marshal(res)

	case "get_node_config":
		allIfaces, _ := a.engine.ListInterfaces(ctx, true)
		return json.Marshal(map[string]any{
			"system":     a.store.GetSystemSettings(),
			"quota":      a.store.GetQuotaConfig(),
			"interfaces": allIfaces,
		})

	case "save_node_config":
		var body struct {
			System *model.SystemSettings `json:"system"`
			Quota  *model.QuotaConfig    `json:"quota"`
		}
		if err := json.Unmarshal(req.Payload, &body); err != nil {
			return nil, errors.New("配置格式无效")
		}
		if body.System != nil {
			if err := a.store.SaveSystemSettings(*body.System); err != nil {
				return nil, err
			}
		}
		if body.Quota != nil {
			qt := *body.Quota
			if qt.ResetDay < 1 || qt.ResetDay > 31 {
				qt.ResetDay = 1
			}
			if qt.WarnPercent < 1 || qt.WarnPercent > 99 {
				qt.WarnPercent = 80
			}
			if err := a.store.SaveQuotaConfig(qt); err != nil {
				return nil, err
			}
		}
		return json.Marshal(map[string]any{"ok": true})

	case "update_interface":
		var ov model.InterfaceOverride
		if err := json.Unmarshal(req.Payload, &ov); err != nil || !collector.IsValidInterfaceName(ov.Name) {
			return nil, errors.New("网卡参数无效")
		}
		if err := a.store.SaveInterfaceOverride(ov); err != nil {
			return nil, err
		}
		return json.Marshal(map[string]any{"ok": true})

	case "import_vnstat":
		imported, err := a.engine.ImportVnstatToSQLite(ctx)
		if err != nil {
			return nil, err
		}
		return json.Marshal(map[string]any{"imported": imported})

	case "self_upgrade":
		targetVer := strings.TrimSpace(req.Params["version"])
		if err := a.updater.TriggerUpgrade(targetVer); err != nil {
			return nil, err
		}
		return json.Marshal(map[string]any{"status": "upgrading", "targetVersion": targetVer})

	default:
		return nil, errors.New("不支持的远程操作类型")
	}
}
