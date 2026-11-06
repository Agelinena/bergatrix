package main

// macOS: a senha de app fica no Keychain do usuário (comando security).

import (
	"os/exec"
	"strings"
)

const keychainService = "claude-sync"

func saveSecret(_ *Store, account, secret string) error {
	return exec.Command("security", "add-generic-password", "-U",
		"-s", keychainService, "-a", account, "-w", secret).Run()
}

func loadSecret(_ *Store, account string) (string, error) {
	out, err := exec.Command("security", "find-generic-password", "-s", keychainService, "-a", account, "-w").Output()
	if err != nil {
		return "", errNoSecret
	}
	return strings.TrimRight(string(out), "\n"), nil
}

func deleteSecret(_ *Store, account string) error {
	_ = exec.Command("security", "delete-generic-password", "-s", keychainService, "-a", account).Run()
	return nil
}
