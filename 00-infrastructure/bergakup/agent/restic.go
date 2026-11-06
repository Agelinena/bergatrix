package main

// Invólucro do restic. O B2 é usado pela API S3 (backend s3: do restic), e
// não pelo backend b2: nativo. Motivo: com Object Lock, um "apagar" pela API
// S3 sem versão vira um marcador de ocultação, e a versão travada continua lá
// até o lock vencer. O backend nativo tenta apagar a versão, e o B2 recusa.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

var resticBin = envOr("BERGAKUP_RESTIC", "restic")

type Restic struct {
	Repo     *Repository
	Storage  *Storage
	Dataset  *Dataset
	env      []string
	hostname string
}

// ErrResticPartial: o restic termina com 3 quando o snapshot foi criado, mas
// alguns arquivos não puderam ser lidos.
var ErrResticPartial = errors.New("snapshot criado, mas alguns arquivos não foram lidos")

func (a *Agent) restic(plan *Plan, repoID string) (*Restic, error) {
	repo, err := plan.repository(repoID)
	if err != nil {
		return nil, err
	}
	storage, err := plan.storage(repo.StorageID)
	if err != nil {
		return nil, err
	}
	dataset, err := plan.dataset(repo.DatasetID)
	if err != nil {
		return nil, err
	}
	password, err := a.opener.Open(repo.Password, "senha do repositório "+repo.URL)
	if err != nil {
		return nil, err
	}
	env := []string{
		"RESTIC_REPOSITORY=" + repo.URL,
		"RESTIC_PASSWORD=" + password,
		"RESTIC_CACHE_DIR=" + filepath.Join(cacheDir, "restic"),
		"RESTIC_PROGRESS_FPS=0.1",
	}
	switch storage.Kind {
	case "b2":
		secret, err := a.opener.Open(storage.Secret, "chave do B2 de "+storage.Name)
		if err != nil {
			return nil, err
		}
		env = append(env, "AWS_ACCESS_KEY_ID="+storage.Username, "AWS_SECRET_ACCESS_KEY="+secret)
		if storage.Region != "" {
			env = append(env, "AWS_DEFAULT_REGION="+storage.Region)
		}
	case "rest":
		if storage.Username != "" {
			secret, err := a.opener.Open(storage.Secret, "senha do rest-server "+storage.Name)
			if err != nil {
				return nil, err
			}
			env = append(env, "RESTIC_REST_USERNAME="+storage.Username, "RESTIC_REST_PASSWORD="+secret)
		}
	}
	return &Restic{Repo: repo, Storage: storage, Dataset: dataset, env: env, hostname: a.hostname}, nil
}

// run executa o restic. Cada linha da saída padrão vai para onLine; a saída
// de erro vai para o log da execução.
func (r *Restic) run(ctx context.Context, run *Run, args []string, onLine func(string)) error {
	cmd := exec.CommandContext(ctx, resticBin, args...)
	cmd.Env = append(baseEnv(), r.env...)
	cmd.WaitDelay = 30 * time.Second
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderrTail bytes.Buffer
	cmd.Stderr = &lineWriter{fn: func(line string) {
		if run != nil {
			run.Log("warn", "restic: "+line)
		}
		if stderrTail.Len() < 4000 {
			stderrTail.WriteString(line + "\n")
		}
	}}
	if run != nil {
		run.Log("info", "$ restic "+strings.Join(args, " "))
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("não consegui rodar o restic (%s): %w", resticBin, err)
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 1<<20), 16<<20)
	for scanner.Scan() {
		if onLine != nil {
			onLine(scanner.Text())
		}
	}
	err = cmd.Wait()
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		if exit.ExitCode() == 3 && len(args) > 0 && args[0] == "backup" {
			return ErrResticPartial
		}
		msg := strings.TrimSpace(stderrTail.String())
		if msg == "" {
			msg = err.Error()
		}
		return fmt.Errorf("restic %s falhou (código %d): %s", args[0], exit.ExitCode(), lastLines(msg, 5))
	}
	return err
}

func baseEnv() []string {
	keep := []string{"PATH", "HOME", "TMPDIR", "LANG"}
	var env []string
	for _, k := range keep {
		if v, ok := os.LookupEnv(k); ok {
			env = append(env, k+"="+v)
		}
	}
	if _, ok := os.LookupEnv("HOME"); !ok {
		env = append(env, "HOME=/root")
	}
	return env
}

