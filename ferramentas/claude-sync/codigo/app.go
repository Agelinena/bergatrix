package main

// O app: login no Nextcloud, a pasta do Claude e as opções. A interface web
// (web.go) só chama estes métodos.
//
// "Ativar" faz o Claude Code usar a pasta sincronizada como pasta dele
// (variável de usuário CLAUDE_CONFIG_DIR). Antes, copia para ela o que já
// existe na pasta atual do Claude (~/.claude e ~/.claude.json), sem
// sobrescrever nada. A sincronização só roda com o app ativado: assim a cópia
// inicial nunca disputa com o que vem do Nextcloud.

import (
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const envName = "CLAUDE_CONFIG_DIR"

var errNoSecret = errors.New("sem senha de app guardada")

type App struct {
	store  *Store
	engine *Engine
	exe    string
	quit   func()

	mu          sync.Mutex
	cfg         *Config
	connected   bool
	login       loginState
	activatedAt time.Time
	// Hook da etiqueta deste PC (nil: sem etiqueta). O motor lê sem pegar a.mu.
	tagHookNow atomic.Pointer[map[string]any]
}

type loginState struct {
	Pending bool   `json:"pending"`
	URL     string `json:"url"`
	Error   string `json:"error"`
	cancel  context.CancelFunc
}

func newApp(store *Store, quit func()) (*App, error) {
	cfg, err := store.LoadConfig()
	if err != nil {
		return nil, err
	}
	exe, _ := os.Executable()
	a := &App{store: store, cfg: cfg, exe: exe, quit: quit, engine: newEngine(store, cfg)}
	a.engine.transformUp = func(remotePath string, data []byte) []byte {
		if !isSyncedSettings(remotePath) {
			return data
		}
		out, err := withTagHook(data, nil) // o hook é de cada PC: não sobe
		if err != nil {
			return data
		}
		return out
	}
	a.engine.transformDown = func(remotePath string, data []byte) []byte {
		if !isSyncedSettings(remotePath) {
			return data
		}
		var hook map[string]any
		if h := a.tagHookNow.Load(); h != nil {
			hook = *h
		}
		out, err := withTagHook(data, hook)
		if err != nil {
			return data
		}
		return out
	}
	a.engine.onRemoteMoved = func(newDir string) {
		a.mu.Lock()
		defer a.mu.Unlock()
		a.cfg.RemoteDir = newDir
		if err := a.store.SaveConfig(a.cfg); err != nil {
			log.Printf("não consegui gravar a pasta nova: %v", err)
		}
	}
	a.mu.Lock()
	a.connectLocked()
	a.mu.Unlock()
	if a.activeLocked() {
		refreshSessionEnv(cfg.SyncDir)
	}
	return a, nil
}

func (a *App) activeLocked() bool {
	value := getUserEnv(envName)
	return value != "" && samePath(value, a.cfg.SyncDir)
}

func isSyncedSettings(remotePath string) bool {
	return strings.HasSuffix(remotePath, "/global/"+settingsFile)
}

// applyTagLocked põe ou tira o hook da etiqueta no settings.json da pasta ativa.
func (a *App) applyTagLocked() {
	active := a.activeLocked()
	if active && !a.cfg.NoTag && a.exe != "" {
		hook := tagHook(a.exe)
		a.tagHookNow.Store(&hook)
	} else {
		a.tagHookNow.Store(nil)
	}
	if !active {
		return
	}
	if err := applyTagHook(a.cfg.SyncDir, a.cfg, a.exe, true); err != nil {
		log.Printf("etiqueta do PC: %v", err)
	}
}

// connectLocked liga ou pausa o motor conforme as credenciais e a ativação.
func (a *App) connectLocked() {
	a.applyTagLocked()
	cfg := *a.cfg
	password, err := loadSecret(a.store, cfg.User)
	a.connected = cfg.Server != "" && cfg.User != "" && err == nil
	if a.connected && a.activeLocked() {
		a.engine.Configure(&cfg, newDav(cfg.Server, cfg.User, password))
		a.engine.Kick()
	} else {
		a.engine.Configure(&cfg, nil)
	}
}

func (a *App) Configured() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.connected && a.activeLocked()
}

