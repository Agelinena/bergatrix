package main

// Etiqueta do PC: um hook UserPromptSubmit no settings.json da pasta do
// Claude roda "claude-sync tag" a cada mensagem. O Claude Code junta a saída
// à mensagem como contexto, então o agente sempre sabe de qual PC ela veio:
//
//   [PC: notebook-casa · windows · DESKTOP-123]
//
// O comando aponta para o executável DESTE PC. Se o settings.json for
// sincronizado, o hook sai antes de subir e volta (com o caminho local) ao
// baixar: um PC nunca recebe o hook de outro.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
)

const settingsFile = "settings.json"

func hostname() string {
	host, _ := os.Hostname()
	if host == "" {
		return "desconhecido"
	}
	return host
}

func pcName(cfg *Config) string {
	if name := strings.TrimSpace(cfg.PCName); name != "" {
		return name
	}
	return hostname()
}

func tagLine(cfg *Config) string {
	name, host := pcName(cfg), hostname()
	if strings.EqualFold(name, host) {
		return fmt.Sprintf("[PC: %s · %s]", name, runtime.GOOS)
	}
	return fmt.Sprintf("[PC: %s · %s · %s]", name, runtime.GOOS, host)
}

// cmdTag é o que o hook roda: só a etiqueta no stdout, nunca falha.
func cmdTag() {
	cfg := defaultConfig()
	if dir, err := appDir(); err == nil {
		if loaded, err := (&Store{Dir: dir}).LoadConfig(); err == nil {
			cfg = loaded
		}
	}
	if cfg.NoTag {
		return
	}
	fmt.Println(tagLine(cfg))
}

// ── O hook no settings.json ─────────────────────────────────────────

func bashQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }
func psQuote(s string) string   { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }

// gitBashAvailable segue a regra do Claude Code no Windows: Git Bash se
// existir, senão PowerShell.
func gitBashAvailable() bool {
	if p := os.Getenv("CLAUDE_CODE_GIT_BASH_PATH"); p != "" {
		return true
	}
	if git, err := exec.LookPath("git"); err == nil {
		for _, rel := range []string{`..\bin\bash.exe`, `..\..\bin\bash.exe`} {
			if _, err := os.Stat(filepath.Join(filepath.Dir(git), rel)); err == nil {
				return true
			}
		}
	}
	for _, p := range []string{`C:\Program Files\Git\bin\bash.exe`, filepath.Join(os.Getenv("LOCALAPPDATA"), `Programs\Git\bin\bash.exe`)} {
		if _, err := os.Stat(p); err == nil {
			return true
		}
	}
	return false
}

func tagHook(exe string) map[string]any {
	hook := map[string]any{"type": "command", "timeout": 10}
	if runtime.GOOS == "windows" && !gitBashAvailable() {
		hook["shell"] = "powershell"
		hook["command"] = "& " + psQuote(exe) + " tag"
	} else {
		hook["command"] = bashQuote(filepath.ToSlash(exe)) + " tag"
	}
	return hook
}

func isTagHook(v any) bool {
	h, ok := v.(map[string]any)
	if !ok {
		return false
	}
	cmd, _ := h["command"].(string)
	return strings.Contains(cmd, "claude-sync") && strings.HasSuffix(strings.TrimSpace(cmd), " tag")
}

// withTagHook devolve o settings.json com o hook da etiqueta trocado por
// `hook` (nil tira). Se nada mudar, devolve os bytes originais.
func withTagHook(data []byte, hook map[string]any) ([]byte, error) {
	settings := map[string]any{}
	if len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &settings); err != nil {
			return data, fmt.Errorf("settings.json inválido: %w", err)
		}
	}
	before, _ := json.Marshal(settings)
	hooks, _ := settings["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	groups, _ := hooks["UserPromptSubmit"].([]any)
	var kept []any
	for _, g := range groups {
		group, ok := g.(map[string]any)
		if !ok {
			kept = append(kept, g)
			continue
		}
		list, _ := group["hooks"].([]any)
		var others []any
		for _, h := range list {
			if !isTagHook(h) {
				others = append(others, h)
			}
		}
		if len(others) == 0 && len(list) > 0 {
			continue // o grupo só tinha a etiqueta
		}
		group["hooks"] = others
		kept = append(kept, group)
	}
	if hook != nil {
		kept = append(kept, map[string]any{"hooks": []any{hook}})
	}
	if len(kept) > 0 {
		hooks["UserPromptSubmit"] = kept
	} else {
		delete(hooks, "UserPromptSubmit")
	}
	if len(hooks) > 0 {
		settings["hooks"] = hooks
	} else {
		delete(settings, "hooks")
	}
	after, _ := json.Marshal(settings)
	var a, b any
	_ = json.Unmarshal(before, &a)
	_ = json.Unmarshal(after, &b)
	if reflect.DeepEqual(a, b) {
		return data, nil
	}
	out, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return data, err
	}
	return append(out, '\n'), nil
}

// applyTagHook põe (ou tira) o hook no settings.json da pasta do Claude.
func applyTagHook(syncDir string, cfg *Config, exe string, on bool) error {
	path := filepath.Join(syncDir, settingsFile)
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	var hook map[string]any
	if on && !cfg.NoTag && exe != "" {
		hook = tagHook(exe)
	}
	if hook == nil && len(data) == 0 {
		return nil
	}
	updated, err := withTagHook(data, hook)
	if err != nil {
		return err
	}
	if bytes.Equal(updated, data) {
		return nil
	}
	return writeAtomic(path, updated, 0o600)
}
