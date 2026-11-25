package collector

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"

	"github.com/vbskycn/flowmaster/internal/config"
	"github.com/vbskycn/flowmaster/internal/logger"
	"github.com/vbskycn/flowmaster/internal/model"
	"github.com/vbskycn/flowmaster/internal/store"
)

const (
	// 单次秒级采样最大合理增量阈值：100 Gbps * 10s ≈ 125 GiB，用于过滤异常计数器跳变。
	maxPlausibleSampleBytes = 125 * 1024 * 1024 * 1024
	realtimeHistoryLen      = 60
)

type cachedVnstatDump struct {
	fetchedAt time.Time
	dumps     map[string]VnstatInterfaceDump
}

// Engine 驱动内核秒级实时采样、SQLite 周期刷盘、SSE 广播以及 SQLite/vnstat 混合查询。
type Engine struct {
	cfg      *config.Config
	store    *store.Store
	vnstat   *VnstatClient
	log      *logger.Manager

	mu              sync.RWMutex
	prevCounters    map[string]RawNetCounter
	prevSampledAt   time.Time
	latestKernel    map[string]RawNetCounter
	realtimeHistory map[string][]model.RealtimeSample
	pendingDeltas   map[string]store.TrafficDelta
	vnstatCache     cachedVnstatDump
	vnstatVerCache  string
	vnstatVerAt     time.Time

	subMu       sync.Mutex
	subscribers map[chan map[string]model.RealtimeSample]struct{}

	stopCh chan struct{}
	doneCh chan struct{}
	once   sync.Once
}

// NewEngine 创建混合流量采集与查询引擎。
func NewEngine(cfg *config.Config, st *store.Store, vn *VnstatClient, log *logger.Manager) *Engine {
	return &Engine{
		cfg:             cfg,
		store:           st,
		vnstat:          vn,
		log:             log,
		prevCounters:    make(map[string]RawNetCounter),
		latestKernel:    make(map[string]RawNetCounter),
		realtimeHistory: make(map[string][]model.RealtimeSample),
		pendingDeltas:   make(map[string]store.TrafficDelta),
		subscribers:     make(map[chan map[string]model.RealtimeSample]struct{}),
		stopCh:          make(chan struct{}),
		doneCh:          make(chan struct{}),
	}
}

// Start 启动后台秒级采样、定时批量落盘与历史保留清理协程。
func (e *Engine) Start(onPeriodicCheck func()) {
	// 初始读取一次内核基准值，避免首次启动把历史累计值误记为增量。
	if counters, err := ReadProcNetDev(e.cfg.ProcNetDevPath); err == nil {
		e.mu.Lock()
		e.prevCounters = counters
		e.latestKernel = counters
		e.prevSampledAt = time.Now()
		e.mu.Unlock()
	}

	go func() {
		defer close(e.doneCh)
		sampleTicker := time.NewTicker(time.Duration(e.cfg.RealtimeIntervalMs) * time.Millisecond)
		flushTicker := time.NewTicker(15 * time.Second)
		pruneTicker := time.NewTicker(6 * time.Hour)
		defer sampleTicker.Stop()
		defer flushTicker.Stop()
		defer pruneTicker.Stop()

		for {
			select {
			case <-e.stopCh:
				e.FlushPending()
				return
			case now := <-sampleTicker.C:
				e.sampleKernelOnce(now)
			case <-flushTicker.C:
				e.FlushPending()
				if onPeriodicCheck != nil {
					onPeriodicCheck()
				}
			case now := <-pruneTicker.C:
				_ = e.store.PruneExpired(e.store.GetSystemSettings(), now)
			}
		}
	}()
}

// Stop 停止后台采集并将尚未落盘的内存增量安全刷入 SQLite。
func (e *Engine) Stop() {
	e.once.Do(func() {
		close(e.stopCh)
		<-e.doneCh
	})
}

