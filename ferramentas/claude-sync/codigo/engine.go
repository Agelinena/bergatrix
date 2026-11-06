package main

// Motor da sincronização. A cada volta:
//
//  1. lista o que mudou no Nextcloud (pelo etag da pasta raiz e das subpastas);
//  2. baixa o que mudou lá;
//  3. manda o que mudou aqui, depois que o arquivo fica 3 s parado (o Claude
//     grava as conversas linha a linha).
//
// Nunca apaga nada, nem lá nem aqui. Conversas só crescem: se os dois lados
// mudaram e uma versão continua a outra, fica a maior. Se divergiram de
// verdade, as duas ficam (a de lá com o sufixo .conflito-<data>).

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const settleTime = 3 * time.Second
const maxActivity = 60

type Activity struct {
	Time string `json:"time"`
	Text string `json:"text"`
	Tone string `json:"tone"`
}

type ProjectStatus struct {
	Key    string   `json:"key"`
	Paths  []string `json:"paths"`
	Remote bool     `json:"remote"`
}

type Counts struct {
	Down      int `json:"down"`
	Up        int `json:"up"`
	Conflicts int `json:"conflicts"`
}

type EngineStatus struct {
	Running   bool            `json:"running"`
	Syncing   bool            `json:"syncing"`
	LastSync  string          `json:"lastSync"`
	LastError string          `json:"lastError"`
	Counts    Counts          `json:"counts"`
	Projects  []ProjectStatus `json:"projects"`
	Activity  []Activity      `json:"activity"`
}

type remoteTree struct {
	rootETag string
	dirs     map[string]string   // pasta → etag
	files    map[string]DavEntry // arquivo → etag e tamanho
}

type localFile struct {
	abs   string
	size  int64
	mtime time.Time
}

type Engine struct {
	store *Store

	mu      sync.Mutex // uma volta por vez; segura durante a rede
	smu     sync.Mutex // só o status: a interface lê sem esperar a volta acabar
	cfg     *Config
	dav     *Dav
	state   *State
	status  EngineStatus
	tree    remoteTree
	pmap    projectMap
	trigger chan struct{}
	dirty   bool
	now     func() time.Time
}

func newEngine(store *Store, cfg *Config) *Engine {
	return &Engine{store: store, cfg: cfg, state: store.LoadState(), trigger: make(chan struct{}, 1), now: time.Now}
}

// Configure troca a configuração ou as credenciais. dav nil pausa a sincronização.
func (e *Engine) Configure(cfg *Config, dav *Dav) {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.cfg == nil || e.cfg.SyncDir != cfg.SyncDir || e.cfg.RemoteDir != cfg.RemoteDir || (e.dav == nil) != (dav == nil) {
		e.tree = remoteTree{} // outra pasta: lista tudo de novo
		e.pmap = projectMap{}
	}
	e.cfg, e.dav = cfg, dav
	e.setStatus(func(s *EngineStatus) { s.Running = dav != nil })
}

func (e *Engine) setStatus(fn func(*EngineStatus)) {
	e.smu.Lock()
	defer e.smu.Unlock()
	fn(&e.status)
}

func (e *Engine) Kick() {
	select {
	case e.trigger <- struct{}{}:
	default:
	}
}

func (e *Engine) Status() EngineStatus {
	e.smu.Lock()
	defer e.smu.Unlock()
	st := e.status
	st.Activity = append([]Activity(nil), e.status.Activity...)
	st.Projects = append([]ProjectStatus(nil), e.status.Projects...)
	return st
}

func (e *Engine) note(tone, format string, args ...any) {
	text := fmt.Sprintf(format, args...)
	log.Printf("[%s] %s", tone, text)
	e.smu.Lock()
	defer e.smu.Unlock()
	e.status.Activity = append([]Activity{{Time: e.now().Format("15:04:05"), Text: text, Tone: tone}}, e.status.Activity...)
	if len(e.status.Activity) > maxActivity {
		e.status.Activity = e.status.Activity[:maxActivity]
	}
}

// Run sincroniza a cada poucos segundos até o contexto acabar.
func (e *Engine) Run(ctx context.Context) {
	localTick := time.NewTicker(5 * time.Second)
	defer localTick.Stop()
	var lastRemote time.Time
	for {
		e.mu.Lock()
		interval := time.Duration(e.cfg.IntervalSeconds) * time.Second
		e.mu.Unlock()
		forced := false
		select {
		case <-ctx.Done():
			return
		case <-e.trigger:
			forced = true
		case <-localTick.C:
		}
		remoteDue := forced || time.Since(lastRemote) >= interval
		if err := e.Cycle(ctx, remoteDue); err == nil && remoteDue {
			lastRemote = time.Now()
		}
	}
}

