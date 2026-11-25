package collector

import "testing"

func TestParseProcStatCPUAndMemInfo(t *testing.T) {
	stat1 := []byte("cpu  100 0 50 850 0 0 0 0 0 0\ncpu0 100 0 50 850 0 0 0 0 0 0\n")
	stat2 := []byte("cpu  150 0 100 1050 0 0 0 0 0 0\n")

	t1, i1, ok1 := parseProcStatCPU(stat1)
	t2, i2, ok2 := parseProcStatCPU(stat2)
	if !ok1 || !ok2 {
		t.Fatalf("expected valid /proc/stat parse")
	}
	dTotal := t2 - t1
	dIdle := i2 - i1
	pct := float64(dTotal-dIdle) / float64(dTotal) * 100
	if round1(pct) != 33.3 {
		t.Fatalf("expected ~33.3%% CPU, got %.1f%%", pct)
	}

	memRaw := []byte("MemTotal:        4096000 kB\nMemFree:          512000 kB\nMemAvailable:    2048000 kB\n")
	used, total, ok := parseProcMemInfo(memRaw)
	if !ok || total != 4096000*1024 || used != 2048000*1024 {
		t.Fatalf("unexpected meminfo parse: used=%d total=%d ok=%v", used, total, ok)
	}
}
