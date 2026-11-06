package main

// Interface web local. Só escuta em 127.0.0.1 e se protege de outros sites:
//   - o cabeçalho Host precisa ser o do próprio app (contra DNS rebinding);
//   - toda ação exige o cabeçalho X-Claude-Sync, que outro site só mandaria
//     com um preflight de CORS que o app nunca aprova, e o Origin, quando
//     vem, precisa ser o do app.

import (
	"embed"
	"encoding/json"
	"io/fs"
	"net/http"
	"strings"
)

//go:embed web
var webFiles embed.FS

type webServer struct {
	app   *App
	hosts map[string]bool
}

func newWebServer(app *App, port string) http.Handler {
	s := &webServer{app: app, hosts: map[string]bool{"127.0.0.1:" + port: true, "localhost:" + port: true}}
	static, _ := fs.Sub(webFiles, "web")
	mux := http.NewServeMux()
	mux.Handle("GET /", http.FileServerFS(static))
	mux.HandleFunc("GET /api/status", s.status)
	mux.HandleFunc("POST /api/login", s.loginStart)
	mux.HandleFunc("POST /api/login/cancel", s.action(func(r *http.Request) error { app.CancelLogin(); return nil }))
	mux.HandleFunc("POST /api/logout", s.action(func(r *http.Request) error { return app.Logout(r.Context()) }))
	mux.HandleFunc("POST /api/activate", s.action(func(r *http.Request) error {
		var body struct {
			SyncDir string `json:"syncDir"`
		}
		if err := decode(r, &body); err != nil {
			return err
		}
		return app.Activate(strings.TrimSpace(body.SyncDir))
	}))
	mux.HandleFunc("POST /api/deactivate", s.action(func(r *http.Request) error { return app.Deactivate() }))
	mux.HandleFunc("POST /api/settings", s.action(func(r *http.Request) error {
		var body Settings
		if err := decode(r, &body); err != nil {
			return err
		}
		return app.UpdateSettings(body)
	}))
	mux.HandleFunc("POST /api/link", s.action(func(r *http.Request) error {
		var body struct {
			Key  string `json:"key"`
			Path string `json:"path"`
		}
		if err := decode(r, &body); err != nil {
			return err
		}
		return app.Link(body.Key, strings.TrimSpace(body.Path))
	}))
	mux.HandleFunc("GET /api/remote-folders", s.remoteFolders)
	mux.HandleFunc("POST /api/remote-dir", s.action(func(r *http.Request) error {
		var body struct {
			Path string `json:"path"`
			Move bool   `json:"move"`
		}
		if err := decode(r, &body); err != nil {
			return err
		}
		return app.SetRemoteDir(r.Context(), body.Path, body.Move)
	}))
	mux.HandleFunc("POST /api/sync", s.action(func(r *http.Request) error { app.SyncNow(); return nil }))
	mux.HandleFunc("POST /api/open-folder", s.action(func(r *http.Request) error { return app.OpenFolder() }))
	mux.HandleFunc("POST /api/quit", s.action(func(r *http.Request) error {
		go app.Quit()
		return nil
	}))
	return s.guard(mux)
}

func (s *webServer) guard(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.hosts[r.Host] {
			http.Error(w, "host não permitido", http.StatusForbidden)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			origin := r.Header.Get("Origin")
			if r.Header.Get("X-Claude-Sync") != "1" || (origin != "" && origin != "http://"+r.Host) {
				http.Error(w, "pedido recusado", http.StatusForbidden)
				return
			}
		}
		h := w.Header()
		h.Set("Content-Security-Policy", "default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "DENY")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}

func decode(r *http.Request, v any) error {
	r.Body = http.MaxBytesReader(nil, r.Body, 64*1024)
	return json.NewDecoder(r.Body).Decode(v)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func (s *webServer) action(fn func(*http.Request) error) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if err := fn(r); err != nil {
			writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, s.app.Status())
	}
}

func (s *webServer) status(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.app.Status())
}

func (s *webServer) remoteFolders(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Query().Get("path")
	folders, err := s.app.RemoteFolders(r.Context(), path)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"path": strings.Trim(path, "/"), "folders": folders})
}

func (s *webServer) loginStart(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Server string `json:"server"`
	}
	if err := decode(r, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "pedido inválido"})
		return
	}
	url, err := s.app.StartLogin(r.Context(), body.Server)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"url": url})
}