// Cycle faz uma volta. remote=false só manda o que mudou aqui (sem listar o servidor de novo).
func (e *Engine) Cycle(ctx context.Context, remote bool) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.dav == nil {
		return nil
	}
	e.setStatus(func(s *EngineStatus) { s.Syncing = true })
	defer e.setStatus(func(s *EngineStatus) { s.Syncing = false })
	err := e.cycle(ctx, remote)
	if e.dirty {
		if saveErr := e.store.SaveState(e.state); saveErr != nil && err == nil {
			err = saveErr
		}
		e.dirty = false
	}
	e.smu.Lock()
	previous := e.status.LastError
	e.smu.Unlock()
	if err != nil {
		if previous != err.Error() {
			e.note("error", "%v", err)
		}
		e.setStatus(func(s *EngineStatus) { s.LastError = err.Error() })
		return err
	}
	if previous != "" {
		e.note("ok", "Conexão de volta.")
	}
	e.setStatus(func(s *EngineStatus) { s.LastError, s.LastSync = "", e.now().Format("15:04:05") })
	return nil
}

func (e *Engine) remoteRoot() string { return strings.Trim(e.cfg.RemoteDir, "/") }

func (e *Engine) cycle(ctx context.Context, remote bool) error {
	if err := os.MkdirAll(filepath.Join(e.cfg.SyncDir, "projects"), 0o700); err != nil {
		return err
	}
	projects := e.pmap.resolve(e.cfg)
	if remote || e.tree.files == nil {
		if err := e.refresh(ctx); err != nil {
			return err
		}
	}
	e.updateProjects(projects)
	if err := e.pull(ctx, projects); err != nil {
		return err
	}
	return e.push(ctx, projects)
}

// ── Lado do Nextcloud ───────────────────────────────────────────────

func (e *Engine) refresh(ctx context.Context) error {
	root := e.remoteRoot()
	top, err := e.dav.Propfind(ctx, root, "0")
	if err != nil {
		return err
	}
	if len(top) == 0 {
		if err := e.mkdirs(ctx, root+"/projects"); err != nil {
			return err
		}
		e.tree = remoteTree{dirs: map[string]string{}, files: map[string]DavEntry{}}
		return nil
	}
	if e.tree.files != nil && top[0].ETag != "" && top[0].ETag == e.tree.rootETag {
		return nil // nada mudou lá
	}
	dirs, files := map[string]string{}, map[string]DavEntry{}
	var walk func(dir string) error
	walk = func(dir string) error {
		entries, err := e.dav.Propfind(ctx, dir, "1")
		if err != nil {
			return err
		}
		for _, entry := range entries {
			switch {
			case entry.Path == dir:
				dirs[dir] = entry.ETag
			case entry.Dir:
				if old, ok := e.tree.dirs[entry.Path]; ok && old == entry.ETag && entry.ETag != "" {
					e.copySubtree(entry.Path, dirs, files)
				} else if err := walk(entry.Path); err != nil {
					return err
				}
			default:
				files[entry.Path] = entry
			}
		}
		return nil
	}
	if err := walk(root); err != nil {
		return err
	}
	e.tree = remoteTree{rootETag: top[0].ETag, dirs: dirs, files: files}
	return nil
}

func (e *Engine) copySubtree(dir string, dirs map[string]string, files map[string]DavEntry) {
	prefix := dir + "/"
	for p, etag := range e.tree.dirs {
		if p == dir || strings.HasPrefix(p, prefix) {
			dirs[p] = etag
		}
	}
	for p, entry := range e.tree.files {
		if strings.HasPrefix(p, prefix) {
			files[p] = entry
		}
	}
}

func (e *Engine) mkdirs(ctx context.Context, dir string) error {
	parts := strings.Split(strings.Trim(dir, "/"), "/")
	for i := range parts {
		current := strings.Join(parts[:i+1], "/")
		if _, ok := e.tree.dirs[current]; ok {
			continue
		}
		if err := e.dav.Mkcol(ctx, current); err != nil {
			return err
		}
		if e.tree.dirs == nil {
			e.tree.dirs = map[string]string{}
		}
		e.tree.dirs[current] = ""
	}
	return nil
}

func (e *Engine) remoteProjects() map[string]bool {
	keys := map[string]bool{}
	prefix := e.remoteRoot() + "/projects/"
	for dir := range e.tree.dirs {
		if rest, ok := strings.CutPrefix(dir, prefix); ok && rest != "" && !strings.Contains(rest, "/") {
			keys[rest] = true
		}
	}
	return keys
}