func (e *Engine) sampleKernelOnce(now time.Time) {
	counters, err := ReadProcNetDev(e.cfg.ProcNetDevPath)
	if err != nil {
		return
	}

	e.mu.Lock()
	elapsedSec := now.Sub(e.prevSampledAt).Seconds()
	if elapsedSec <= 0 {
		elapsedSec = float64(e.cfg.RealtimeIntervalMs) / 1000.0
	}
	hasPrev := !e.prevSampledAt.IsZero() && len(e.prevCounters) > 0
	e.prevSampledAt = now
	e.latestKernel = counters

	broadcastBatch := make(map[string]model.RealtimeSample, len(counters))
	nowMs := now.UnixMilli()

	if hasPrev {
		for name, curr := range counters {
			prev, ok := e.prevCounters[name]
			if !ok {
				continue
			}
			dRx := ComputeCounterDelta(prev.RxBytes, curr.RxBytes, maxPlausibleSampleBytes)
			dTx := ComputeCounterDelta(prev.TxBytes, curr.TxBytes, maxPlausibleSampleBytes)
			dRxPkt := ComputeCounterDelta(prev.RxPackets, curr.RxPackets, maxPlausibleSampleBytes)
			dTxPkt := ComputeCounterDelta(prev.TxPackets, curr.TxPackets, maxPlausibleSampleBytes)

			if dRx > 0 || dTx > 0 {
				existing := e.pendingDeltas[name]
				existing.RxBytes += int64(dRx)
				existing.TxBytes += int64(dTx)
				e.pendingDeltas[name] = existing
			}

			rxBps := float64(dRx) / elapsedSec
			txBps := float64(dTx) / elapsedSec
			sample := model.RealtimeSample{
				Interface:       name,
				Timestamp:       nowMs,
				RxBytesPerSec:   rxBps,
				TxBytesPerSec:   txBps,
				RxMbps:          (rxBps * 8) / 1_000_000.0,
				TxMbps:          (txBps * 8) / 1_000_000.0,
				RxPacketsPerSec: float64(dRxPkt) / elapsedSec,
				TxPacketsPerSec: float64(dTxPkt) / elapsedSec,
				Stale:           false,
				AgeMs:           0,
				Source:          "kernel",
			}

			hist := append(e.realtimeHistory[name], sample)
			if len(hist) > realtimeHistoryLen {
				hist = hist[len(hist)-realtimeHistoryLen:]
			}
			e.realtimeHistory[name] = hist
			broadcastBatch[name] = sample
		}
	}
	e.prevCounters = counters
	e.mu.Unlock()

	if len(broadcastBatch) > 0 {
		e.broadcastRealtime(broadcastBatch)
	}
}

// FlushPending 将内存暂存增量原子写入 SQLite。
func (e *Engine) FlushPending() {
	e.mu.Lock()
	if len(e.pendingDeltas) == 0 {
		e.mu.Unlock()
		return
	}
	snapshot := e.pendingDeltas
	e.pendingDeltas = make(map[string]store.TrafficDelta)
	e.mu.Unlock()

	if err := e.store.RecordTrafficDeltas(snapshot, time.Now()); err != nil {
		e.log.Error("写入 SQLite 流量统计失败: %v", err)
		// 写入失败时合并回待刷缓冲，防止瞬时锁繁忙丢样本
		e.mu.Lock()
		for k, v := range snapshot {
			cur := e.pendingDeltas[k]
			cur.RxBytes += v.RxBytes
			cur.TxBytes += v.TxBytes
			e.pendingDeltas[k] = cur
		}
		e.mu.Unlock()
	}
}

// SubscribeRealtime 注册 SSE 实时流量订阅通道。
func (e *Engine) SubscribeRealtime() chan map[string]model.RealtimeSample {
	ch := make(chan map[string]model.RealtimeSample, 4)
	e.subMu.Lock()
	e.subscribers[ch] = struct{}{}
	e.subMu.Unlock()
	return ch
}

// UnsubscribeRealtime 注销 SSE 实时流量订阅通道。
func (e *Engine) UnsubscribeRealtime(ch chan map[string]model.RealtimeSample) {
	e.subMu.Lock()
	if _, ok := e.subscribers[ch]; ok {
		delete(e.subscribers, ch)
		close(ch)
	}
	e.subMu.Unlock()
}

func (e *Engine) broadcastRealtime(batch map[string]model.RealtimeSample) {
	e.subMu.Lock()
	defer e.subMu.Unlock()
	for ch := range e.subscribers {
		select {
		case ch <- batch:
		default:
			// 慢消费端丢弃最旧帧，绝不阻塞内核采集循环
		}
	}
}

