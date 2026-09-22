//go:build !windows

package main

import "github.com/shirou/gopsutil/v4/process"

// quitPIDs politely asks each process to quit (SIGTERM), like the apps.
func quitPIDs(pids []int32) {
	for _, pid := range pids {
		if p, err := process.NewProcess(pid); err == nil {
			_ = p.Terminate()
		}
	}
}
