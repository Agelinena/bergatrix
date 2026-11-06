package main

// Testes contra um Nextcloud de mentira, em memória: WebDAV com etag
// propagado para as pastas (como o de verdade), Login Flow v2 e OCS.

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const testUser = "lucas"

type fakeNextcloud struct {
	mu        sync.Mutex
	files     map[string][]byte
	dirs      map[string]bool
	propfinds atomic.Int32
	polls     atomic.Int32
	server    *httptest.Server
}

func newFakeNextcloud(t *testing.T) *fakeNextcloud {
	f := &fakeNextcloud{files: map[string][]byte{}, dirs: map[string]bool{"": true}}
	f.server = httptest.NewServer(http.HandlerFunc(f.handle))
	t.Cleanup(f.server.Close)
	return f
}

func md5hex(b []byte) string { sum := md5.Sum(b); return hex.EncodeToString(sum[:]) }

// dirETag muda sempre que qualquer coisa abaixo da pasta muda.
func (f *fakeNextcloud) dirETag(dir string) string {
	var parts []string
	prefix := dir + "/"
	if dir == "" {
		prefix = ""
	}
	for p, data := range f.files {
		if strings.HasPrefix(p, prefix) {
			parts = append(parts, p+":"+md5hex(data))
		}
	}
	sort.Strings(parts)
	return md5hex([]byte(dir + strings.Join(parts, ",")))
}

