//go:build !linux

package collector

func readRootDiskUsage(_ string) (used uint64, total uint64, ok bool) {
	return 0, 0, false
}
