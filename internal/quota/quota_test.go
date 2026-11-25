package quota

import (
	"testing"
	"time"
)

func TestComputeCycleWindowClampAndRollover(t *testing.T) {
	loc := time.Local
	// 当前 3 月 10 日，重置日 15 号 -> 周期应为 2月15日 ~ 3月14日
	now1 := time.Date(2026, 3, 10, 12, 0, 0, 0, loc)
	s1, e1, total1, _ := ComputeCycleWindow(now1, 15)
	if s1.Format("2006-01-02") != "2026-02-15" || e1.Format("2006-01-02") != "2026-03-14" || total1 != 28 {
		t.Fatalf("unexpected cycle 1: %s ~ %s (%d days)", s1.Format("2006-01-02"), e1.Format("2006-01-02"), total1)
	}

	// 重置日 31 号在 2 月（平年 28 天）自动收敛为 2月28日
	now2 := time.Date(2026, 2, 28, 8, 0, 0, 0, loc)
	s2, e2, _, _ := ComputeCycleWindow(now2, 31)
	if s2.Format("2006-01-02") != "2026-02-28" || e2.Format("2006-01-02") != "2026-03-30" {
		t.Fatalf("unexpected clamped cycle 2: %s ~ %s", s2.Format("2006-01-02"), e2.Format("2006-01-02"))
	}
}

func TestSSRFTargetValidation(t *testing.T) {
	if _, err := validateTargetURL("http://127.0.0.1:8080/hook", false); err == nil {
		t.Fatalf("loopback URL should be blocked when allowPrivate=false")
	}
	if _, err := validateTargetURL("http://169.254.169.254/latest/meta-data/", false); err == nil {
		t.Fatalf("cloud metadata link-local IP should be blocked")
	}
	if _, err := validateTargetURL("http://192.168.1.50:9000/hook", false); err == nil {
		t.Fatalf("RFC1918 LAN IP should be blocked by default")
	}
	if _, err := validateTargetURL("http://192.168.1.50:9000/hook", true); err != nil {
		t.Fatalf("RFC1918 LAN IP should be allowed when allowPrivate=true: %v", err)
	}
	if _, err := validateTargetURL("https://hooks.example.com/notify", false); err != nil {
		t.Fatalf("public HTTPS URL should pass: %v", err)
	}
}
