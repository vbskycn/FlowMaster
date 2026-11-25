//go:build linux

package collector

import "syscall"

func readRootDiskUsage(mountPath string) (used uint64, total uint64, ok bool) {
	var st syscall.Statfs_t
	if err := syscall.Statfs(mountPath, &st); err != nil {
		return 0, 0, false
	}
	if st.Blocks == 0 || st.Bsize <= 0 {
		return 0, 0, false
	}
	bsize := uint64(st.Bsize)
	total = st.Blocks * bsize
	free := st.Bfree * bsize
	if free > total {
		free = total
	}
	return total - free, total, true
}