type AppStatus struct {
	Version         string            `json:"version"`
	Server          string            `json:"server"`
	User            string            `json:"user"`
	Connected       bool              `json:"connected"`
	Login           loginState        `json:"login"`
	SyncDir         string            `json:"syncDir"`
	EnvValue        string            `json:"envValue"`
	Active          bool              `json:"active"`
	JustActivated   bool              `json:"justActivated"`
	Autostart       bool              `json:"autostart"`
	GlobalItems     []string          `json:"globalItems"`
	AllGlobalItems  []string          `json:"allGlobalItems"`
	IntervalSeconds int               `json:"intervalSeconds"`
	Links           map[string]string `json:"links"`
	RemoteDir       string            `json:"remoteDir"`
	PCName          string            `json:"pcName"`
	Hostname        string            `json:"hostname"`
	Tag             bool              `json:"tag"`
	TagLine         string            `json:"tagLine"`
	Engine          EngineStatus      `json:"engine"`
}

func (a *App) Status() AppStatus {
	engine := a.engine.Status()
	a.mu.Lock()
	defer a.mu.Unlock()
	return AppStatus{
		Version:         version,
		Server:          a.cfg.Server,
		User:            a.cfg.User,
		Connected:       a.connected,
		Login:           a.login,
		SyncDir:         a.cfg.SyncDir,
		EnvValue:        getUserEnv(envName),
		Active:          a.activeLocked(),
		JustActivated:   !a.activatedAt.IsZero() && time.Since(a.activatedAt) < 30*time.Minute,
		Autostart:       autostartEnabled(),
		GlobalItems:     a.cfg.GlobalItems,
		AllGlobalItems:  allGlobalItems,
		IntervalSeconds: a.cfg.IntervalSeconds,
		Links:           a.cfg.Links,
		RemoteDir:       a.cfg.RemoteDir,
		PCName:          a.cfg.PCName,
		Hostname:        hostname(),
		Tag:             !a.cfg.NoTag,
		TagLine:         tagLine(a.cfg),
		Engine:          engine,
	}
}

// ── Login ───────────────────────────────────────────────────────────

// StartLogin devolve o endereço que o navegador deve abrir; o resto acontece em segundo plano.
func (a *App) StartLogin(ctx context.Context, rawServer string) (string, error) {
	server, err := normalizeServer(rawServer)
	if err != nil {
		return "", err
	}
	flow, err := startLogin(ctx, server)
	if err != nil {
		return "", err
	}
	a.mu.Lock()
	if a.login.cancel != nil {
		a.login.cancel()
	}
	pollCtx, cancel := context.WithCancel(context.Background())
	a.login = loginState{Pending: true, URL: flow.Login, cancel: cancel}
	a.mu.Unlock()
	go a.finishLogin(pollCtx, server, flow)
	return flow.Login, nil
}

func (a *App) finishLogin(ctx context.Context, server string, flow *loginFlow) {
	fail := func(err error) {
		a.mu.Lock()
		a.login = loginState{Error: err.Error()}
		a.mu.Unlock()
	}
	result, err := pollLogin(ctx, flow)
	if err != nil {
		if ctx.Err() == nil {
			fail(err)
		}
		return
	}
	if result.Server != "" {
		if s, err := normalizeServer(result.Server); err == nil {
			server = s
		}
	}
	id, err := userID(ctx, server, result.LoginName, result.AppPassword)
	if err != nil {
		fail(err)
		return
	}
	if err := saveSecret(a.store, id, result.AppPassword); err != nil {
		fail(errors.New("não consegui guardar a senha no cofre do sistema: " + err.Error()))
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.cfg.Server, a.cfg.User = server, id
	a.login = loginState{}
	if err := a.store.SaveConfig(a.cfg); err != nil {
		a.login.Error = err.Error()
	}
	log.Printf("conectado a %s como %s", server, id)
	a.connectLocked()
}

func (a *App) CancelLogin() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.login.cancel != nil {
		a.login.cancel()
	}
	a.login = loginState{}
}

func (a *App) Logout(ctx context.Context) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if password, err := loadSecret(a.store, a.cfg.User); err == nil {
		revokeAppPassword(ctx, a.cfg.Server, a.cfg.User, password)
	}
	if err := deleteSecret(a.store, a.cfg.User); err != nil {
		return err
	}
	a.cfg.User = ""
	if err := a.store.SaveConfig(a.cfg); err != nil {
		return err
	}
	a.connectLocked()
	return nil
}

// ── Pasta do Claude ─────────────────────────────────────────────────