// VnstatStatus 返回 vnstat 可用性与版本号（带 60 秒缓存减少无意义子进程派生）。
func (e *Engine) VnstatStatus(ctx context.Context) (bool, string) {
	e.mu.RLock()
	if time.Since(e.vnstatVerAt) < 60*time.Second {
		ver := e.vnstatVerCache
		e.mu.RUnlock()
		return ver != "", ver
	}
	e.mu.RUnlock()

	ver, err := e.vnstat.Version(ctx)
	if err != nil {
		ver = ""
	}
	e.mu.Lock()
	e.vnstatVerCache = ver
	e.vnstatVerAt = time.Now()
	e.mu.Unlock()
	return ver != "", ver
}

// ClearCaches 清空引擎内的 vnstat 短期缓存（供管理端手动刷新使用）。
func (e *Engine) ClearCaches() {
	e.mu.Lock()
	e.vnstatCache = cachedVnstatDump{}
	e.vnstatVerAt = time.Time{}
	e.mu.Unlock()
}

func (e *Engine) getVnstatDumpsCached(ctx context.Context) (map[string]VnstatInterfaceDump, error) {
	e.mu.RLock()
	if !e.vnstatCache.fetchedAt.IsZero() && time.Since(e.vnstatCache.fetchedAt) < 25*time.Second {
		cached := e.vnstatCache.dumps
		e.mu.RUnlock()
		return cached, nil
	}
	e.mu.RUnlock()

	dumps, err := e.vnstat.DumpAllJSON(ctx, "")
	if err != nil {
		return nil, err
	}
	mapped := make(map[string]VnstatInterfaceDump, len(dumps))
	for _, d := range dumps {
		mapped[d.Name] = d
	}

	e.mu.Lock()
	e.vnstatCache = cachedVnstatDump{
		fetchedAt: time.Now(),
		dumps:     mapped,
	}
	e.mu.Unlock()
	return mapped, nil
}

// ListInterfaces 汇总所有网卡信息；includeHidden=false 时仅返回前台可见网卡。
func (e *Engine) ListInterfaces(ctx context.Context, includeHidden bool) ([]model.InterfaceInfo, error) {
	settings := e.store.GetSystemSettings()
	overrides, _ := e.store.GetInterfaceOverrides()

	nameSet := make(map[string]struct{})
	sqliteSet := make(map[string]bool)
	vnstatSet := make(map[string]bool)

	e.mu.RLock()
	kernelCopy := make(map[string]RawNetCounter, len(e.latestKernel))
	for k, v := range e.latestKernel {
		kernelCopy[k] = v
		if settings.DataSourceMode != model.SourceModeVnstat {
			nameSet[k] = struct{}{}
		}
	}
	e.mu.RUnlock()

	if len(kernelCopy) == 0 && settings.DataSourceMode != model.SourceModeVnstat {
		if fresh, err := ReadProcNetDev(e.cfg.ProcNetDevPath); err == nil {
			for k, v := range fresh {
				kernelCopy[k] = v
				nameSet[k] = struct{}{}
			}
		}
	}

	if tracked, err := e.store.ListTrackedInterfaces(); err == nil {
		for _, n := range tracked {
			sqliteSet[n] = true
			if settings.DataSourceMode != model.SourceModeVnstat {
				nameSet[n] = struct{}{}
			}
		}
	}

	if settings.DataSourceMode == model.SourceModeVnstat || settings.DataSourceMode == model.SourceModeHybrid {
		if dumps, err := e.getVnstatDumpsCached(ctx); err == nil {
			for n := range dumps {
				vnstatSet[n] = true
				nameSet[n] = struct{}{}
			}
		} else if settings.DataSourceMode == model.SourceModeVnstat {
			if list, lErr := e.vnstat.ListInterfaces(ctx); lErr == nil {
				for _, n := range list {
					vnstatSet[n] = true
					nameSet[n] = struct{}{}
				}
			} else {
				return nil, lErr
			}
		}
	}

	names := make([]string, 0, len(nameSet))
	for n := range nameSet {
		if n != "lo" && IsValidInterfaceName(n) {
			names = append(names, n)
		}
	}
	SortInterfaceNames(names, e.cfg.SysClassNetPath)

	// 将显式指定的默认网卡排在第一位
	if settings.DefaultInterface != "" {
		for idx, n := range names {
			if n == settings.DefaultInterface && idx > 0 {
				copy(names[1:idx+1], names[0:idx])
				names[0] = settings.DefaultInterface
				break
			}
		}
	}

	result := make([]model.InterfaceInfo, 0, len(names))
	for _, name := range names {
		isVirt := IsVirtualInterface(name, e.cfg.SysClassNetPath)
		visible := !settings.HideVirtualInterfaces || !isVirt
		alias := ""
		if ov, ok := overrides[name]; ok {
			alias = ov.Alias
			if ov.Visible != nil {
				visible = *ov.Visible
			}
		}
		if !includeHidden && !visible {
			continue
		}

		sysMeta := ReadInterfaceSysMeta(name, e.cfg.SysClassNetPath)
		kc := kernelCopy[name]
		result = append(result, model.InterfaceInfo{
			Name:          name,
			Alias:         alias,
			IsVirtual:     isVirt,
			Visible:       visible,
			OperState:     sysMeta.OperState,
			SpeedMbps:     sysMeta.SpeedMbps,
			MAC:           sysMeta.MAC,
			IPv4:          sysMeta.IPv4,
			RxBytesKernel: kc.RxBytes,
			TxBytesKernel: kc.TxBytes,
			HasSQLiteData: sqliteSet[name],
			HasVnstatData: vnstatSet[name],
		})
	}
	return result, nil
}

