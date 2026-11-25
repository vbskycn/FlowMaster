package web

import (
	"fmt"
	"math"
	"net/http"
	"runtime"
	"strings"
	"time"

	flowmaster "github.com/vbskycn/flowmaster"
	"github.com/vbskycn/flowmaster/internal/collector"
	"github.com/vbskycn/flowmaster/internal/model"
)

// registerLegacyCompatRoutes 注册 100% 兼容 FlowMaster v1.x 的 /api/* 路由。
func (s *Server) registerLegacyCompatRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/version", s.handleLegacyVersion)
	mux.HandleFunc("GET /api/interfaces", s.requireViewAccess(s.handleLegacyInterfaces))
	mux.HandleFunc("GET /api/stats/{interface}/{period}", s.requireViewAccess(s.handleLegacyStats))
	mux.HandleFunc("GET /api/stats/{interface}/range/{startDate}/{endDate}", s.requireViewAccess(s.handleLegacyRange))
	mux.HandleFunc("GET /api/cache/stats", s.requireViewAccess(s.handleLegacyCacheStats))
	mux.HandleFunc("POST /api/cache/clear", s.requireLegacyAdmin(s.handleLegacyCacheClear))
	mux.HandleFunc("GET /api/system/memory", s.requireViewAccess(s.handleLegacyMemory))
	mux.HandleFunc("GET /api/system/status", s.requireViewAccess(s.handleLegacySystemStatus))
	mux.HandleFunc("GET /api/test/vnstat", s.requireLegacyAdmin(s.handleLegacyTestVnstat))
}

func (s *Server) handleLegacyVersion(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{
		"version": flowmaster.AppVersion(),
	}
	if s.cfg.InstanceToken != "" && timingSafeEqualStr(s.cfg.InstanceToken, r.Header.Get("X-FlowMaster-Instance-Token")) {
		resp["instanceTokenMatched"] = true
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleLegacyInterfaces(w http.ResponseWriter, r *http.Request) {
	list, err := s.engine.ListInterfaces(r.Context(), false)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "无法读取网络接口，请检查服务状态"})
		return
	}
	names := make([]string, 0, len(list))
	for _, item := range list {
		names = append(names, item.Name)
	}
	writeJSON(w, http.StatusOK, map[string]any{"interfaces": names})
}

func (s *Server) handleLegacyStats(w http.ResponseWriter, r *http.Request) {
	iface := r.PathValue("interface")
	period := r.PathValue("period")
	if !collector.IsValidInterfaceName(iface) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的接口名称"})
		return
	}
	switch period {
	case "l":
		_, latest, err := s.engine.GetRealtimeHistory(r.Context(), iface)
		if err != nil {
			writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "暂时无法读取实时流量统计"})
			return
		}
		lines := []string{
			fmt.Sprintf("正在采样 %s (实时速率)", iface),
			fmt.Sprintf("  接收 %10.2f Mb/秒 %10.0f 包/秒", latest.RxMbps, latest.RxPacketsPerSec),
			fmt.Sprintf("  发送 %10.2f Mb/秒 %10.0f 包/秒", latest.TxMbps, latest.TxPacketsPerSec),
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"data":      lines,
			"timestamp": latest.Timestamp,
			"stale":     latest.Stale,
			"ageMs":     latest.AgeMs,
		})
		return
	case "5", "h", "d", "m", "y":
	default:
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的时间周期"})
		return
	}

	limitMap := map[string]int{"5": 12, "h": 12, "d": 12, "m": 24, "y": 10}
	unitMap := map[string]string{"5": "MiB", "h": "MiB", "d": "GiB", "m": "GiB", "y": "TiB"}
	res, err := s.engine.QueryStats(r.Context(), iface, period, "", limitMap[period])
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "暂时无法读取流量统计"})
		return
	}

	writeJSON(w, http.StatusOK, buildLegacyStatsPayload(iface, period, unitMap[period], res.Points))
}

func (s *Server) handleLegacyRange(w http.ResponseWriter, r *http.Request) {
	iface := r.PathValue("interface")
	startStr := r.PathValue("startDate")
	endStr := r.PathValue("endDate")
	if !collector.IsValidInterfaceName(iface) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的接口名称"})
		return
	}
	startDate, ok1 := parseStrictISODate(startStr)
	endDate, ok2 := parseStrictISODate(endStr)
	if !ok1 || !ok2 {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "无效的日期格式"})
		return
	}
	if startDate.After(endDate) {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "开始日期不能晚于结束日期"})
		return
	}
	days := int(endDate.Sub(startDate).Hours()/24) + 1
	if days > s.cfg.MaxRangeDays {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": fmt.Sprintf("日期范围不能超过 %d 天", s.cfg.MaxRangeDays)})
		return
	}

	res, err := s.engine.QueryRange(r.Context(), iface, startStr, endStr, "")
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "暂时无法读取日期范围统计"})
		return
	}
	writeJSON(w, http.StatusOK, buildLegacyStatsPayload(iface, "d", "GiB", res.Points))
}

