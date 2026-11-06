//go:build linux

package main

import (
	"os"
	"syscall"
)

type owner struct{ uid, gid int }

func statOwner(info os.FileInfo) (owner, bool) {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return owner{}, false
	}
	return owner{int(st.Uid), int(st.Gid)}, true
}
