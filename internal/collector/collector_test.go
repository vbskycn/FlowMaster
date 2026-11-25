package collector

import (
	"bufio"
	"math"
	"strings"
	"testing"
)

func TestParseProcNetDevReader(t *testing.T) {
	sample := `Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 123456     100    0    0    0     0          0         0   123456     100    0    0    0     0       0          0
  eth0: 10485760   8500    0    0    0     0          0         0  5242880    4200    0    0    0     0       0          0
docker0: 2048      20     0    0    0     0          0         0     4096      30    0    0    0     0       0          0
`
	parsed, err := ParseProcNetDevReader(bufio.NewScanner(strings.NewReader(sample)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if _, hasLo := parsed["lo"]; hasLo {
		t.Fatalf("lo interface must be skipped")
	}
	eth0, ok := parsed["eth0"]
	if !ok {
		t.Fatalf("expected eth0 in parsed counters")
	}
	if eth0.RxBytes != 10485760 || eth0.TxBytes != 5242880 || eth0.RxPackets != 8500 || eth0.TxPackets != 4200 {
		t.Fatalf("unexpected eth0 counters: %+v", eth0)
	}
}

func TestComputeCounterDelta(t *testing.T) {
	const maxCap = 10 * 1024 * 1024 * 1024
	// 正常单调递增
	if got := ComputeCounterDelta(1000, 3500, maxCap); got != 2500 {
		t.Fatalf("expected 2500, got %d", got)
	}
	// 32 位回绕
	prev32 := uint64(math.MaxUint32 - 99)
	if got := ComputeCounterDelta(prev32, 200, maxCap); got != 300 {
		t.Fatalf("expected 300 across 32-bit wrap, got %d", got)
	}
	// 64 位大计数归零重置（取合理新计数）
	if got := ComputeCounterDelta(90_000_000_000, 4096, maxCap); got != 4096 {
		t.Fatalf("expected 4096 after reset, got %d", got)
	}
	// 异常巨额跳变保护
	if got := ComputeCounterDelta(100, maxCap+5000, maxCap); got != 0 {
		t.Fatalf("expected 0 on implausible spike, got %d", got)
	}
}

func TestParseVnstatJSONAndRealtime(t *testing.T) {
	rawJSON := `{
		"vnstatversion": "2.13",
		"jsonversion": "2",
		"interfaces": [{
			"name": "ens3",
			"alias": "WAN",
			"traffic": {
				"fiveminute": [{"date":{"year":2026,"month":11,"day":25},"time":{"hour":14,"minute":5},"rx":1048576,"tx":2097152}],
				"hour": [{"date":{"year":2026,"month":11,"day":25},"time":{"hour":14,"minute":0},"rx":10485760,"tx":5242880}],
				"day": [{"date":{"year":2026,"month":11,"day":25},"rx":1073741824,"tx":536870912}],
				"month": [{"date":{"year":2026,"month":11,"day":1},"rx":10737418240,"tx":5368709120}],
				"year": [{"date":{"year":2026,"month":1,"day":1},"rx":10737418240,"tx":5368709120}]
			}
		}]
	}`
	dumps, err := ParseVnstatJSON(rawJSON)
	if err != nil {
		t.Fatalf("ParseVnstatJSON failed: %v", err)
	}
	if len(dumps) != 1 || dumps[0].Name != "ens3" {
		t.Fatalf("unexpected dumps: %+v", dumps)
	}
	if len(dumps[0].Day) != 1 || dumps[0].Day[0].Label != "2026-11-25" || dumps[0].Day[0].TotalBytes != 1610612736 {
		t.Fatalf("unexpected day point: %+v", dumps[0].Day)
	}

	trText := `Sampling ens3 (2 seconds average)
500 packets sampled in 2 seconds
Traffic average for ens3
      rx        12.50 Mbit/s           150 packets/s
      tx         1.00 MiB/s            100 packets/s
`
	rt, err := ParseVnstatRealtimeOutput("ens3", trText, 1700000000000)
	if err != nil {
		t.Fatalf("ParseVnstatRealtimeOutput failed: %v", err)
	}
	if math.Abs(rt.RxMbps-12.50) > 0.01 {
		t.Fatalf("expected RxMbps 12.50, got %f", rt.RxMbps)
	}
	// 1 MiB/s = 8 * 1048576 / 1e6 = 8.388608 Mbps
	if math.Abs(rt.TxMbps-8.3886) > 0.01 {
		t.Fatalf("expected TxMbps ~8.3886, got %f", rt.TxMbps)
	}
}

func TestInterfaceClassificationAndSort(t *testing.T) {
	names := []string{"veth99a", "docker0", "ens3", "eth0", "br-1234"}
	SortInterfaceNames(names, "")
	if names[0] != "eth0" || names[1] != "ens3" {
		t.Fatalf("physical interfaces should sort before virtual: %v", names)
	}
	if !IsVirtualInterface("veth99a", "") || !IsVirtualInterface("docker0", "") || IsVirtualInterface("eth0", "") {
		t.Fatalf("unexpected virtual classification")
	}
}