// GetRealtimeHistory 返回指定网卡最近实时样本历史（内核直采优先，非 Linux 回退 vnstat）。
func (e *Engine) GetRealtimeHistory(ctx context.Context, iface string) ([]model.RealtimeSample, model.RealtimeSample, error) {
	if !IsValidInterfaceName(iface) {
		return nil, model.RealtimeSample{}, errors.New("无效的接口名称")
	}
	nowMs := time.Now().UnixMilli()
	staleThresholdMs := int64(max(15000, e.cfg.RealtimeIntervalMs*4))

	e.mu.RLock()
	hist := make([]model.RealtimeSample, len(e.realtimeHistory[iface]))
	copy(hist, e.realtimeHistory[iface])
	e.mu.RUnlock()

	if len(hist) > 0 {
		latest := hist[len(hist)-1]
		latest.AgeMs = max(0, nowMs-latest.Timestamp)
		latest.Stale = latest.AgeMs > staleThresholdMs
		hist[len(hist)-1] = latest
		return hist, latest, nil
	}

	// 内核尚无第二个点（刚启动第 1 秒内）时若 /proc/net/dev 存在该接口，返回零速率初始样本避免无谓阻塞 2 秒
	e.mu.RLock()
	_, inKernel := e.latestKernel[iface]
	e.mu.RUnlock()
	if inKernel {
		initSample := model.RealtimeSample{
			Interface: iface,
			Timestamp: nowMs,
			Source:    "kernel",
			Stale:     false,
			AgeMs:     0,
		}
		return []model.RealtimeSample{initSample}, initSample, nil
	}

	// 无 /proc/net/dev 的环境尝试回退 vnstat -tr
	fallback, err := e.vnstat.SampleRealtimeFallback(ctx, iface)
	if err != nil {
		return nil, model.RealtimeSample{}, err
	}
	return []model.RealtimeSample{fallback}, fallback, nil
}

