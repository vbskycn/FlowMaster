package collector

import (
	"bufio"
	"bytes"
	"math"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/vbskycn/flowmaster/internal/model"
)

// HostMetricsSampler 以零子进程方式采集主机 CPU、内存与根分区硬盘占用，内置 2 秒缓存防高频重复读取。
type HostMetricsSampler struct {
	mu           sync.Mutex
	hasBaseline  bool
	prevTotal    uint64
	prevIdle     uint64
	lastSampleAt time.Time
	cached       model.HostMetrics
}

func NewHostMetricsSampler() *HostMetricsSampler {
	s := &HostMetricsSampler{}
	if total, idle, ok := readProcStatCPU("/proc/stat"); ok {
		s.hasBaseline = true
		s.prevTotal = total
		s.prevIdle = idle
	}
	return s
}

// Sample 返回最近 2 秒内的 CPU、内存与硬盘使用率快照。
func (s *HostMetricsSampler) Sample() model.HostMetrics {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	if !s.lastSampleAt.IsZero() && now.Sub(s.lastSampleAt) < 2*time.Second {
		return s.cached
	}

	m := model.HostMetrics{
		CPUCores: runtime.NumCPU(),
	}

	if total, idle, ok := readProcStatCPU("/proc/stat"); ok {
		if s.hasBaseline && total > s.prevTotal {
			dTotal := total - s.prevTotal
			var dIdle uint64
			if idle >= s.prevIdle {
				dIdle = idle - s.prevIdle
			}
			if dTotal > 0 {
				busy := float64(dTotal-min(dTotal, dIdle)) / float64(dTotal) * 100
				m.CPUPercent = round1(clampPercent(busy))
			}
		}
		s.hasBaseline = true
		s.prevTotal = total
		s.prevIdle = idle
	}

	if used, total, ok := readProcMemInfo("/proc/meminfo"); ok && total > 0 {
		m.MemUsedBytes = used
		m.MemTotalBytes = total
		m.MemPercent = round1(clampPercent(float64(used) / float64(total) * 100))
	}

	if used, total, ok := readRootDiskUsage("/"); ok && total > 0 {
		m.DiskUsedBytes = used
		m.DiskTotalBytes = total
		m.DiskPercent = round1(clampPercent(float64(used) / float64(total) * 100))
	}

	s.cached = m
	s.lastSampleAt = now
	return m
}

func readProcStatCPU(path string) (total uint64, idle uint64, ok bool) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, 0, false
	}
	return parseProcStatCPU(raw)
}

func parseProcStatCPU(raw []byte) (total uint64, idle uint64, ok bool) {
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if !strings.HasPrefix(line, "cpu ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 5 {
			return 0, 0, false
		}
		var vals []uint64
		for _, f := range fields[1:] {
			v, err := strconv.ParseUint(f, 10, 64)
			if err != nil {
				return 0, 0, false
			}
			vals = append(vals, v)
			total += v
		}
		// idle = idle(index 3) + iowait(index 4，若存在)
		idle = vals[3]
		if len(vals) > 4 {
			idle += vals[4]
		}
		return total, idle, total > 0
	}
	return 0, 0, false
}

func readProcMemInfo(path string) (used uint64, total uint64, ok bool) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0, 0, false
	}
	return parseProcMemInfo(raw)
}

func parseProcMemInfo(raw []byte) (used uint64, total uint64, ok bool) {
	var memTotalKB, memAvailKB, memFreeKB, buffersKB, cachedKB uint64
	var hasAvail bool

	scanner := bufio.NewScanner(bytes.NewReader(raw))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		v, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			continue
		}
		switch fields[0] {
		case "MemTotal:":
			memTotalKB = v
		case "MemAvailable:":
			memAvailKB = v
			hasAvail = true
		case "MemFree:":
			memFreeKB = v
		case "Buffers:":
			buffersKB = v
		case "Cached:":
			cachedKB = v
		}
	}
	if memTotalKB == 0 {
		return 0, 0, false
	}
	availKB := memAvailKB
	if !hasAvail {
		availKB = memFreeKB + buffersKB + cachedKB
	}
	if availKB > memTotalKB {
		availKB = memTotalKB
	}
	return (memTotalKB - availKB) * 1024, memTotalKB * 1024, true
}

func clampPercent(v float64) float64 {
	if v < 0 {
		return 0
	}
	if v > 100 {
		return 100
	}
	return v
}

func round1(v float64) float64 {
	return math.Round(v*10) / 10
}
