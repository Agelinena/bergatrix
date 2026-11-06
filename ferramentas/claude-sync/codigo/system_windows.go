package main

// Windows: variável de usuário em HKCU\Environment (avisando os programas
// abertos), início automático em HKCU\...\Run e navegador padrão.

import (
	"os/exec"
	"strings"
	"syscall"
	"unsafe"
)

const runKey = `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
const envKey = `HKCU\Environment`

func hiddenCommand(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	// O app roda sem console: sem isto, cada reg.exe piscaria uma janela.
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
	return cmd
}

func regQuery(key, name string) (string, bool) {
	out, err := hiddenCommand("reg", "query", key, "/v", name).Output()
	if err != nil {
		return "", false
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 3 && strings.EqualFold(fields[0], name) && strings.HasPrefix(fields[1], "REG_") {
			// O valor pode ter espaços: tudo depois do tipo.
			idx := strings.Index(line, fields[1]) + len(fields[1])
			return strings.TrimSpace(line[idx:]), true
		}
	}
	return "", false
}

var (
	user32                  = syscall.NewLazyDLL("user32.dll")
	procSendMessageTimeoutW = user32.NewProc("SendMessageTimeoutW")
)

// broadcastEnvironment avisa o Explorer e os outros programas que o ambiente mudou.
func broadcastEnvironment() {
	const hwndBroadcast, wmSettingChange, smtoAbortIfHung = 0xffff, 0x001A, 0x0002
	env, _ := syscall.UTF16PtrFromString("Environment")
	var result uintptr
	procSendMessageTimeoutW.Call(hwndBroadcast, wmSettingChange, 0, uintptr(unsafe.Pointer(env)),
		smtoAbortIfHung, 5000, uintptr(unsafe.Pointer(&result)))
}

func getUserEnv(name string) string {
	value, _ := regQuery(envKey, name)
	return value
}

func setUserEnv(name, value string) error {
	if err := hiddenCommand("reg", "add", envKey, "/v", name, "/t", "REG_SZ", "/d", value, "/f").Run(); err != nil {
		return err
	}
	broadcastEnvironment()
	return nil
}

func clearUserEnv(name string) error {
	if _, ok := regQuery(envKey, name); !ok {
		return nil
	}
	if err := hiddenCommand("reg", "delete", envKey, "/v", name, "/f").Run(); err != nil {
		return err
	}
	broadcastEnvironment()
	return nil
}

func refreshSessionEnv(string) {}

func autostartEnabled() bool {
	_, ok := regQuery(runKey, "claude-sync")
	return ok
}

func setAutostart(on bool, exe string) error {
	if !on {
		if !autostartEnabled() {
			return nil
		}
		return hiddenCommand("reg", "delete", runKey, "/v", "claude-sync", "/f").Run()
	}
	return hiddenCommand("reg", "add", runKey, "/v", "claude-sync", "/t", "REG_SZ",
		"/d", `"`+exe+`" --background`, "/f").Run()
}

func openBrowser(url string) error {
	return hiddenCommand("rundll32", "url.dll,FileProtocolHandler", url).Start()
}
