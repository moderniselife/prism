//go:build !windows

package main

import "syscall"

// Detach the child into its own session so terminal signals (Ctrl-C) and
// the TUI exiting don't take Cursor down with them.
func detachAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{Setsid: true}
}