func (e *Engine) updateProjects(projects []LocalProject) {
	remote := e.remoteProjects()
	byKey := map[string]*ProjectStatus{}
	for _, p := range projects {
		st, ok := byKey[p.Key]
		if !ok {
			st = &ProjectStatus{Key: p.Key, Remote: remote[p.Key]}
			byKey[p.Key] = st
		}
		st.Paths = append(st.Paths, p.Path)
	}
	for key := range remote {
		if _, ok := byKey[key]; !ok {
			byKey[key] = &ProjectStatus{Key: key, Remote: true}
		}
	}
	list := make([]ProjectStatus, 0, len(byKey))
	for _, st := range byKey {
		list = append(list, *st)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Key < list[j].Key })
	e.setStatus(func(s *EngineStatus) { s.Projects = list })
}

// ── Mapeamento local ↔ remoto ───────────────────────────────────────

// targets devolve, para cada caminho remoto, o arquivo local correspondente (pode ser mais de um).
func (e *Engine) localFor(remotePath string, projects []LocalProject) []string {
	root := e.remoteRoot()
	if rest, ok := strings.CutPrefix(remotePath, root+"/projects/"); ok {
		key, rel, found := strings.Cut(rest, "/")
		if !found {
			return nil
		}
		var out []string
		for _, p := range projects {
			if p.Key == key {
				out = append(out, filepath.Join(e.cfg.SyncDir, "projects", p.Folder, filepath.FromSlash(rel)))
			}
		}
		return out
	}
	if rel, ok := strings.CutPrefix(remotePath, root+"/global/"); ok && e.globalAllowed(rel) {
		return []string{filepath.Join(e.cfg.SyncDir, filepath.FromSlash(rel))}
	}
	return nil
}

func (e *Engine) globalAllowed(rel string) bool {
	top, _, _ := strings.Cut(rel, "/")
	for _, item := range e.cfg.GlobalItems {
		if item == top {
			return true
		}
	}
	return false
}

func skipFile(name string) bool {
	return strings.HasSuffix(name, tmpSuffix) || name == ".DS_Store" || name == "Thumbs.db" || name == "desktop.ini"
}

// scanLocal lista o que sobe: as pastas dos projetos conhecidos e os itens globais escolhidos.
func (e *Engine) scanLocal(projects []LocalProject) map[string]localFile {
	out := map[string]localFile{}
	addTree := func(localRoot, remotePrefix string) {
		_ = filepath.WalkDir(localRoot, func(p string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() || skipFile(d.Name()) {
				return nil
			}
			info, err := d.Info()
			if err != nil || !info.Mode().IsRegular() {
				return nil
			}
			rel, err := filepath.Rel(localRoot, p)
			if err != nil {
				return nil
			}
			remote := remotePrefix
			if rel != "." {
				remote += "/" + filepath.ToSlash(rel)
			}
			out[remote] = localFile{abs: p, size: info.Size(), mtime: info.ModTime()}
			return nil
		})
	}
	root := e.remoteRoot()
	for _, p := range projects {
		addTree(filepath.Join(e.cfg.SyncDir, "projects", p.Folder), root+"/projects/"+p.Key)
	}
	for _, item := range e.cfg.GlobalItems {
		addTree(filepath.Join(e.cfg.SyncDir, item), root+"/global/"+item)
	}
	return out
}

// ── Baixar e mandar ─────────────────────────────────────────────────

func stateKey(remotePath, local string) string { return remotePath + "|" + local }

func (e *Engine) record(key, etag, local string) {
	st := FileState{ETag: etag, Size: -1, MTime: -1}
	if info, err := os.Stat(local); err == nil {
		st.Size, st.MTime = info.Size(), info.ModTime().UnixNano()
	}
	e.state.Files[key] = st
	e.dirty = true
}

func (e *Engine) localChanged(key string, f localFile) bool {
	known, ok := e.state.Files[key]
	return !ok || known.Size != f.size || known.MTime != f.mtime.UnixNano()
}

