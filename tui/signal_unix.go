//go:build !windows

package main

import "github.com/shirou/gopsutil/v4/process"

// quitPIDs politely asks each process to quit (SIGTERM), like the apps.
// Non-positive PIDs are sentinels (e.g. Store-app "running" markers), never
// real processes — signaling -1 would hit the whole process group.
func quitPIDs(pids []int32) {
	for _, pid := range pids {
		if pid <= 0 {
			continue
		}
		if p, err := process.NewProcess(pid); err == nil {
			_ = p.Terminate()
		}
	}
}