func lastLines(s string, n int) string {
	lines := strings.Split(s, "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, " | ")
}

type lineWriter struct {
	fn  func(string)
	buf []byte
}

func (w *lineWriter) Write(p []byte) (int, error) {
	w.buf = append(w.buf, p...)
	for {
		i := bytes.IndexAny(w.buf, "\r\n")
		if i < 0 {
			break
		}
		if line := strings.TrimSpace(string(w.buf[:i])); line != "" {
			w.fn(line)
		}
		w.buf = w.buf[i+1:]
	}
	return len(p), nil
}

// ── Operações ─────────────────────────────────────────────────────────

type BackupSummary struct {
	FilesNew            int64   `json:"files_new"`
	FilesChanged        int64   `json:"files_changed"`
	FilesUnmodified     int64   `json:"files_unmodified"`
	DirsNew             int64   `json:"dirs_new"`
	DirsChanged         int64   `json:"dirs_changed"`
	DataAdded           int64   `json:"data_added"`
	DataAddedPacked     int64   `json:"data_added_packed"`
	TotalFilesProcessed int64   `json:"total_files_processed"`
	TotalBytesProcessed int64   `json:"total_bytes_processed"`
	TotalDuration       float64 `json:"total_duration"`
	SnapshotID          string  `json:"snapshot_id"`
}

func (r *Restic) Backup(ctx context.Context, run *Run, paths, excludes, tags []string) (*BackupSummary, error) {
	excludeFile, err := os.CreateTemp("", "bergakup-exclude-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(excludeFile.Name())
	for _, e := range excludes {
		fmt.Fprintln(excludeFile, e)
	}
	excludeFile.Close()

	args := []string{"backup", "--json", "--host", r.hostname, "--exclude-file", excludeFile.Name(),
		"--exclude-caches"}
	for _, t := range tags {
		args = append(args, "--tag", t)
	}
	args = append(args, paths...)

	var summary *BackupSummary
	lastProgress := time.Time{}
	err = r.run(ctx, run, args, func(line string) {
		var msg struct {
			Type        string  `json:"message_type"`
			PercentDone float64 `json:"percent_done"`
			FilesDone   int64   `json:"files_done"`
			TotalFiles  int64   `json:"total_files"`
			BytesDone   int64   `json:"bytes_done"`
			TotalBytes  int64   `json:"total_bytes"`
			Error       struct {
				Message string `json:"message"`
			} `json:"error"`
			Item string `json:"item"`
		}
		if json.Unmarshal([]byte(line), &msg) != nil {
			run.Log("info", line)
			return
		}
		switch msg.Type {
		case "status":
			if time.Since(lastProgress) > 30*time.Second {
				lastProgress = time.Now()
				run.Log("info", fmt.Sprintf("progresso: %.1f%% · %d/%d arquivos · %s/%s", msg.PercentDone*100,
					msg.FilesDone, msg.TotalFiles, humanBytes(msg.BytesDone), humanBytes(msg.TotalBytes)))
			}
		case "error":
			run.Warn(fmt.Sprintf("não li %s: %s", msg.Item, msg.Error.Message))
		case "summary":
			summary = &BackupSummary{}
			_ = json.Unmarshal([]byte(line), summary)
		}
	})
	if summary == nil && err == nil {
		err = errors.New("o restic terminou sem resumo do backup")
	}
	return summary, err
}

// Forget aplica a retenção só aos snapshots que têm TODAS as tags (no restic,
// "--tag a,b" é E; "--tag a --tag b" seria OU).
func (r *Restic) Forget(ctx context.Context, run *Run, tags []string, keep Retention) error {
	args := []string{"forget", "--group-by", "host,tags", "--tag", strings.Join(tags, ",")}
	rules := 0
	for _, rule := range []struct {
		flag string
		n    int
	}{{"--keep-last", keep.Last}, {"--keep-daily", keep.Daily}, {"--keep-weekly", keep.Weekly},
		{"--keep-monthly", keep.Monthly}} {
		if rule.n > 0 {
			args = append(args, rule.flag, strconv.Itoa(rule.n))
			rules++
		}
	}
	if rules == 0 {
		return errors.New("retenção vazia: nada é apagado")
	}
	return r.run(ctx, run, args, func(line string) { run.Log("info", line) })
}

func (r *Restic) Prune(ctx context.Context, run *Run) error {
	return r.run(ctx, run, []string{"prune"}, func(line string) { run.Log("info", line) })
}

func (r *Restic) Check(ctx context.Context, run *Run, subset string) error {
	args := []string{"check"}
	if subset != "" {
		args = append(args, "--read-data-subset", subset)
	}
	return r.run(ctx, run, args, func(line string) { run.Log("info", line) })
}

func (r *Restic) Unlock(ctx context.Context, run *Run) error {
	return r.run(ctx, run, []string{"unlock"}, nil)
}

func (r *Restic) Init(ctx context.Context, run *Run) error {
	return r.run(ctx, run, []string{"init"}, func(line string) { run.Log("info", line) })
}

// KeyAdd acrescenta uma segunda senha ao repositório (a de recuperação).
func (r *Restic) KeyAdd(ctx context.Context, run *Run, password string) error {
	dir := "/run/bergakup"
	if err := os.MkdirAll(dir, 0o700); err != nil {
		dir = ""
	}
	f, err := os.CreateTemp(dir, "key-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return err
	}
	if _, err := f.WriteString(password); err != nil {
		f.Close()
		return err
	}
	f.Close()
	return r.run(ctx, run, []string{"key", "add", "--new-password-file", f.Name(), "--host", "recuperacao"},
		func(line string) { run.Log("info", line) })
}

type SnapshotInfo struct {
	ID       string         `json:"id"`
	ShortID  string         `json:"short_id"`
	Time     time.Time      `json:"time"`
	Hostname string         `json:"hostname"`
	Paths    []string       `json:"paths"`
	Tags     []string       `json:"tags"`
	Summary  map[string]any `json:"summary"`
}

func (r *Restic) Snapshots(ctx context.Context, run *Run) ([]SnapshotInfo, error) {
	var out bytes.Buffer
	err := r.run(ctx, run, []string{"snapshots", "--json"}, func(line string) { out.WriteString(line) })
	if err != nil {
		return nil, err
	}
	var list []SnapshotInfo
	if out.Len() > 0 {
		if err := json.Unmarshal(out.Bytes(), &list); err != nil {
			return nil, fmt.Errorf("saída inesperada do restic snapshots: %w", err)
		}
	}
	for i := range list {
		if list[i].Tags == nil {
			list[i].Tags = []string{}
		}
		if list[i].Summary == nil {
			list[i].Summary = map[string]any{}
		}
		if list[i].ShortID == "" && len(list[i].ID) >= 8 {
			list[i].ShortID = list[i].ID[:8]
		}
	}
	return list, nil
}

type LsEntry struct {
	Name  string    `json:"name"`
	Type  string    `json:"type"`
	Path  string    `json:"path"`
	Size  int64     `json:"size"`
	Mtime time.Time `json:"mtime"`
}

func (r *Restic) Ls(ctx context.Context, run *Run, snapshot, dir string, limit int) ([]LsEntry, bool, error) {
	var entries []LsEntry
	truncated := false
	err := r.run(ctx, run, []string{"ls", "--json", snapshot, dir}, func(line string) {
		var node struct {
			LsEntry
			StructType string `json:"struct_type"`
		}
		if json.Unmarshal([]byte(line), &node) != nil || node.Path == "" || node.Type == "" {
			return // a primeira linha descreve o snapshot
		}
		if node.Path == dir || filepath.Dir(node.Path) != filepath.Clean(dir) {
			return
		}
		if len(entries) >= limit {
			truncated = true
			return
		}
		entries = append(entries, node.LsEntry)
	})
	return entries, truncated, err
}

func (r *Restic) Restore(ctx context.Context, run *Run, snapshot, target string, includes []string) error {
	args := []string{"restore", snapshot, "--target", target}
	for _, inc := range includes {
		args = append(args, "--include", inc)
	}
	return r.run(ctx, run, args, func(line string) { run.Log("info", line) })
}

// Cat config: confere acesso e senha sem mudar nada.
func (r *Restic) Test(ctx context.Context, run *Run) error {
	return r.run(ctx, run, []string{"cat", "config"}, nil)
}

func humanBytes(n int64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := int64(unit), 0
	for m := n / unit; m >= unit; m /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}
