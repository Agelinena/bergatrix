package main

// Linux: a senha de app fica no Secret Service (GNOME Keyring, KWallet),
// pelo secret-tool (pacote libsecret-tools). A senha vai pelo stdin, não
// pela linha de comando.

import (
	"errors"
	"os/exec"
	"strings"
)

func saveSecret(_ *Store, account, secret string) error {
	if _, err := exec.LookPath("secret-tool"); err != nil {
		return errors.New("instale o secret-tool (libsecret-tools) para guardar a senha no chaveiro")
	}
	cmd := exec.Command("secret-tool", "store", "--label=claude-sync", "service", "claude-sync", "account", account)
	cmd.Stdin = strings.NewReader(secret)
	return cmd.Run()
}

func loadSecret(_ *Store, account string) (string, error) {
	out, err := exec.Command("secret-tool", "lookup", "service", "claude-sync", "account", account).Output()
	if err != nil || len(out) == 0 {
		return "", errNoSecret
	}
	return strings.TrimRight(string(out), "\n"), nil
}

func deleteSecret(_ *Store, account string) error {
	_ = exec.Command("secret-tool", "clear", "service", "claude-sync", "account", account).Run()
	return nil
}
