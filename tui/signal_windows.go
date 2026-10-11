package main

import "github.com/shirou/gopsutil/v4/process"

// Windows has no SIGTERM; terminate the processes outright.
// Non-positive PIDs are sentinels, never real processes — skip them.
func quitPIDs(pids []int32) {
	for _, pid := range pids {
		if pid <= 0 {
			continue
		}
		if p, err := process.NewProcess(pid); err == nil {
			_ = p.Kill()
		}
	}
}
