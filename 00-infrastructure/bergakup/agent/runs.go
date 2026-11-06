package main

// Relatórios para a API. Tudo passa por uma fila em ordem, gravada em disco:
// se a API estiver fora (inclusive durante um backup frio, que para a própria
// stack do Bergakup), os relatórios esperam e são entregues quando ela voltar.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const maxOutbox = 20000

type outMsg struct {
	Path string          `json:"path"`
	Body json.RawMessage `json:"body"`
	Log  bool            `json:"log,omitempty"`
}

type Reporter struct {
	client *Client
	path   string
	mu     sync.Mutex
	queue  []outMsg
	wake   chan struct{}
}

func newReporter(client *Client) *Reporter {
	r := &Reporter{client: client, path: filepath.Join(stateDir, "outbox.json"), wake: make(chan struct{}, 1)}
	_ = readJSON(r.path, &r.queue)
	return r
}

func (r *Reporter) send(path string, body any, isLog bool) {
	data, err := json.Marshal(body)
	if err != nil {
		log.Printf("relatório inválido para %s: %v", path, err)
		return
	}
	r.mu.Lock()
	r.queue = append(r.queue, outMsg{Path: path, Body: data, Log: isLog})
	if len(r.queue) > maxOutbox {
		// Sem a API por muito tempo: descarta linhas de log antigas, nunca o início ou o fim de uma execução.
		kept := r.queue[:0]
		drop := len(r.queue) - maxOutbox
		for _, m := range r.queue {
			if drop > 0 && m.Log {
				drop--
				continue
			}
			kept = append(kept, m)
		}
		r.queue = kept
	}
	r.persistLocked()
	r.mu.Unlock()
	select {
	case r.wake <- struct{}{}:
	default:
	}
}

func (r *Reporter) persistLocked() {
	if err := writeJSONAtomic(r.path, r.queue, 0o600); err != nil {
		log.Printf("não consegui gravar a fila de relatórios: %v", err)
	}
}

func (r *Reporter) loop(ctx context.Context) {
	backoff := time.Second
	for {
		r.mu.Lock()
		var next *outMsg
		if len(r.queue) > 0 {
			m := r.queue[0]
			next = &m
		}
		r.mu.Unlock()
		if next == nil {
			select {
			case <-ctx.Done():
				return
			case <-r.wake:
				continue
			}
		}
		sendCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		err := r.client.do(sendCtx, "POST", next.Path, next.Body, nil)
		cancel()
		var httpErr *HTTPError
		// 4xx (menos 401/429) não melhora tentando de novo: descarta.
		permanent := errors.As(err, &httpErr) && httpErr.Status >= 400 && httpErr.Status < 500 &&
			httpErr.Status != 401 && httpErr.Status != 429
		if err != nil && !permanent {
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			backoff = min(backoff*2, time.Minute)
			continue
		}
		if permanent {
			log.Printf("relatório recusado pela API (%s): %v", next.Path, err)
		}
		backoff = time.Second
		r.mu.Lock()
		if len(r.queue) > 0 {
			r.queue = r.queue[1:]
		}
		r.persistLocked()
		r.mu.Unlock()
	}
}

// ── Execução ──────────────────────────────────────────────────────────

var heavyKinds = map[string]bool{"backup": true, "forget": true, "prune": true, "check": true,
	"restore": true, "import_dumps": true, "init": true}

type logLine struct {
	Seq   int       `json:"seq"`
	TS    time.Time `json:"ts"`
	Level string    `json:"level"`
	Line  string    `json:"line"`
}

type Run struct {
	ID       string
	Kind     string
	Label    string
	a        *Agent
	mu       sync.Mutex
	pending  []logLine
	seq      int
	warnings []string
	done     chan struct{}
	started  time.Time
}

func (a *Agent) startRun(kind, label, jobID, repoID, commandID, trigger string) *Run {
	run := &Run{ID: newUUID(), Kind: kind, Label: label, a: a, done: make(chan struct{}), started: time.Now()}
	body := map[string]any{"id": run.ID, "kind": kind, "trigger": trigger, "started_at": run.started}
	for k, v := range map[string]string{"job_id": jobID, "repository_id": repoID, "command_id": commandID} {
		if v != "" {
			body[k] = v
		}
	}
	a.reporter.send("/runs", body, false)
	go run.flusher()
	return run
}

func (r *Run) Log(level, msg string) {
	if r == nil {
		log.Printf("[%s] %s", level, msg)
		return
	}
	log.Printf("[%s %s] %s", r.Kind, level, msg)
	r.mu.Lock()
	r.pending = append(r.pending, logLine{Seq: r.seq, TS: time.Now(), Level: level, Line: msg})
	r.seq++
	r.mu.Unlock()
}

func (r *Run) Warn(msg string) {
	r.Log("warn", msg)
	r.mu.Lock()
	if len(r.warnings) < 50 {
		r.warnings = append(r.warnings, msg)
	}
	r.mu.Unlock()
}

func (r *Run) flush() {
	r.mu.Lock()
	lines := r.pending
	r.pending = nil
	r.mu.Unlock()
	for len(lines) > 0 {
		n := min(len(lines), 500)
		r.a.reporter.send("/runs/"+r.ID+"/logs", lines[:n], true)
		lines = lines[n:]
	}
}

func (r *Run) flusher() {
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-r.done:
			return
		case <-ticker.C:
			r.flush()
		}
	}
}

// Finish fecha a execução: sucesso, aviso (terminou, mas com avisos) ou falha.
// Falha e aviso de execuções pesadas mandam e-mail direto do agente.
func (r *Run) Finish(err error, summary map[string]any) {
	if summary == nil {
		summary = map[string]any{}
	}
	status := "success"
	r.mu.Lock()
	warnings := append([]string(nil), r.warnings...)
	r.mu.Unlock()
	if len(warnings) > 0 {
		status = "warning"
		summary["warnings"] = warnings
	}
	errText := ""
	if err != nil {
		status = "failed"
		errText = err.Error()
		r.Log("error", errText)
	}
	took := time.Since(r.started).Round(time.Second)
	summary["duration_seconds"] = int(took.Seconds())
	r.Log("info", fmt.Sprintf("fim: %s em %s", status, took))
	close(r.done)
	r.flush()
	body := map[string]any{"status": status, "finished_at": time.Now(), "summary": summary}
	if errText != "" {
		body["error"] = errText
	}
	r.a.reporter.send("/runs/"+r.ID+"/finish", body, false)
	if heavyKinds[r.Kind] && status != "success" {
		subject := fmt.Sprintf("[bergakup] %s: %s", r.Label, map[string]string{"failed": "FALHOU", "warning": "terminou com avisos"}[status])
		text := fmt.Sprintf("Execução: %s (%s)\nAgente: %s\nInício: %s\nDuração: %s\n\n", r.Label, r.Kind,
			r.a.hostname, r.started.Format("02/01/2006 15:04"), took)
		if errText != "" {
			text += "Erro:\n" + errText + "\n\n"
		}
		if len(warnings) > 0 {
			text += "Avisos:\n- " + strings.Join(warnings, "\n- ") + "\n"
		}
		r.a.sendMail(subject, text)
	}
}