func (f *fakeNextcloud) handle(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	switch {
	case r.URL.Path == "/index.php/login/v2":
		json.NewEncoder(w).Encode(map[string]any{
			"login": f.server.URL + "/login/v2/flow/abc",
			"poll":  map[string]string{"token": "tok", "endpoint": f.server.URL + "/login/v2/poll"},
		})
		return
	case r.URL.Path == "/login/v2/poll":
		r.ParseForm()
		if r.Form.Get("token") != "tok" || f.polls.Add(1) < 2 {
			http.NotFound(w, r) // ainda esperando o navegador
			return
		}
		json.NewEncoder(w).Encode(map[string]string{"server": f.server.URL, "loginName": "Lucas@Example", "appPassword": "app-pass"})
		return
	case r.URL.Path == "/ocs/v2.php/cloud/user":
		if u, p, _ := r.BasicAuth(); u != "Lucas@Example" || p != "app-pass" || r.Header.Get("OCS-APIRequest") != "true" {
			http.Error(w, "no", http.StatusUnauthorized)
			return
		}
		fmt.Fprint(w, `{"ocs":{"data":{"id":"lucas"}}}`)
		return
	}
	if u, p, _ := r.BasicAuth(); u != testUser || p != "app-pass" {
		http.Error(w, "no", http.StatusUnauthorized)
		return
	}
	root := "/remote.php/dav/files/" + testUser
	path := strings.Trim(strings.TrimPrefix(r.URL.Path, root), "/")
	parent := ""
	if i := strings.LastIndex(path, "/"); i >= 0 {
		parent = path[:i]
	}
	body, _ := io.ReadAll(r.Body)
	switch r.Method {
	case "PROPFIND":
		f.propfinds.Add(1)
		_, isFile := f.files[path]
		if !f.dirs[path] && !isFile {
			http.NotFound(w, r)
			return
		}
		entry := func(p string, dir bool) string {
			href := root + "/" + escapePath(p)
			if dir {
				return fmt.Sprintf(`<d:response><d:href>%s/</d:href><d:propstat><d:prop><d:getetag>"%s"</d:getetag><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>`, href, f.dirETag(p))
			}
			return fmt.Sprintf(`<d:response><d:href>%s</d:href><d:propstat><d:prop><d:getetag>"%s"</d:getetag><d:getcontentlength>%d</d:getcontentlength><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>`, href, md5hex(f.files[p]), len(f.files[p]))
		}
		out := []string{entry(path, !isFile)}
		if !isFile && r.Header.Get("Depth") == "1" {
			prefix := path + "/"
			if path == "" {
				prefix = ""
			}
			for d := range f.dirs {
				if d != path && strings.HasPrefix(d, prefix) && !strings.Contains(d[len(prefix):], "/") {
					out = append(out, entry(d, true))
				}
			}
			for p := range f.files {
				if strings.HasPrefix(p, prefix) && !strings.Contains(p[len(prefix):], "/") {
					out = append(out, entry(p, false))
				}
			}
		}
		w.WriteHeader(http.StatusMultiStatus)
		fmt.Fprintf(w, `<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">%s</d:multistatus>`, strings.Join(out, ""))
	case "MKCOL":
		if f.dirs[path] {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		if !f.dirs[parent] {
			w.WriteHeader(http.StatusConflict)
			return
		}
		f.dirs[path] = true
		w.WriteHeader(http.StatusCreated)
	case http.MethodPut:
		if !f.dirs[parent] {
			w.WriteHeader(http.StatusConflict)
			return
		}
		f.files[path] = body
		w.Header().Set("OC-ETag", `"`+md5hex(body)+`"`)
		w.WriteHeader(http.StatusCreated)
	case "MOVE":
		dest, err := url.Parse(r.Header.Get("Destination"))
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		target, _ := url.PathUnescape(dest.Path)
		target = strings.Trim(strings.TrimPrefix(target, root), "/")
		_, targetFile := f.files[target]
		if f.dirs[target] || targetFile {
			w.WriteHeader(http.StatusPreconditionFailed)
			return
		}
		targetParent := ""
		if i := strings.LastIndex(target, "/"); i >= 0 {
			targetParent = target[:i]
		}
		if !f.dirs[targetParent] {
			w.WriteHeader(http.StatusConflict)
			return
		}
		for d := range f.dirs {
			if d == path || strings.HasPrefix(d, path+"/") {
				delete(f.dirs, d)
				f.dirs[target+strings.TrimPrefix(d, path)] = true
			}
		}
		for p, data := range f.files {
			if p == path || strings.HasPrefix(p, path+"/") {
				delete(f.files, p)
				f.files[target+strings.TrimPrefix(p, path)] = data
			}
		}
		w.WriteHeader(http.StatusCreated)
	case http.MethodGet:
		data, ok := f.files[path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Write(data)
	default:
		w.WriteHeader(http.StatusMethodNotAllowed)
	}
}

func (f *fakeNextcloud) file(p string) ([]byte, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	data, ok := f.files[p]
	return data, ok
}

// pc monta um PC: pasta do app, pasta do Claude e o caminho onde o repositório está clonado.
type pc struct {
	engine  *Engine
	syncDir string
	project string
}

func newPC(t *testing.T, nc *fakeNextcloud, name string) *pc {
	base := filepath.Join(t.TempDir(), name)
	cfg := defaultConfig()
	cfg.SyncDir = filepath.Join(base, "ClaudeSync")
	cfg.Server = nc.server.URL
	cfg.User = testUser
	store := &Store{Dir: filepath.Join(base, "appdata")}
	os.MkdirAll(store.Dir, 0o700)
	e := newEngine(store, cfg)
	e.Configure(cfg, newDav(cfg.Server, testUser, "app-pass"))
	// Os arquivos acabaram de ser escritos: pula a espera de 3 s.
	e.now = func() time.Time { return time.Now().Add(time.Minute) }
	return &pc{engine: e, syncDir: cfg.SyncDir, project: filepath.Join(base, "src", "bergatrix")}
}

func (p *pc) folder() string { return filepath.Join(p.syncDir, "projects", encodeProjectDir(p.project)) }

func (p *pc) sync(t *testing.T) {
	t.Helper()
	if err := p.engine.Cycle(context.Background(), true); err != nil {
		t.Fatal(err)
	}
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func jsonl(fields map[string]string) string {
	data, _ := json.Marshal(fields)
	return string(data) + "\n"
}

func TestConversationFollowsProjectToAnotherPC(t *testing.T) {
	nc := newFakeNextcloud(t)
	a := newPC(t, nc, "pc-a")
	session := jsonl(map[string]string{"type": "user", "cwd": a.project}) + jsonl(map[string]string{"type": "assistant"})
	write(t, filepath.Join(a.folder(), "s1.jsonl"), session)
	write(t, filepath.Join(a.folder(), "s1", "tool-results", "r.txt"), "saída")
	write(t, filepath.Join(a.folder(), "memory", "MEMORY.md"), "- nota")
	write(t, filepath.Join(a.syncDir, "CLAUDE.md"), "regras globais")
	write(t, filepath.Join(a.syncDir, ".credentials.json"), "segredo")
	write(t, filepath.Join(a.syncDir, "settings.json"), "{}")
	a.sync(t)

	for _, p := range []string{"Claude/projects/bergatrix/s1.jsonl", "Claude/projects/bergatrix/s1/tool-results/r.txt",
		"Claude/projects/bergatrix/memory/MEMORY.md", "Claude/global/CLAUDE.md"} {
		if _, ok := nc.file(p); !ok {
			t.Errorf("faltou no Nextcloud: %s", p)
		}
	}
	for p := range nc.files {
		if strings.Contains(p, "credentials") || strings.Contains(p, "settings.json") {
			t.Errorf("não devia subir: %s", p)
		}
	}

	// PC B: outro caminho, nenhuma conversa ainda, mas o Claude Code já abriu o projeto (.claude.json).
	b := newPC(t, nc, "pc-b")
	write(t, filepath.Join(b.syncDir, ".claude.json"), fmt.Sprintf(`{"projects":{%q:{}}}`, filepath.ToSlash(b.project)))
	b.sync(t)
	if got := read(t, filepath.Join(b.folder(), "s1.jsonl")); got != session {
		t.Fatalf("conversa no PC B = %q", got)
	}
	if read(t, filepath.Join(b.folder(), "s1", "tool-results", "r.txt")) != "saída" || read(t, filepath.Join(b.syncDir, "CLAUDE.md")) != "regras globais" {
		t.Fatal("subpasta da sessão ou CLAUDE.md não chegou")
	}

	// Continua no B; o A recebe a versão maior, sem conflito.
	longer := session + jsonl(map[string]string{"type": "user", "cwd": b.project, "text": "continuando"})
	write(t, filepath.Join(b.folder(), "s1.jsonl"), longer)
	b.sync(t)
	a.sync(t)
	if got := read(t, filepath.Join(a.folder(), "s1.jsonl")); got != longer {
		t.Fatalf("PC A não recebeu a continuação: %q", got)
	}
	if c := a.engine.Status().Counts.Conflicts; c != 0 {
		t.Fatalf("conflitos = %d", c)
	}
}

func TestUnchangedServerCostsOnePropfind(t *testing.T) {
	nc := newFakeNextcloud(t)
	a := newPC(t, nc, "pc")
	write(t, filepath.Join(a.folder(), "s.jsonl"), jsonl(map[string]string{"cwd": a.project}))
	a.sync(t)
	a.sync(t) // pega o etag depois do próprio envio
	before := nc.propfinds.Load()
	a.sync(t)
	if n := nc.propfinds.Load() - before; n != 1 {
		t.Fatalf("volta sem mudanças fez %d PROPFIND (esperado 1, só a raiz)", n)
	}
	counts := a.engine.Status().Counts
	if counts.Up != 1 || counts.Down != 0 {
		t.Fatalf("contagem = %+v", counts)
	}
}

func TestDivergedConversationKeepsBoth(t *testing.T) {
	nc := newFakeNextcloud(t)
	a := newPC(t, nc, "pc-a")
	b := newPC(t, nc, "pc-b")
	start := jsonl(map[string]string{"cwd": a.project})
	write(t, filepath.Join(a.folder(), "s.jsonl"), start)
	a.sync(t)
	b.engine.cfg.Links["bergatrix"] = b.project // vínculo feito na interface
	b.sync(t)
	if read(t, filepath.Join(b.folder(), "s.jsonl")) != start {
		t.Fatal("PC B não baixou pelo vínculo")
	}

	write(t, filepath.Join(a.folder(), "s.jsonl"), start+`{"text":"no A"}`+"\n")
	write(t, filepath.Join(b.folder(), "s.jsonl"), start+`{"text":"no B"}`+"\n")
	b.sync(t)
	a.sync(t)
	a.sync(t)

	copies, _ := filepath.Glob(filepath.Join(a.folder(), "s.conflito-*.jsonl"))
	if len(copies) != 1 || !strings.Contains(read(t, copies[0]), "no B") {
		t.Fatalf("cópia de conflito = %v", copies)
	}
	if !strings.Contains(read(t, filepath.Join(a.folder(), "s.jsonl")), "no A") {
		t.Fatal("a versão local foi perdida")
	}
	remote, _ := nc.file("Claude/projects/bergatrix/s.jsonl")
	if !strings.Contains(string(remote), "no A") {
		t.Fatal("a versão do A não subiu")
	}
	found := false
	for p := range nc.files {
		found = found || strings.Contains(p, "conflito")
	}
	if !found {
		t.Fatal("a cópia de conflito não subiu")
	}
}

func TestFileStillBeingWrittenWaits(t *testing.T) {
	nc := newFakeNextcloud(t)
	a := newPC(t, nc, "pc")
	a.engine.now = time.Now // sem pular a espera
	write(t, filepath.Join(a.folder(), "s.jsonl"), jsonl(map[string]string{"cwd": a.project}))
	a.sync(t)
	if _, ok := nc.file("Claude/projects/bergatrix/s.jsonl"); ok {
		t.Fatal("subiu antes de o arquivo ficar parado")
	}
}

func TestLoginFlow(t *testing.T) {
	nc := newFakeNextcloud(t)
	store := &Store{Dir: t.TempDir()}
	app, err := newApp(store, func() {})
	if err != nil {
		t.Fatal(err)
	}
	loginURL, err := app.StartLogin(context.Background(), nc.server.URL)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(loginURL, "/login/v2/flow/abc") {
		t.Fatalf("login = %s", loginURL)
	}
	deadline := time.Now().Add(15 * time.Second)
	for !app.Status().Connected {
		if time.Now().After(deadline) {
			t.Fatalf("não conectou: %+v", app.Status().Login)
		}
		time.Sleep(100 * time.Millisecond)
	}
	st := app.Status()
	if st.User != "lucas" || st.Server != nc.server.URL {
		t.Fatalf("usuário/servidor = %s %s (o ID do OCS, não o nome de login)", st.User, st.Server)
	}
	secret, err := loadSecret(store, "lucas")
	if err != nil || secret != "app-pass" {
		t.Fatalf("senha guardada = %q, %v", secret, err)
	}
	raw, _ := os.ReadFile(filepath.Join(store.Dir, "config.json"))
	if strings.Contains(string(raw), "app-pass") {
		t.Fatal("a senha apareceu no config.json")
	}
	if files, _ := os.ReadDir(store.Dir); len(files) > 0 {
		for _, f := range files {
			data, _ := os.ReadFile(filepath.Join(store.Dir, f.Name()))
			if strings.Contains(string(data), "app-pass") {
				t.Fatalf("a senha está em texto puro em %s", f.Name())
			}
		}
	}
}

func TestServerMustUseHTTPS(t *testing.T) {
	if _, err := normalizeServer("http://storange.example.com"); err == nil {
		t.Fatal("aceitou http:// fora do localhost")
	}
	if got, _ := normalizeServer("storange.example.com/"); got != "https://storange.example.com" {
		t.Fatalf("normalizado = %s", got)
	}
}

func TestMigrationNeverOverwrites(t *testing.T) {
	src, dst := t.TempDir(), t.TempDir()
	write(t, filepath.Join(src, "projects", "p", "a.jsonl"), "antigo")
	write(t, filepath.Join(src, ".credentials.json"), "login")
	write(t, filepath.Join(dst, "projects", "p", "a.jsonl"), "novo")
	if err := copyMissing(src, dst); err != nil {
		t.Fatal(err)
	}
	if read(t, filepath.Join(dst, "projects", "p", "a.jsonl")) != "novo" || read(t, filepath.Join(dst, ".credentials.json")) != "login" {
		t.Fatal("a cópia sobrescreveu ou deixou de copiar")
	}
}

func TestWebGuard(t *testing.T) {
	app, err := newApp(&Store{Dir: t.TempDir()}, func() {})
	if err != nil {
		t.Fatal(err)
	}
	handler := newWebServer(app, defaultPort)
	do := func(method, host, origin string, header bool) int {
		req := httptest.NewRequest(method, "http://"+host+"/api/sync", strings.NewReader("{}"))
		req.Host = host
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		if header {
			req.Header.Set("X-Claude-Sync", "1")
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		return rec.Code
	}
	local := "127.0.0.1:" + defaultPort
	cases := []struct {
		name         string
		method, host string
		origin       string
		header       bool
		want         int
	}{
		{"ação do próprio app", "POST", local, "http://" + local, true, 200},
		{"sem o cabeçalho", "POST", local, "", false, 403},
		{"outro site", "POST", local, "https://evil.example", true, 403},
		{"DNS rebinding", "GET", "evil.example:" + defaultPort, "", false, 403},
	}
	for _, c := range cases {
		if got := do(c.method, c.host, c.origin, c.header); got != c.want {
			t.Errorf("%s: HTTP %d, esperado %d", c.name, got, c.want)
		}
	}
	req := httptest.NewRequest("GET", "http://"+local+"/api/status", nil)
	req.Host = local
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"connected":false`) {
		t.Fatalf("status: %d %s", rec.Code, rec.Body.String())
	}
	if csp := rec.Header().Get("Content-Security-Policy"); !strings.Contains(csp, "default-src 'self'") {
		t.Fatalf("CSP = %q", csp)
	}
}

func TestEncodeMatchesClaudeCode(t *testing.T) {
	got := encodeProjectDir(`c:\Users\LucasAmaral\OneDrive - Assist Cloud\Documentos\bergatrix`)
	if got != "c--Users-LucasAmaral-OneDrive---Assist-Cloud-Documentos-bergatrix" {
		t.Fatal(got)
	}
}
