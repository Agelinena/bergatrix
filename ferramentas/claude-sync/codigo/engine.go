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
	"encoding/json"
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

	// Ajustes no conteúdo ao subir e ao baixar (o hook da etiqueta no settings.json).
	transformUp   func(remotePath string, data []byte) []byte
	transformDown func(remotePath string, data []byte) []byte
	// Outro PC moveu a pasta no Nextcloud: o app grava a pasta nova na configuração.
	onRemoteMoved func(newDir string)
}

// movedMarker fica na pasta antiga depois de "mover", apontando a nova.
const movedMarker = ".claude-sync-movido.json"

func (e *Engine) up(remotePath string, data []byte) []byte {
	if e.transformUp != nil {
		return e.transformUp(remotePath, data)
	}
	return data
}

func (e *Engine) down(remotePath string, data []byte) []byte {
	if e.transformDown != nil {
		return e.transformDown(remotePath, data)
	}
	return data
}

// MoveRemote passa a usar outra pasta no Nextcloud e leva junto o estado
// (o que já foi sincronizado), para não baixar tudo de novo.
func (e *Engine) MoveRemote(oldDir, newDir string) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.renameRemote(oldDir, newDir)
}

func (e *Engine) renameRemote(oldDir, newDir string) {
	oldPrefix, newPrefix := strings.Trim(oldDir, "/")+"/", strings.Trim(newDir, "/")+"/"
	for key, st := range e.state.Files {
		if rest, ok := strings.CutPrefix(key, oldPrefix); ok {
			delete(e.state.Files, key)
			e.state.Files[newPrefix+rest] = st
		}
	}
	e.dirty = true
	if e.cfg != nil {
		cfg := *e.cfg
		cfg.RemoteDir = strings.Trim(newDir, "/")
		e.cfg = &cfg
	}
	e.tree = remoteTree{}
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

func (e *Engine) refresh(ctx context.Context) error { return e.refreshOnce(ctx, false) }

func (e *Engine) refreshOnce(ctx context.Context, followed bool) error {
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
	if _, moved := files[root+"/"+movedMarker]; moved && !followed {
		return e.followMove(ctx, root)
	}
	return nil
}

// followMove: outro PC moveu a pasta. Lê para onde e passa a usar a nova.
func (e *Engine) followMove(ctx context.Context, root string) error {
	data, err := e.dav.Get(ctx, root+"/"+movedMarker)
	if err != nil {
		return err
	}
	var marker struct {
		MovedTo string `json:"movedTo"`
	}
	if json.Unmarshal(data, &marker) != nil {
		return nil
	}
	target, err := normalizeRemoteDir(marker.MovedTo)
	if err != nil || target == root {
		return nil
	}
	e.renameRemote(root, target)
	e.note("warn", "A pasta no Nextcloud foi movida para %s em outro PC. Este PC passou a usar a nova.", target)
	if e.onRemoteMoved != nil {
		go e.onRemoteMoved(target)
	}
	return e.refreshOnce(ctx, true)
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

// managedGlobal: partes dos itens globais que o próprio Claude Code cuida em
// cada PC e não sobem: skills/synced (skills sincronizadas pela conta) e
// qualquer pasta ou arquivo oculto (.trash, .last-complete-round...).
func managedGlobal(rel string) bool {
	rel = filepath.ToSlash(rel)
	if rel == "skills/synced" || strings.HasPrefix(rel, "skills/synced/") {
		return true
	}
	for _, part := range strings.Split(rel, "/") {
		if strings.HasPrefix(part, ".") {
			return true
		}
	}
	return false
}

func (e *Engine) globalAllowed(rel string) bool {
	if managedGlobal(rel) {
		return false
	}
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
	for remote := range out {
		if rel, ok := strings.CutPrefix(remote, root+"/global/"); ok && managedGlobal(rel) {
			delete(out, remote)
		}
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
		if strings.HasSuffix(remotePath, tmpSuffix) {
			continue // envio de outro PC em andamento (ou que caiu)
		}
		entry := e.tree.files[remotePath]
		for _, local := range e.localFor(remotePath, projects) {
			key := stateKey(remotePath, local)
			known, hasState := e.state.Files[key]
			info, statErr := os.Stat(local)
			exists := statErr == nil
			if hasState && known.ETag == entry.ETag && exists {
				continue // lá não mudou
			}
			var err error
			switch {
			case !exists:
				err = e.download(ctx, remotePath, local, entry.ETag, key, "Baixado")
			case hasState && known.Size == info.Size() && known.MTime == info.ModTime().UnixNano():
				err = e.download(ctx, remotePath, local, entry.ETag, key, "Atualizado")
			default:
				err = e.resolve(ctx, remotePath, local, entry.ETag, key)
			}
			if err != nil && !errors.Is(err, errIncomplete) {
				return err
			}
		}
	}
	return nil
}

// errIncomplete: a conversa no Nextcloud termina no meio de uma linha (envio
// cortado ou em andamento). Não é baixada; a próxima volta tenta de novo.
var errIncomplete = errors.New("conversa incompleta no Nextcloud")

func isConversation(path string) bool { return strings.HasSuffix(path, ".jsonl") }

// download traz o arquivo de lá. verb vai para o registro ("Baixado", "Atualizado").
func (e *Engine) download(ctx context.Context, remotePath, local, etag, key, verb string) error {
	data, err := e.dav.Get(ctx, remotePath)
	if err != nil {
		return err
	}
	data = e.down(remotePath, data)
	if isConversation(local) {
		if !endsComplete(data) {
			e.note("warn", "%s está incompleta no Nextcloud; espero a próxima volta", shortName(remotePath))
			return errIncomplete
		}
		// Conversa só cresce. Se a que veio não continua a daqui, junta as duas.
		if mine, err := os.ReadFile(local); err == nil && !bytes.HasPrefix(data, mine) {
			return e.reconcile(remotePath, local, etag, key, mine, data)
		}
	}
	if err := writeAtomic(local, data, 0o600); err != nil {
		return err
	}
	e.record(key, etag, local)
	e.setStatus(func(s *EngineStatus) { s.Counts.Down++ })
	e.note("down", "%s: %s", verb, shortName(remotePath))
	return nil
}

// reconcile: a conversa mudou aqui e lá. Nada é descartado: fica a que já
// tem tudo, ou a junção das duas (que sobe na volta seguinte).
func (e *Engine) reconcile(remotePath, local, etag, key string, mine, theirs []byte) error {
	result, outcome := mergeConversation(mine, theirs)
	switch outcome {
	case takeTheirs:
		if err := writeAtomic(local, theirs, 0o600); err != nil {
			return err
		}
		e.record(key, etag, local)
		e.setStatus(func(s *EngineStatus) { s.Counts.Down++ })
		e.note("down", "Atualizado: %s", shortName(remotePath))
	case keepMine:
		e.state.Files[key] = FileState{ETag: etag, Size: -1, MTime: -1}
		e.dirty = true
	default:
		if err := writeAtomic(local, result, 0o600); err != nil {
			return err
		}
		e.state.Files[key] = FileState{ETag: etag, Size: -1, MTime: -1}
		e.dirty = true
		e.setStatus(func(s *EngineStatus) { s.Counts.Conflicts++ })
		e.note("warn", "%s mudou nos dois PCs: as duas partes foram juntadas", shortName(remotePath))
	}
	return nil
}

// conflictName: s.json → s.conflito-<data>.json
func conflictName(path, stamp string) string {
	ext := filepath.Ext(path)
	return strings.TrimSuffix(path, ext) + stamp + ext
}

// resolve trata um arquivo que mudou dos dois lados.
func (e *Engine) resolve(ctx context.Context, remotePath, local, etag, key string) error {
	theirs, err := e.dav.Get(ctx, remotePath)
	if err != nil {
		return err
	}
	theirs = e.down(remotePath, theirs)
	mine, err := os.ReadFile(local)
	if err != nil {
		return err
	}
	switch {
	case bytes.Equal(theirs, mine):
		e.record(key, etag, local)
	case bytes.HasPrefix(mine, theirs):
		// A daqui é a maior (ou a de lá ficou cortada): o push manda.
		e.state.Files[key] = FileState{ETag: etag, Size: -1, MTime: -1}
		e.dirty = true
	case isConversation(local) && !endsComplete(theirs):
		e.note("warn", "%s está incompleta no Nextcloud; espero a próxima volta", shortName(remotePath))
		return errIncomplete
	case bytes.HasPrefix(theirs, mine):
		if err := writeAtomic(local, theirs, 0o600); err != nil {
			return err
		}
		e.record(key, etag, local)
		e.setStatus(func(s *EngineStatus) { s.Counts.Down++ })
		e.note("down", "Continuação baixada: %s", shortName(remotePath))
	case isConversation(local):
		return e.reconcile(remotePath, local, etag, key, mine, theirs)
	default:
		copyPath := conflictName(local, ".conflito-"+e.now().Format("20060102-150405"))
		if err := writeAtomic(copyPath, theirs, 0o600); err != nil {
			return err
		}
		e.state.Files[key] = FileState{ETag: etag, Size: -1, MTime: -1}
		e.dirty = true
		e.setStatus(func(s *EngineStatus) { s.Counts.Conflicts++ })
		e.note("warn", "%s mudou nos dois PCs: fica a daqui, e a do Nextcloud foi para %s", shortName(remotePath), filepath.Base(copyPath))
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
		// Duas tentativas: se o servidor mudou entre a última leitura e o envio,
		// a primeira volta com errRemoteChanged, a diferença é resolvida e tenta de novo.
		for attempt := 0; ; attempt++ {
			known, hasState := e.state.Files[key]
			if entry, ok := e.tree.files[remotePath]; ok && (!hasState || known.ETag != entry.ETag) {
				err := e.resolve(ctx, remotePath, f.abs, entry.ETag, key)
				if errors.Is(err, errIncomplete) {
					break
				}
				if err != nil {
					return err
				}
				if e.state.Files[key].Size != -1 {
					break // resolvido sem precisar mandar
				}
				if info, err := os.Stat(f.abs); err == nil && info.ModTime() != f.mtime {
					break // juntou as duas aqui: sobe na próxima volta, depois de assentar
				}
			}
			err := e.upload(ctx, remotePath, f, key)
			if errors.Is(err, errRemoteChanged) && attempt == 0 {
				continue
			}
			if err != nil {
				return err
			}
			break
		}
	}
	return nil
}

// errRemoteChanged: o arquivo no Nextcloud não é mais o que este PC viu por
// último (outro PC mandou uma versão nova). Nada foi sobrescrito.
var errRemoteChanged = errors.New("o arquivo mudou no Nextcloud desde a última leitura")

// upload manda o arquivo com If-Match: o Nextcloud só aceita se o arquivo lá
// ainda for o que este PC viu por último, então nunca passa por cima de uma
// versão nova de outro PC. O PUT vai por HTTP/1.1, em que o Nextcloud confere
// o Content-Length e descarta envio cortado; o tamanho é conferido no fim.
// O arquivo continua o mesmo no servidor (mesmo id e histórico de versões).
func (e *Engine) upload(ctx context.Context, remotePath string, f localFile, key string) error {
	data, err := os.ReadFile(f.abs)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	data = e.up(remotePath, data)
	if err := e.mkdirs(ctx, path.Dir(remotePath)); err != nil {
		return err
	}
	expected := e.state.Files[key].ETag // "" = este PC nunca viu o arquivo lá
	if _, err := e.dav.PutIf(ctx, remotePath, data, f.mtime, expected); err != nil {
		if !errors.Is(err, errRemoteChanged) {
			return err
		}
		current, perr := e.dav.Propfind(ctx, remotePath, "0")
		if perr != nil {
			return perr
		}
		if len(current) > 0 {
			e.tree.files[remotePath] = current[0]
		} else {
			// Sumiu de lá: manda de novo como arquivo novo.
			delete(e.tree.files, remotePath)
			e.state.Files[key] = FileState{Size: -1, MTime: -1}
			e.dirty = true
		}
		return errRemoteChanged
	}
	entries, err := e.dav.Propfind(ctx, remotePath, "0")
	if err != nil {
		return err
	}
	if len(entries) == 0 || entries[0].Size != int64(len(data)) {
		return fmt.Errorf("envio de %s chegou incompleto no Nextcloud", shortName(remotePath))
	}
	etag := entries[0].ETag
	e.tree.files[remotePath] = entries[0]
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
