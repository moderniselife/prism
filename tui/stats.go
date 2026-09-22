package main

// Live measurement via gopsutil. Everything is read, nothing is hardcoded:
// per-PID RSS, total RAM, and a non-blocking CPU sample (meaningless until
// the second call, like every delta-based CPU meter).

import (
	"os"
	"sync"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/mem"
	"github.com/shirou/gopsutil/v4/process"
)

type procInfo struct {
	pid  int32
	argv []string
}

func listProcesses() []procInfo {
	procs, err := process.Processes()
	if err != nil {
		return nil
	}
	out := make([]procInfo, 0, len(procs))
	for _, p := range procs {
		argv, err := p.CmdlineSlice()
		if err != nil || len(argv) == 0 {
			continue
		}
		out = append(out, procInfo{pid: p.Pid, argv: argv})
	}
	return out
}

func rssOfPids(pids []int32) uint64 {
	var total uint64
	for _, pid := range pids {
		p, err := process.NewProcess(pid)
		if err != nil {
			continue
		}
		if m, err := p.MemoryInfo(); err == nil && m != nil {
			total += m.RSS
		}
	}
	return total
}

func totalMemory() uint64 {
	if v, err := mem.VirtualMemory(); err == nil && v != nil {
		return v.Total
	}
	return 0
}

var (
	cpuMu     sync.Mutex
	cpuPrimed bool
)

// cpuSample returns system CPU % since the previous call. The first call
// only primes the sampler and reports ok=false — callers show a dash.
func cpuSample() (pct float64, ok bool) {
	cpuMu.Lock()
	defer cpuMu.Unlock()
	vals, err := cpu.Percent(0, false)
	if err != nil || len(vals) == 0 {
		return 0, false
	}
	if !cpuPrimed {
		cpuPrimed = true
		return 0, false
	}
	pct = vals[0]
	if pct < 0 {
		pct = 0
	}
	if pct > 100 {
		pct = 100
	}
	return pct, true
}

func diskUsage(dir string) uint64 {
	var total uint64
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	var walk func(string)
	walk = func(d string) {
		ents, err := os.ReadDir(d)
		if err != nil {
			return
		}
		for _, e := range ents {
			p := d + string(os.PathSeparator) + e.Name()
			if e.IsDir() {
				walk(p)
				continue
			}
			if info, err := e.Info(); err == nil && info.Mode().IsRegular() {
				total += uint64(info.Size())
			}
		}
	}
	for _, e := range entries {
		p := dir + string(os.PathSeparator) + e.Name()
		if e.IsDir() {
			walk(p)
		} else if info, err := e.Info(); err == nil && info.Mode().IsRegular() {
			total += uint64(info.Size())
		}
	}
	return total
}
