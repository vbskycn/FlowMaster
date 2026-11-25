package collector

import (
	"bufio"
	"fmt"
	"math"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

var validIfaceRegex = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9:._-]{0,63}$`)

var virtualPrefixPatterns = []string{
	"veth", "docker", "br-", "virbr", "cali", "flannel", "cni",
	"tun", "tap", "wg", "tailscale", "zt", "sit", "ip6tnl", "gre", "erspan", "dummy", "ifb", "lxcbr", "lxdbr",
}

// IsValidInterfaceName 校验网卡名称合法性，拒绝任何特殊字符与路径成分。
func IsValidInterfaceName(name string) bool {
	return validIfaceRegex.MatchString(name)
}

// IsVirtualInterface 判断网卡是否属于容器桥接、隧道或虚拟接口。
func IsVirtualInterface(name string, sysClassNetPath string) bool {
	lower := strings.ToLower(strings.TrimSpace(name))
	if lower == "lo" {
		return true
	}
	for _, prefix := range virtualPrefixPatterns {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	// Linux /sys/class/net/<iface> 若符号链接指向 /devices/virtual/，也判定为虚拟接口（保留 bond/vlan 可按需在后台显式开启）。
	if sysClassNetPath != "" {
		linkTarget, err := os.Readlink(filepath.Join(sysClassNetPath, name))
		if err == nil && strings.Contains(linkTarget, "/devices/virtual/") {
			if !strings.HasPrefix(lower, "bond") && !strings.HasPrefix(lower, "eth") && !strings.HasPrefix(lower, "en") {
				return true
			}
		}
	}
	return false
}

// InterfacePriority 返回默认排序优先级，使物理主网卡优先排在最前。
func InterfacePriority(name string, isVirtual bool) int {
	if isVirtual {
		return 100
	}
	switch {
	case strings.HasPrefix(name, "eth"):
		return 1
	case strings.HasPrefix(name, "ens"):
		return 2
	case strings.HasPrefix(name, "enp"):
		return 3
	case strings.HasPrefix(name, "eno"):
		return 4
	case strings.HasPrefix(name, "wlan"), strings.HasPrefix(name, "wlp"):
		return 10
	case strings.HasPrefix(name, "bond"):
		return 11
	default:
		return 30
	}
}

// SortInterfaceNames 按物理网卡优先、同优先级字典序稳定排序。
func SortInterfaceNames(names []string, sysClassNetPath string) {
	sort.Slice(names, func(i, j int) bool {
		vi := IsVirtualInterface(names[i], sysClassNetPath)
		vj := IsVirtualInterface(names[j], sysClassNetPath)
		pi := InterfacePriority(names[i], vi)
		pj := InterfacePriority(names[j], vj)
		if pi != pj {
			return pi < pj
		}
		return names[i] < names[j]
	})
}

// RawNetCounter 保存从 /proc/net/dev 读取的原始累计计数器。
type RawNetCounter struct {
	Name      string
	RxBytes   uint64
	RxPackets uint64
	TxBytes   uint64
	TxPackets uint64
}

// ReadProcNetDev 解析 Linux /proc/net/dev 内容（自动跳过 lo 回环接口）。
func ReadProcNetDev(procPath string) (map[string]RawNetCounter, error) {
	file, err := os.Open(procPath)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return ParseProcNetDevReader(bufio.NewScanner(file))
}

// ParseProcNetDevReader 从文本扫描器解析 /proc/net/dev 格式。
func ParseProcNetDevReader(scanner *bufio.Scanner) (map[string]RawNetCounter, error) {
	result := make(map[string]RawNetCounter)
	lineNo := 0
	for scanner.Scan() {
		lineNo++
		// 前两行为表头
		if lineNo <= 2 {
			continue
		}
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		colonIdx := strings.IndexByte(line, ':')
		if colonIdx <= 0 {
			continue
		}
		name := strings.TrimSpace(line[:colonIdx])
		if name == "lo" || !IsValidInterfaceName(name) {
			continue
		}
		fields := strings.Fields(line[colonIdx+1:])
		// /proc/net/dev 标准列：rx_bytes(0) rx_packets(1) ... tx_bytes(8) tx_packets(9)
		if len(fields) < 10 {
			continue
		}
		rxBytes, err1 := strconv.ParseUint(fields[0], 10, 64)
		rxPkts, err2 := strconv.ParseUint(fields[1], 10, 64)
		txBytes, err3 := strconv.ParseUint(fields[8], 10, 64)
		txPkts, err4 := strconv.ParseUint(fields[9], 10, 64)
		if err1 != nil || err2 != nil || err3 != nil || err4 != nil {
			continue
		}
		result[name] = RawNetCounter{
			Name:      name,
			RxBytes:   rxBytes,
			RxPackets: rxPkts,
			TxBytes:   txBytes,
			TxPackets: txPkts,
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("读取 /proc/net/dev 出错: %w", err)
	}
	return result, nil
}

// ComputeCounterDelta 安全计算两次采样的增量，处理 32 位计数器回绕并防御网卡重置导致的异常巨额跳变。
func ComputeCounterDelta(prev, curr uint64, maxPlausibleDelta uint64) uint64 {
	if curr >= prev {
		delta := curr - prev
		if maxPlausibleDelta > 0 && delta > maxPlausibleDelta {
			return 0
		}
		return delta
	}
	// 处理 32 位无符号计数器回绕
	if prev <= math.MaxUint32 {
		wrapped := (uint64(math.MaxUint32) - prev) + 1 + curr
		if maxPlausibleDelta == 0 || wrapped <= maxPlausibleDelta {
			return wrapped
		}
	}
	// 网卡重建或计数器归零：若新值本身在合理单周期增量范围内，取 curr 作为重置后新流量；否则记 0 防假尖峰。
	if maxPlausibleDelta > 0 && curr <= maxPlausibleDelta {
		return curr
	}
	return 0
}

// InterfaceSysMeta 保存从 /sys/class/net 与标准库读取的网卡附加属性。
type InterfaceSysMeta struct {
	OperState string
	SpeedMbps int
	MAC       string
	IPv4      []string
}

// ReadInterfaceSysMeta 读取指定网卡的状态、协商速率、MAC 与 IPv4 地址列表。
func ReadInterfaceSysMeta(name, sysClassNetPath string) InterfaceSysMeta {
	meta := InterfaceSysMeta{
		OperState: "unknown",
		IPv4:      []string{},
	}
	if sysClassNetPath != "" {
		base := filepath.Join(sysClassNetPath, name)
		if raw, err := os.ReadFile(filepath.Join(base, "operstate")); err == nil {
			if st := strings.TrimSpace(string(raw)); st != "" {
				meta.OperState = st
			}
		}
		if raw, err := os.ReadFile(filepath.Join(base, "speed")); err == nil {
			if sp, convErr := strconv.Atoi(strings.TrimSpace(string(raw))); convErr == nil && sp > 0 {
				meta.SpeedMbps = sp
			}
		}
		if raw, err := os.ReadFile(filepath.Join(base, "address")); err == nil {
			meta.MAC = strings.TrimSpace(string(raw))
		}
	}

	if netIf, err := net.InterfaceByName(name); err == nil {
		if meta.MAC == "" && len(netIf.HardwareAddr) > 0 {
			meta.MAC = netIf.HardwareAddr.String()
		}
		if meta.OperState == "unknown" {
			if netIf.Flags&net.FlagUp != 0 {
				meta.OperState = "up"
			} else {
				meta.OperState = "down"
			}
		}
		if addrs, addrErr := netIf.Addrs(); addrErr == nil {
			for _, addr := range addrs {
				var ip net.IP
				switch v := addr.(type) {
				case *net.IPNet:
					ip = v.IP
				case *net.IPAddr:
					ip = v.IP
				}
				if ip4 := ip.To4(); ip4 != nil && !ip4.IsLoopback() {
					meta.IPv4 = append(meta.IPv4, ip4.String())
				}
			}
		}
	}
	return meta
}