// QueryStats 按当前引擎模式（sqlite / vnstat / hybrid）查询统计时间序列与汇总指标。
func (e *Engine) QueryStats(ctx context.Context, iface, period, sourceOverride string, limit int) (model.StatsQueryResult, error) {
	if !IsValidInterfaceName(iface) {
		return model.StatsQueryResult{}, errors.New("无效的接口名称")
	}
	// 先将内存缓冲刷盘，确保前端看到的当前 5m/小时/日/月数据即时最新
	e.FlushPending()

	mode := sourceOverride
	if mode == "" {
		mode = e.store.GetSystemSettings().DataSourceMode
	}

	var points []model.TrafficPoint
	usedSource := model.SourceModeSQLite

	switch mode {
	case model.SourceModeSQLite:
		pts, err := e.store.QueryStats(iface, period, limit)
		if err != nil {
			return model.StatsQueryResult{}, err
		}
		points = pts

	case model.SourceModeVnstat:
		pts, err := e.queryVnstatPeriod(ctx, iface, period, limit)
		if err != nil {
			return model.StatsQueryResult{}, err
		}
		points = pts
		usedSource = model.SourceModeVnstat

	default: // hybrid：同一时间桶融合 SQLite 实时落盘与 vnstat 历史账本，无 vnstat 时零报错降级纯 SQLite
		sqlPts, sqlErr := e.store.QueryStats(iface, period, limit)
		vnPts, vnErr := e.queryVnstatPeriod(ctx, iface, period, limit)
		if sqlErr != nil && vnErr != nil {
			return model.StatsQueryResult{}, sqlErr
		}
		if len(vnPts) == 0 {
			points = sqlPts
			usedSource = model.SourceModeSQLite
		} else if len(sqlPts) == 0 {
			points = vnPts
			usedSource = model.SourceModeVnstat
		} else {
			points = mergeTrafficPointSlices(sqlPts, vnPts, limit)
			usedSource = model.SourceModeHybrid
		}
	}

	return model.StatsQueryResult{
		Interface: iface,
		Period:    period,
		Source:    usedSource,
		Points:    points,
		Summary:   summarizePoints(points, period),
		UpdatedAt: time.Now().UnixMilli(),
	}, nil
}

// QueryRange 查询日期区间（YYYY-MM-DD）按日流量。
func (e *Engine) QueryRange(ctx context.Context, iface, startDate, endDate, sourceOverride string) (model.StatsQueryResult, error) {
	if !IsValidInterfaceName(iface) {
		return model.StatsQueryResult{}, errors.New("无效的接口名称")
	}
	e.FlushPending()

	mode := sourceOverride
	if mode == "" {
		mode = e.store.GetSystemSettings().DataSourceMode
	}

	var points []model.TrafficPoint
	usedSource := model.SourceModeSQLite

	filterRange := func(src []model.TrafficPoint) []model.TrafficPoint {
		var out []model.TrafficPoint
		for _, p := range src {
			if p.Label >= startDate && p.Label <= endDate {
				out = append(out, p)
			}
		}
		return out
	}

	switch mode {
	case model.SourceModeSQLite:
		pts, err := e.store.QueryDateRange(iface, startDate, endDate)
		if err != nil {
			return model.StatsQueryResult{}, err
		}
		points = pts
	case model.SourceModeVnstat:
		pts, err := e.queryVnstatPeriod(ctx, iface, "d", 0)
		if err != nil {
			return model.StatsQueryResult{}, err
		}
		points = filterRange(pts)
		usedSource = model.SourceModeVnstat
	default:
		sqlPts, sqlErr := e.store.QueryDateRange(iface, startDate, endDate)
		vnPts, vnErr := e.queryVnstatPeriod(ctx, iface, "d", 0)
		vnFiltered := filterRange(vnPts)
		if sqlErr != nil && vnErr != nil {
			return model.StatsQueryResult{}, sqlErr
		}
		if len(vnFiltered) == 0 {
			points = sqlPts
			usedSource = model.SourceModeSQLite
		} else if len(sqlPts) == 0 {
			points = vnFiltered
			usedSource = model.SourceModeVnstat
		} else {
			points = mergeTrafficPointSlices(sqlPts, vnFiltered, 0)
			usedSource = model.SourceModeHybrid
		}
	}

	return model.StatsQueryResult{
		Interface: iface,
		Period:    "range",
		Source:    usedSource,
		Points:    points,
		Summary:   summarizePoints(points, "d"),
		UpdatedAt: time.Now().UnixMilli(),
	}, nil
}

func (e *Engine) queryVnstatPeriod(ctx context.Context, iface, period string, limit int) ([]model.TrafficPoint, error) {
	dumps, err := e.getVnstatDumpsCached(ctx)
	if err != nil {
		return nil, err
	}
	d, ok := dumps[iface]
	if !ok {
		return []model.TrafficPoint{}, nil
	}
	var pts []model.TrafficPoint
	switch period {
	case "5":
		pts = d.FiveMinute
	case "h":
		pts = d.Hour
	case "d":
		pts = d.Day
	case "m":
		pts = d.Month
	case "y":
		pts = d.Year
	default:
		return nil, fmt.Errorf("不支持的统计周期: %s", period)
	}
	if limit > 0 && len(pts) > limit {
		pts = pts[len(pts)-limit:]
	}
	out := make([]model.TrafficPoint, len(pts))
	copy(out, pts)
	return out, nil
}

