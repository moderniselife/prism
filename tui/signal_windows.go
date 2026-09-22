package main

import "github.com/shirou/gopsutil/v4/process"

// Windows has no SIGTERM; terminate the processes outright.
func quitPIDs(pids []int32) {
	for _, pid := range pids {
		if p, err := process.NewProcess(pid); err == nil {
			_ = p.Kill()
		}
	}
}