func (a *App) Activate(syncDir string) error {
	if syncDir == "" || !filepath.IsAbs(syncDir) {
		return errors.New("escolha um caminho completo para a pasta")
	}
	syncDir = filepath.Clean(syncDir)
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.connected {
		return errors.New("entre no Nextcloud antes de ativar")
	}
	if err := os.MkdirAll(syncDir, 0o700); err != nil {
		return err
	}
	if err := migrateClaudeDir(syncDir); err != nil {
		return errors.New("não consegui copiar a pasta atual do Claude: " + err.Error())
	}
	if err := setUserEnv(envName, syncDir); err != nil {
		return errors.New("não consegui gravar a variável " + envName + ": " + err.Error())
	}
	a.cfg.SyncDir = syncDir
	a.activatedAt = time.Now()
	if err := a.store.SaveConfig(a.cfg); err != nil {
		return err
	}
	log.Printf("ativado: %s=%s", envName, syncDir)
	a.connectLocked()
	return nil
}

func (a *App) Deactivate() error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.activeLocked() {
		return nil
	}
	// A pasta deixa de ser a do Claude: o hook da etiqueta sai dela.
	if err := applyTagHook(a.cfg.SyncDir, a.cfg, a.exe, false); err != nil {
		log.Printf("etiqueta do PC: %v", err)
	}
	if err := clearUserEnv(envName); err != nil {
		return err
	}
	a.activatedAt = time.Time{}
	log.Printf("desativado: %s removida", envName)
	a.connectLocked()
	return nil
}

// migrateClaudeDir copia a pasta atual do Claude para a nova, sem sobrescrever.
func migrateClaudeDir(dst string) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	src := filepath.Join(home, ".claude")
	if current := getUserEnv(envName); current != "" && !samePath(current, dst) {
		src = current // trocando de pasta: leva da anterior
	} else if samePath(src, dst) {
		return nil
	}
	if err := copyMissing(src, dst); err != nil {
		return err
	}
	// Sem CLAUDE_CONFIG_DIR, o .claude.json (projetos conhecidos, login) fica na pasta do usuário.
	if samePath(src, filepath.Join(home, ".claude")) {
		return copyFileMissing(filepath.Join(home, ".claude.json"), filepath.Join(dst, ".claude.json"))
	}
	return nil
}

func copyMissing(src, dst string) error {
	if _, err := os.Stat(src); errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return filepath.WalkDir(src, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // arquivo em uso ou sem permissão: segue com o resto
		}
		rel, err := filepath.Rel(src, p)
		if err != nil || rel == "." {
			return nil
		}
		target := filepath.Join(dst, rel)
		if samePath(p, dst) {
			return filepath.SkipDir // a pasta nova está dentro da antiga
		}
		if d.IsDir() {
			return os.MkdirAll(target, 0o700)
		}
		if d.Type().IsRegular() {
			return copyFileMissing(p, target)
		}
		return nil
	})
}

func copyFileMissing(src, dst string) error {
	if _, err := os.Stat(dst); err == nil {
		return nil
	}
	info, err := os.Stat(src)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	data, err := os.ReadFile(src)
	if err != nil {
		return nil // em uso: o Claude recria
	}
	if err := writeAtomic(dst, data, 0o600); err != nil {
		return err
	}
	return os.Chtimes(dst, info.ModTime(), info.ModTime())
}

// ── Opções ──────────────────────────────────────────────────────────

type Settings struct {
	GlobalItems     []string `json:"globalItems"`
	IntervalSeconds int      `json:"intervalSeconds"`
	Autostart       bool     `json:"autostart"`
	PCName          string   `json:"pcName"`
	Tag             bool     `json:"tag"`
}