func buildLegacyStatsPayload(iface, period, targetUnit string, points []model.TrafficPoint) map[string]any {
	const mib = 1024.0 * 1024.0
	type seriesPoint struct {
		Label string  `json:"label"`
		Rx    float64 `json:"rx"`
		Tx    float64 `json:"tx"`
		Total float64 `json:"total"`
	}
	sPoints := make([]seriesPoint, 0, len(points))
	colLabel := map[string]string{"5": "时间", "h": "小时", "d": "日期", "m": "月份", "y": "年份"}[period]
	if colLabel == "" {
		colLabel = "日期"
	}

	lines := []string{
		fmt.Sprintf(" %s", iface),
		fmt.Sprintf("%s\t| 接收(%s)\t| 发送(%s)\t| 总计(%s)\t| 平均速率", colLabel, targetUnit, targetUnit, targetUnit),
		"------------------------+-------------+-------------+---------------",
	}

	for _, p := range points {
		rxMiB := float64(p.RxBytes) / mib
		txMiB := float64(p.TxBytes) / mib
		totMiB := float64(p.TotalBytes) / mib
		sPoints = append(sPoints, seriesPoint{
			Label: p.Label,
			Rx:    math.Round(rxMiB*10000) / 10000,
			Tx:    math.Round(txMiB*10000) / 10000,
			Total: math.Round(totMiB*10000) / 10000,
		})
		lines = append(lines, fmt.Sprintf(" %s | %s | %s | %s | %.2f kb/秒",
			p.Label,
			formatBytesToUnitText(p.RxBytes, targetUnit),
			formatBytesToUnitText(p.TxBytes, targetUnit),
			formatBytesToUnitText(p.TotalBytes, targetUnit),
			p.AvgBps/1000.0,
		))
	}

	return map[string]any{
		"data": lines,
		"series": map[string]any{
			"unit":   "MiB",
			"points": sPoints,
		},
	}
}

func formatBytesToUnitText(bytesVal int64, unit string) string {
	val := float64(bytesVal) / (1024 * 1024)
	switch unit {
	case "GiB":
		val /= 1024
	case "TiB":
		val /= 1024 * 1024
	}
	if val == 0 || math.Abs(val) >= 0.01 {
		return fmt.Sprintf("%.2f %s", val, unit)
	}
	decimals := min(8, max(3, int(math.Ceil(-math.Log10(math.Abs(val))))+2))
	return fmt.Sprintf("%.*f %s", decimals, val, unit)
}

func (s *Server) handleLegacyCacheStats(w http.ResponseWriter, r *http.Request) {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	writeJSON(w, http.StatusOK, map[string]any{
		"hits":        0,
		"misses":      0,
		"sets":        0,
		"deletes":     0,
		"rejected":    0,
		"hitRate":     "100.00%",
		"size":        1,
		"maxSize":     100,
		"memoryUsage": fmt.Sprintf("%.2fMB", float64(ms.Alloc)/1024/1024),
		"maxMemory":   "50.00MB",
	})
}

func (s *Server) handleLegacyCacheClear(w http.ResponseWriter, r *http.Request) {
	s.engine.ClearCaches()
	writeJSON(w, http.StatusOK, map[string]any{"message": "缓存已清空"})
}

func (s *Server) handleLegacyMemory(w http.ResponseWriter, r *http.Request) {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	writeJSON(w, http.StatusOK, map[string]any{
		"rss":         fmt.Sprintf("%.2fMB", float64(ms.Sys)/1024/1024),
		"heapTotal":   fmt.Sprintf("%.2fMB", float64(ms.HeapSys)/1024/1024),
		"heapUsed":    fmt.Sprintf("%.2fMB", float64(ms.HeapAlloc)/1024/1024),
		"external":    "0.00MB",
		"cacheMemory": fmt.Sprintf("%.2fMB", float64(ms.Alloc)/1024/1024),
	})
}

func (s *Server) handleLegacySystemStatus(w http.ResponseWriter, r *http.Request) {
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	vnAvail, vnVer := s.engine.VnstatStatus(r.Context())
	var vnErr any
	if !vnAvail {
		vnErr = "vnstat 命令不可用（当前内置内核引擎正常运行）"
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"server": map[string]any{
			"uptime":   time.Since(s.startedAt).Seconds(),
			"version":  runtime.Version(),
			"platform": runtime.GOOS,
			"arch":     runtime.GOARCH,
			"memory": map[string]any{
				"rss":       ms.Sys,
				"heapTotal": ms.HeapSys,
				"heapUsed":  ms.HeapAlloc,
			},
		},
		"vnstat": map[string]any{
			"available": vnAvail,
			"version":   vnVer,
			"error":     vnErr,
		},
		"timestamp": time.Now().UTC().Format(time.RFC3339),
	})
}

func (s *Server) handleLegacyTestVnstat(w http.ResponseWriter, r *http.Request) {
	tests := []struct {
		name string
		args []string
	}{
		{"version", []string{"--version"}},
		{"iflist", []string{"--iflist"}},
		{"help", []string{"--help"}},
	}
	results := make(map[string]any, len(tests))
	for _, t := range tests {
		out, err := s.vnstat.Run(r.Context(), t.args...)
		if err != nil {
			results[t.name] = map[string]any{"success": false, "error": "命令执行失败"}
		} else {
			results[t.name] = map[string]any{"success": true, "output": strings.TrimSpace(out)}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"timestamp": time.Now().UTC().Format(time.RFC3339),
		"results":   results,
	})
}