// ImportVnstatToSQLite 一键将系统 vnstat 数据库中的全部历史周期数据幂等导入内置 SQLite（对 /var/lib/vnstat 纯只读）。
func (e *Engine) ImportVnstatToSQLite(ctx context.Context) (map[string]int, error) {
	if !e.store.TryLockMaintenance() {
		return nil, errors.New("当前已有备份、恢复或导入任务正在执行，请稍后重试")
	}
	defer e.store.UnlockMaintenance()

	dumps, err := e.vnstat.DumpAllJSON(ctx, "")
	if err != nil {
		return nil, fmt.Errorf("调用 vnstat 导出历史数据失败: %w", err)
	}
	summary := make(map[string]int, len(dumps))
	for _, d := range dumps {
		n, mErr := e.store.MergeVnstatPoints(d.Name, d.FiveMinute, d.Hour, d.Day, d.Month)
		if mErr != nil {
			return summary, fmt.Errorf("合并网卡 %s 历史数据失败: %w", d.Name, mErr)
		}
		summary[d.Name] = n
	}
	e.ClearCaches()
	return summary, nil
}

func mergeTrafficPointSlices(a, b []model.TrafficPoint, limit int) []model.TrafficPoint {
	byKey := make(map[string]model.TrafficPoint, len(a)+len(b))
	keyOf := func(p model.TrafficPoint) string {
		if p.Timestamp > 0 {
			return fmt.Sprintf("ts:%d", p.Timestamp)
		}
		return "lbl:" + p.Label
	}
	for _, p := range a {
		byKey[keyOf(p)] = p
	}
	for _, p := range b {
		k := keyOf(p)
		if existing, ok := byKey[k]; ok {
			rx := max(existing.RxBytes, p.RxBytes)
			tx := max(existing.TxBytes, p.TxBytes)
			existing.RxBytes = rx
			existing.TxBytes = tx
			existing.TotalBytes = rx + tx
			existing.AvgBps = max(existing.AvgBps, p.AvgBps)
			byKey[k] = existing
		} else {
			byKey[k] = p
		}
	}
	merged := make([]model.TrafficPoint, 0, len(byKey))
	for _, v := range byKey {
		merged = append(merged, v)
	}
	sort.Slice(merged, func(i, j int) bool {
		if merged[i].Timestamp != merged[j].Timestamp {
			return merged[i].Timestamp < merged[j].Timestamp
		}
		return merged[i].Label < merged[j].Label
	})
	if limit > 0 && len(merged) > limit {
		merged = merged[len(merged)-limit:]
	}
	return merged
}

func summarizePoints(pts []model.TrafficPoint, period string) model.TrafficSummary {
	var sum model.TrafficSummary
	sum.PointCount = len(pts)
	var peakTotal int64
	for _, p := range pts {
		sum.TotalRxBytes += p.RxBytes
		sum.TotalTxBytes += p.TxBytes
		sum.TotalBytes += p.TotalBytes
		if p.RxBytes > sum.PeakRxBytes {
			sum.PeakRxBytes = p.RxBytes
		}
		if p.TxBytes > sum.PeakTxBytes {
			sum.PeakTxBytes = p.TxBytes
		}
		if p.TotalBytes >= peakTotal {
			peakTotal = p.TotalBytes
			sum.PeakLabel = p.Label
		}
	}
	bucketSec := 3600.0
	switch period {
	case "5":
		bucketSec = 300
	case "h":
		bucketSec = 3600
	case "d":
		bucketSec = 86400
	case "m":
		bucketSec = 30 * 86400
	case "y":
		bucketSec = 365 * 86400
	}
	if len(pts) > 0 && bucketSec > 0 {
		sum.AvgBps = float64(sum.TotalBytes*8) / (float64(len(pts)) * bucketSec)
	}
	return sum
}
