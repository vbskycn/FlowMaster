package cluster

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/vbskycn/flowmaster/internal/model"
)

// BatchSetGroup 批量更新选中受控节点的分组标签。
func (h *Hub) BatchSetGroup(nodeIDs []string, groupName string) map[string]string {
	results := make(map[string]string, len(nodeIDs))
	cleanGroup := strings.TrimSpace(groupName)
	if len([]rune(cleanGroup)) > 32 {
		cleanGroup = string([]rune(cleanGroup)[:32])
	}

	records, _ := h.store.ListClusterNodes()
	recMap := make(map[string]model.ClusterNodeRecord, len(records))
	for _, r := range records {
		recMap[r.ID] = r
	}

	for _, rawID := range nodeIDs {
		id := strings.TrimSpace(rawID)
		if id == "" || id == "local" {
			if id == "local" {
				results[id] = "跳过: 主控本机固定归属主控中心"
			}
			continue
		}
		rec, ok := recMap[id]
		if !ok {
			results[id] = "失败: 节点不存在"
			continue
		}
		if err := h.store.UpdateClusterNodeMeta(id, rec.Name, cleanGroup, rec.Remark); err != nil {
			results[id] = "失败: " + err.Error()
		} else {
			results[id] = "已更新分组"
		}
	}
	return results
}

// BatchDeleteNodes 批量从主控移除选中的受控节点记录。
func (h *Hub) BatchDeleteNodes(nodeIDs []string) map[string]string {
	results := make(map[string]string, len(nodeIDs))
	for _, rawID := range nodeIDs {
		id := strings.TrimSpace(rawID)
		if id == "" {
			continue
		}
		if err := h.DeleteNode(id); err != nil {
			results[id] = "失败: " + err.Error()
		} else {
			results[id] = "已删除"
		}
	}
	return results
}

// BatchApplyQuota 将统一的月度流量包配额模板批量下发至选中节点（含主控本机及在线远程节点）。
func (h *Hub) BatchApplyQuota(ctx context.Context, nodeIDs []string, qt model.QuotaConfig) map[string]string {
	results := make(map[string]string, len(nodeIDs))
	var wg sync.WaitGroup
	var mu sync.Mutex
	setRes := func(id, msg string) {
		mu.Lock()
		results[id] = msg
		mu.Unlock()
	}

	for _, rawID := range nodeIDs {
		id := strings.TrimSpace(rawID)
		if id == "" {
			continue
		}
		if id == "local" {
			if err := h.store.SaveQuotaConfig(qt); err != nil {
				setRes("local", "失败: "+err.Error())
			} else {
				setRes("local", "已保存生效")
			}
			continue
		}
		wg.Add(1)
		go func(nodeID string) {
			defer wg.Done()
			_, err := h.CallNode(ctx, nodeID, "save_node_config", nil, map[string]any{"quota": qt})
			if err != nil {
				setRes(nodeID, "失败: "+err.Error())
			} else {
				setRes(nodeID, "已下发生效")
			}
		}(id)
	}
	wg.Wait()
	return results
}

// BatchRestartNodes 批量触发选中在线节点平滑重启 FlowMaster 服务（systemd / Docker 自动拉起）。
func (h *Hub) BatchRestartNodes(ctx context.Context, nodeIDs []string) map[string]string {
	results := make(map[string]string, len(nodeIDs))
	var wg sync.WaitGroup
	var mu sync.Mutex
	setRes := func(id, msg string) {
		mu.Lock()
		results[id] = msg
		mu.Unlock()
	}

	restartLocal := false
	for _, rawID := range nodeIDs {
		id := strings.TrimSpace(rawID)
		if id == "" {
			continue
		}
		if id == "local" {
			restartLocal = true
			setRes("local", "主控即将平滑重启")
			continue
		}
		wg.Add(1)
		go func(nodeID string) {
			defer wg.Done()
			_, err := h.CallNode(ctx, nodeID, "restart_service", nil, nil)
			if err != nil {
				setRes(nodeID, "失败: "+err.Error())
			} else {
				setRes(nodeID, "已发送平滑重启指令")
			}
		}(id)
	}
	wg.Wait()

	if restartLocal {
		go func() {
			time.Sleep(500 * time.Millisecond)
			h.engine.FlushPending()
			os.Exit(0)
		}()
	}
	return results
}