func (a *App) UpdateSettings(s Settings) error {
	allowed := map[string]bool{}
	for _, item := range allGlobalItems {
		allowed[item] = true
	}
	items := []string{}
	for _, item := range s.GlobalItems {
		if allowed[item] {
			items = append(items, item)
		}
	}
	if s.IntervalSeconds < 10 || s.IntervalSeconds > 3600 {
		return errors.New("o intervalo vai de 10 a 3600 segundos")
	}
	name := strings.TrimSpace(s.PCName)
	if len([]rune(name)) > 40 || strings.ContainsAny(name, "\r\n[]") {
		return errors.New("o nome do PC tem até 40 caracteres, sem colchetes nem quebra de linha")
	}
	if err := setAutostart(s.Autostart, a.exe); err != nil {
		return errors.New("não consegui mudar o início automático: " + err.Error())
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.cfg.GlobalItems, a.cfg.IntervalSeconds = items, s.IntervalSeconds
	a.cfg.PCName, a.cfg.NoTag = name, !s.Tag
	if err := a.store.SaveConfig(a.cfg); err != nil {
		return err
	}
	a.connectLocked()
	return nil
}

// Link diz onde um projeto que só está no Nextcloud fica neste PC (caminho vazio desfaz).
func (a *App) Link(key, path string) error {
	if key == "" || notKeySafe.MatchString(key) {
		return errors.New("projeto inválido")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if path == "" {
		delete(a.cfg.Links, key)
	} else {
		if !filepath.IsAbs(path) {
			return errors.New("use o caminho completo do projeto")
		}
		a.cfg.Links[key] = filepath.Clean(path)
	}
	if err := a.store.SaveConfig(a.cfg); err != nil {
		return err
	}
	a.connectLocked()
	return nil
}

func (a *App) SyncNow() { a.engine.Kick() }

// ── Pasta no Nextcloud ──────────────────────────────────────────────

func (a *App) davNow() (*Dav, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.connected {
		return nil, errors.New("entre no Nextcloud primeiro")
	}
	password, err := loadSecret(a.store, a.cfg.User)
	if err != nil {
		return nil, err
	}
	return newDav(a.cfg.Server, a.cfg.User, password), nil
}

// RemoteFolders lista as subpastas de `dir` no Nextcloud (vazio: a raiz da conta).
func (a *App) RemoteFolders(ctx context.Context, dir string) ([]string, error) {
	if strings.TrimSpace(strings.Trim(dir, "/")) != "" {
		clean, err := normalizeRemoteDir(dir)
		if err != nil {
			return nil, err
		}
		dir = clean
	} else {
		dir = ""
	}
	dav, err := a.davNow()
	if err != nil {
		return nil, err
	}
	entries, err := dav.Propfind(ctx, dir, "1")
	if err != nil {
		return nil, err
	}
	folders := []string{}
	for _, e := range entries {
		if e.Dir && e.Path != dir {
			folders = append(folders, e.Path[strings.LastIndex(e.Path, "/")+1:])
		}
	}
	sort.Strings(folders)
	return folders, nil
}

// SetRemoteDir troca a pasta no Nextcloud. Com move, leva o que já está na
// atual para a nova e deixa um aviso na antiga: os outros PCs seguem sozinhos.
func (a *App) SetRemoteDir(ctx context.Context, raw string, move bool) error {
	target, err := normalizeRemoteDir(raw)
	if err != nil {
		return err
	}
	a.mu.Lock()
	current := a.cfg.RemoteDir
	a.mu.Unlock()
	if target == current {
		return nil
	}
	if strings.HasPrefix(target+"/", current+"/") || strings.HasPrefix(current+"/", target+"/") {
		return errors.New("uma pasta não pode ficar dentro da outra")
	}
	dav, err := a.davNow()
	if err != nil {
		return err
	}
	if move {
		old, err := dav.Propfind(ctx, current, "0")
		if err != nil {
			return err
		}
		if len(old) > 0 {
			existing, err := dav.Propfind(ctx, target, "0")
			if err != nil {
				return err
			}
			if len(existing) > 0 {
				return errors.New("a pasta " + target + " já existe no Nextcloud: escolha outra, ou troque sem mover")
			}
			if i := strings.LastIndex(target, "/"); i > 0 {
				parts := strings.Split(target[:i], "/")
				for j := range parts {
					if err := dav.Mkcol(ctx, strings.Join(parts[:j+1], "/")); err != nil {
						return err
					}
				}
			}
			if err := dav.Move(ctx, current, target); err != nil {
				return err
			}
			marker, _ := json.Marshal(map[string]string{"movedTo": target, "movedAt": time.Now().Format(time.RFC3339), "by": hostname()})
			if err := dav.Mkcol(ctx, current); err != nil {
				return err
			}
			if _, err := dav.Put(ctx, current+"/"+movedMarker, marker, time.Now()); err != nil {
				return err
			}
			a.engine.MoveRemote(current, target)
			log.Printf("pasta no Nextcloud movida: %s → %s", current, target)
		}
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.cfg.RemoteDir = target
	if err := a.store.SaveConfig(a.cfg); err != nil {
		return err
	}
	a.connectLocked()
	return nil
}

func (a *App) OpenFolder() error {
	a.mu.Lock()
	dir := a.cfg.SyncDir
	a.mu.Unlock()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	return openBrowser(dir)
}

func (a *App) Quit() { a.quit() }
