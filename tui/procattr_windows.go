package main

import "syscall"

// New process group: Ctrl-C / console teardown in our window doesn't
// propagate to the launched Cursor instance.
func detachAttr() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{CreationFlags: 0x00000200}
}