// StartAlertMonitor 启动主控统一集群告警后台巡检循环（掉线/恢复、远程流量配额、硬盘/内存高水位）。
func (h *Hub) StartAlertMonitor() {
	go func() {
		// 启动后预留 25 秒等待各在线节点重新上报首帧心跳，避免主控重启误报全员掉线
		select {
		case <-h.alertStopCh:
			return
		case <-time.After(25 * time.Second):
		}

		ticker := time.NewTicker(15 * time.Second)
		defer ticker.Stop()

		for {
			select {
			case <-h.alertStopCh:
				return
			case <-ticker.C:
				h.checkClusterAlertsOnce()
			}
		}
	}()
}

// StopAlertMonitor 优雅停止主控统一集群告警巡检循环。
func (h *Hub) StopAlertMonitor() {
	h.alertStopOnce.Do(func() {
		close(h.alertStopCh)
	})
}

func (h *Hub) checkClusterAlertsOnce() {
	aCfg := h.store.GetAlertConfig()
	if !aCfg.Enabled || !aCfg.ClusterMonitorEnabled {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	nodes, err := h.ListNodeSummaries(ctx, "")
	if err != nil {
		return
	}

	graceSec := aCfg.OfflineGraceSec
	if graceSec < 30 {
		graceSec = 60
	}
	now := time.Now()
	nowUnix := now.Unix()

	for _, n := range nodes {
		// 1. 远程节点掉线 / 恢复上线监测（仅针对曾成功上线过的节点，未安装的待接入节点不误报）
		if !n.IsLocal && aCfg.NotifyNodeOffline && n.LastSeen > 0 {
			offlineFor := nowUnix - n.LastSeen
			h.alertMu.Lock()
			wasNotified := h.offlineNotified[n.ID]
			h.alertMu.Unlock()

			if !n.Online && offlineFor >= int64(graceSec) && !wasNotified {
				title := fmt.Sprintf("🔴 FlowMaster 节点掉线告警：%s", n.Name)
				text := fmt.Sprintf("%s\n节点：%s (%s)\n分组：%s\n已离线时长：%d 秒\n检测时间：%s",
					title, n.Name, n.ID, fallbackStr(n.GroupName, "未分组"), offlineFor, now.Format("2006-01-02 15:04:05"))
				if err := h.quotaSvc.DispatchClusterAlert(ctx, "cluster_node_offline", title, text); err == nil {
					h.alertMu.Lock()
					h.offlineNotified[n.ID] = true
					h.alertMu.Unlock()
				}
			} else if n.Online && wasNotified {
				title := fmt.Sprintf("🟢 FlowMaster 节点已恢复上线：%s", n.Name)
				text := fmt.Sprintf("%s\n节点：%s (%s)\n分组：%s\n当前版本：v%s\n恢复时间：%s",
					title, n.Name, n.ID, fallbackStr(n.GroupName, "未分组"), n.Version, now.Format("2006-01-02 15:04:05"))
				if err := h.quotaSvc.DispatchClusterAlert(ctx, "cluster_node_recovered", title, text); err == nil {
					h.alertMu.Lock()
					delete(h.offlineNotified, n.ID)
					h.alertMu.Unlock()
				}
			}
		}

		if !n.Online {
			continue
		}

		// 2. 远程节点月度流量配额预警 / 超限统一托管告警（本机已由 quotaSvc.CheckAndNotify 负责，此处不重复发送）
		if !n.IsLocal && aCfg.NotifyRemoteQuota && n.Quota.Enabled && n.Quota.LimitBytes > 0 {
			giB := float64(1024 * 1024 * 1024)
			if n.Quota.OverLimit {
				key := fmt.Sprintf("quota_limit:%s:%s", n.ID, n.Quota.CycleStart)
				if h.allowAlertWithCooldown(key, 12*time.Hour, now) {
					title := fmt.Sprintf("🚨 FlowMaster 远程节点流量已超额：%s", n.Name)
					text := fmt.Sprintf("%s\n节点：%s (%s)\n周期：%s ~ %s\n已用：%.2f GiB / %.2f GiB (%.1f%%)",
						title, n.Name, fallbackStr(n.GroupName, "未分组"), n.Quota.CycleStart, n.Quota.CycleEnd,
						float64(n.Quota.UsedBytes)/giB, float64(n.Quota.LimitBytes)/giB, n.Quota.UsagePercent)
					_ = h.quotaSvc.DispatchClusterAlert(ctx, "cluster_quota_exceeded", title, text)
				}
			} else if n.Quota.OverWarn {
				key := fmt.Sprintf("quota_warn:%s:%s", n.ID, n.Quota.CycleStart)
				if h.allowAlertWithCooldown(key, 12*time.Hour, now) {
					title := fmt.Sprintf("⚠️ FlowMaster 远程节点流量预警：%s", n.Name)
					text := fmt.Sprintf("%s\n节点：%s (%s)\n周期：%s ~ %s\n已用：%.2f GiB / %.2f GiB (%.1f%%，预警线 %d%%)",
						title, n.Name, fallbackStr(n.GroupName, "未分组"), n.Quota.CycleStart, n.Quota.CycleEnd,
						float64(n.Quota.UsedBytes)/giB, float64(n.Quota.LimitBytes)/giB, n.Quota.UsagePercent, n.Quota.WarnPercent)
					_ = h.quotaSvc.DispatchClusterAlert(ctx, "cluster_quota_warning", title, text)
				}
			}
		}

		// 3. 硬盘与内存高水位统一预警（覆盖主控本机与全部在线远程节点）
		if aCfg.DiskWarnPercent > 0 && n.Host.DiskTotalBytes > 0 && n.Host.DiskPercent >= float64(aCfg.DiskWarnPercent) {
			key := fmt.Sprintf("disk:%s", n.ID)
			if h.allowAlertWithCooldown(key, 6*time.Hour, now) {
				giB := float64(1024 * 1024 * 1024)
				title := fmt.Sprintf("⚠️ FlowMaster 硬盘空间不足预警：%s (%.1f%%)", n.Name, n.Host.DiskPercent)
				text := fmt.Sprintf("%s\n节点：%s (%s)\n根分区已用：%.1f GiB / %.1f GiB (%.1f%%，阈值 %d%%)\n时间：%s",
					title, n.Name, fallbackStr(n.GroupName, "未分组"),
					float64(n.Host.DiskUsedBytes)/giB, float64(n.Host.DiskTotalBytes)/giB,
					n.Host.DiskPercent, aCfg.DiskWarnPercent, now.Format("2006-01-02 15:04:05"))
				_ = h.quotaSvc.DispatchClusterAlert(ctx, "cluster_disk_high", title, text)
			}
		}

		if aCfg.MemWarnPercent > 0 && n.Host.MemTotalBytes > 0 && n.Host.MemPercent >= float64(aCfg.MemWarnPercent) {
			key := fmt.Sprintf("mem:%s", n.ID)
			if h.allowAlertWithCooldown(key, 6*time.Hour, now) {
				giB := float64(1024 * 1024 * 1024)
				title := fmt.Sprintf("⚠️ FlowMaster 内存占用过高预警：%s (%.1f%%)", n.Name, n.Host.MemPercent)
				text := fmt.Sprintf("%s\n节点：%s (%s)\n内存已用：%.2f GiB / %.2f GiB (%.1f%%，阈值 %d%%)\n时间：%s",
					title, n.Name, fallbackStr(n.GroupName, "未分组"),
					float64(n.Host.MemUsedBytes)/giB, float64(n.Host.MemTotalBytes)/giB,
					n.Host.MemPercent, aCfg.MemWarnPercent, now.Format("2006-01-02 15:04:05"))
				_ = h.quotaSvc.DispatchClusterAlert(ctx, "cluster_mem_high", title, text)
			}
		}
	}
}

func (h *Hub) allowAlertWithCooldown(key string, cooldown time.Duration, now time.Time) bool {
	h.alertMu.Lock()
	defer h.alertMu.Unlock()
	if last, ok := h.alertCooldown[key]; ok && now.Sub(last) < cooldown {
		return false
	}
	h.alertCooldown[key] = now
	return true
}

func fallbackStr(v, def string) string {
	if strings.TrimSpace(v) == "" {
		return def
	}
	return v
}