func (e *Engine) pull(ctx context.Context, projects []LocalProject) error {
	paths := make([]string, 0, len(e.tree.files))
	for p := range e.tree.files {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, remotePath := range paths {
		entry := e.tree.files[remotePath]
		for _, local := range e.localFor(remotePath, projects) {
			key := stateKey(remotePath, local)
			known, hasState := e.state.Files[key]
			info, statErr := os.Stat(local)
			exists := statErr == nil
			if hasState && known.ETag == entry.ETag && exists {
				continue // lá não mudou
			}
			switch {
			case !exists:
				if err := e.download(ctx, remotePath, local, entry.ETag, key); err != nil {
					return err
				}
				e.setStatus(func(s *EngineStatus) { s.Counts.Down++ })
				e.note("down", "Baixado: %s", shortName(remotePath))
			case hasState && known.Size == info.Size() && known.MTime == info.ModTime().UnixNano():
				if err := e.download(ctx, remotePath, local, entry.ETag, key); err != nil {
					return err
				}
				e.setStatus(func(s *EngineStatus) { s.Counts.Down++ })
				e.note("down", "Atualizado: %s", shortName(remotePath))
			default:
				if err := e.resolve(ctx, remotePath, local, entry.ETag, key); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func (e *Engine) download(ctx context.Context, remotePath, local, etag, key string) error {
	data, err := e.dav.Get(ctx, remotePath)
	if err != nil {
		return err
	}
	if err := writeAtomic(local, data, 0o600); err != nil {
		return err
	}
	e.record(key, etag, local)
	return nil
}

// resolve trata um arquivo que mudou dos dois lados.
func (e *Engine) resolve(ctx context.Context, remotePath, local, etag, key string) error {
	theirs, err := e.dav.Get(ctx, remotePath)
	if err != nil {
		return err
	}
	mine, err := os.ReadFile(local)
	if err != nil {
		return err
	}
	switch {
	case bytes.Equal(theirs, mine):
		e.record(key, etag, local)
	case bytes.HasPrefix(theirs, mine):
		if err := writeAtomic(local, theirs, 0o600); err != nil {
			return err
		}
		e.record(key, etag, local)
		e.setStatus(func(s *EngineStatus) { s.Counts.Down++ })
		e.note("down", "Continuação baixada: %s", shortName(remotePath))
	case bytes.HasPrefix(mine, theirs):
		// A daqui é a maior: o push manda.
		e.state.Files[key] = FileState{ETag: etag, Size: -1, MTime: -1}
		e.dirty = true
	default:
		ext := filepath.Ext(local)
		copyPath := strings.TrimSuffix(local, ext) + ".conflito-" + e.now().Format("20060102-150405") + ext
		if err := writeAtomic(copyPath, theirs, 0o600); err != nil {
			return err
		}
		e.state.Files[key] = FileState{ETag: etag, Size: -1, MTime: -1}
		e.dirty = true
		e.setStatus(func(s *EngineStatus) { s.Counts.Conflicts++ })
		e.note("warn", "Conversa divergente: a versão do Nextcloud ficou em %s", filepath.Base(copyPath))
	}
	return nil
}

func (e *Engine) push(ctx context.Context, projects []LocalProject) error {
	local := e.scanLocal(projects)
	paths := make([]string, 0, len(local))
	for p := range local {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	for _, remotePath := range paths {
		f := local[remotePath]
		key := stateKey(remotePath, f.abs)
		if !e.localChanged(key, f) || e.now().Sub(f.mtime) < settleTime {
			continue
		}
		known, hasState := e.state.Files[key]
		if entry, ok := e.tree.files[remotePath]; ok && (!hasState || known.ETag != entry.ETag) {
			if err := e.resolve(ctx, remotePath, f.abs, entry.ETag, key); err != nil {
				return err
			}
			if e.state.Files[key].Size != -1 {
				continue // resolvido sem precisar mandar
			}
		}
		if err := e.upload(ctx, remotePath, f, key); err != nil {
			return err
		}
	}
	return nil
}

func (e *Engine) upload(ctx context.Context, remotePath string, f localFile, key string) error {
	data, err := os.ReadFile(f.abs)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if err := e.mkdirs(ctx, path.Dir(remotePath)); err != nil {
		return err
	}
	etag, err := e.dav.Put(ctx, remotePath, data, f.mtime)
	if err != nil {
		return err
	}
	if etag == "" {
		if entries, err := e.dav.Propfind(ctx, remotePath, "0"); err == nil && len(entries) > 0 {
			etag = entries[0].ETag
		}
	}
	e.tree.files[remotePath] = DavEntry{Path: remotePath, ETag: etag, Size: int64(len(data))}
	// Se o arquivo mudou durante o envio, o stat novo não bate e ele sobe de novo na próxima volta.
	e.state.Files[key] = FileState{ETag: etag, Size: f.size, MTime: f.mtime.UnixNano()}
	e.dirty = true
	e.setStatus(func(s *EngineStatus) { s.Counts.Up++ })
	e.note("up", "Enviado: %s", shortName(remotePath))
	return nil
}

func shortName(remotePath string) string {
	parts := strings.Split(remotePath, "/")
	if len(parts) > 3 {
		parts = parts[2:] // tira "Claude/projects"
	}
	return strings.Join(parts, "/")
}
