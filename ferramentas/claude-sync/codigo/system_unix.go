//go:build darwin || linux

package main

// macOS e Linux: a variável vai numa linha marcada nos arquivos de perfil
// (terminais) e, para apps gráficos, no launchctl (macOS) ou no
// environment.d do systemd (Linux).

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const envMarker = "# claude-sync"

func profileFiles() []string {
	home, _ := os.UserHomeDir()
	if runtime.GOOS == "darwin" {
		return []string{filepath.Join(home, ".zprofile"), filepath.Join(home, ".bash_profile")}
	}
	return []string{filepath.Join(home, ".profile")}
}

func environmentD() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".config", "environment.d", "50-claude-sync.conf")
}

func rewriteProfile(file, name, line string) error {
	data, err := os.ReadFile(file)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	var kept []string
	for _, l := range strings.Split(strings.TrimRight(string(data), "\n"), "\n") {
		if !(strings.Contains(l, envMarker) && strings.Contains(l, name)) && (l != "" || len(kept) > 0) {
			kept = append(kept, l)
		}
	}
	if line != "" {
		kept = append(kept, line)
	}
	if len(kept) == 0 {
		return os.WriteFile(file, nil, 0o644)
	}
	return os.WriteFile(file, []byte(strings.Join(kept, "\n")+"\n"), 0o644)
}

func getUserEnv(name string) string {
	for _, file := range profileFiles() {
		data, _ := os.ReadFile(file)
		for _, l := range strings.Split(string(data), "\n") {
			if strings.Contains(l, envMarker) && strings.HasPrefix(l, "export "+name+"=") {
				value := strings.TrimPrefix(l, "export "+name+"=")
				value = strings.TrimSpace(strings.SplitN(value, envMarker, 2)[0])
				return strings.Trim(value, `"`)
			}
		}
	}
	return ""
}

func setUserEnv(name, value string) error {
	line := fmt.Sprintf("export %s=%q %s", name, value, envMarker)
	for _, file := range profileFiles() {
		if err := rewriteProfile(file, name, line); err != nil {
			return err
		}
	}
	if runtime.GOOS == "linux" {
		if err := os.MkdirAll(filepath.Dir(environmentD()), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(environmentD(), []byte(name+"="+value+"\n"), 0o644); err != nil {
			return err
		}
	}
	refreshSessionEnv(value)
	return nil
}

func clearUserEnv(name string) error {
	for _, file := range profileFiles() {
		if _, err := os.Stat(file); err == nil {
			if err := rewriteProfile(file, name, ""); err != nil {
				return err
			}
		}
	}
	if runtime.GOOS == "linux" {
		_ = os.Remove(environmentD())
	} else {
		_ = exec.Command("launchctl", "unsetenv", name).Run()
	}
	return nil
}

// refreshSessionEnv põe a variável na sessão gráfica atual do macOS (o
// launchctl esquece ao reiniciar; o app faz de novo toda vez que abre).
func refreshSessionEnv(value string) {
	if runtime.GOOS == "darwin" && value != "" {
		_ = exec.Command("launchctl", "setenv", "CLAUDE_CONFIG_DIR", value).Run()
	}
}

func autostartFile() string {
	home, _ := os.UserHomeDir()
	if runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "LaunchAgents", "com.bergatrix.claude-sync.plist")
	}
	return filepath.Join(home, ".config", "autostart", "claude-sync.desktop")
}

func autostartEnabled() bool {
	_, err := os.Stat(autostartFile())
	return err == nil
}

func setAutostart(on bool, exe string) error {
	file := autostartFile()
	if !on {
		if err := os.Remove(file); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	var content string
	if runtime.GOOS == "darwin" {
		content = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>com.bergatrix.claude-sync</string>
<key>ProgramArguments</key><array><string>` + xmlEscape(exe) + `</string><string>--background</string></array>
<key>RunAtLoad</key><true/>
</dict></plist>
`
	} else {
		content = "[Desktop Entry]\nType=Application\nName=claude-sync\nExec=\"" + exe + "\" --background\nX-GNOME-Autostart-enabled=true\n"
	}
	if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
		return err
	}
	return os.WriteFile(file, []byte(content), 0o644)
}

func xmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;").Replace(s)
}

func openBrowser(url string) error {
	if runtime.GOOS == "darwin" {
		return exec.Command("open", url).Start()
	}
	return exec.Command("xdg-open", url).Start()
}
