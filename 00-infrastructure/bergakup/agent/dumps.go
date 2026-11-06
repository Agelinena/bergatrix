package main

// Dumps de banco, descobertos pelas labels dos containers:
//
//   bergatrix.backup.dump: postgres         pg_dump -Fc com o banco rodando
//   bergatrix.backup.pg_user / pg_db         opcionais (padrão: POSTGRES_USER e POSTGRES_DB do container)
//   bergatrix.backup.dump: sqlite
//   bergatrix.backup.sqlite: /data/db.sqlite3,/data/outro.db   caminhos de dentro do container
//
// Os arquivos vão para <dumps_dir>/<stack>/ e um manifest.json diz de onde
// cada um veio. Na restauração, import_dumps usa o manifesto para devolver
// cada dump ao seu banco.

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const (
	labelDump    = "bergatrix.backup.dump"
	labelPgUser  = "bergatrix.backup.pg_user"
	labelPgDB    = "bergatrix.backup.pg_db"
	labelSQLite  = "bergatrix.backup.sqlite"
	manifestName = "manifest.json"
)

var safeName = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,63}$`)

type DumpTarget struct {
	Stack     string   `json:"stack"`
	Container string   `json:"container"`
	Kind      string   `json:"kind"`
	Running   bool     `json:"running"`
	Files     []string `json:"files,omitempty"` // sqlite: caminhos no host
	Problem   string   `json:"problem,omitempty"`
}

type ManifestEntry struct {
	Stack     string    `json:"stack"`
	Container string    `json:"container"`
	Kind      string    `json:"kind"`
	Dump      string    `json:"dump"`             // relativo ao dumps_dir
	Source    string    `json:"source,omitempty"` // sqlite: arquivo original no host
	PgUser    string    `json:"pg_user,omitempty"`
	PgDB      string    `json:"pg_db,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// discoverDumps lê as labels e avisa sobre bancos sem dump: um Postgres sem
// label cuja pasta foi excluída do backup ficaria sem cópia nenhuma.
func discoverDumps(containers []Container) ([]DumpTarget, []string) {
	var targets []DumpTarget
	var warnings []string
	for _, c := range containers {
		kind := c.Labels[labelDump]
		stack := c.Project
		if stack == "" {
			stack = c.Name
		}
		switch kind {
		case "postgres":
			targets = append(targets, DumpTarget{Stack: stack, Container: c.Name, Kind: kind, Running: c.Running})
		case "sqlite":
			t := DumpTarget{Stack: stack, Container: c.Name, Kind: kind, Running: c.Running}
			for _, inside := range strings.Split(c.Labels[labelSQLite], ",") {
				inside = strings.TrimSpace(inside)
				if inside == "" {
					continue
				}
				if host, ok := c.hostPath(inside); ok {
					t.Files = append(t.Files, host)
				} else {
					t.Problem = fmt.Sprintf("%s não está num volume montado", inside)
				}
			}
			if len(t.Files) == 0 && t.Problem == "" {
				t.Problem = "label " + labelSQLite + " vazia"
			}
			if t.Problem != "" {
				warnings = append(warnings, fmt.Sprintf("%s: %s", c.Name, t.Problem))
			}
			targets = append(targets, t)
		case "":
			image := strings.ToLower(c.Image)
			if strings.Contains(image, "postgres") || strings.Contains(image, "vectorchord") ||
				strings.Contains(image, "mariadb") || strings.Contains(image, "mysql") {
				warnings = append(warnings, fmt.Sprintf("%s (%s) parece um banco, mas não tem a label %s: "+
					"sem dump, ele só entra no backup se a pasta dele não estiver excluída", c.Name, c.Image, labelDump))
			}
		default:
			warnings = append(warnings, fmt.Sprintf("%s: tipo de dump desconhecido %q", c.Name, kind))
		}
	}
	return targets, warnings
}

// runDumps faz o dump de cada banco. skip: stacks fora do backup.
func (a *Agent) runDumps(ctx context.Context, run *Run, dumpsDir string, skip map[string]bool) error {
	if dumpsDir == "" {
		return fmt.Errorf("dumps_dir não configurado")
	}
	containers, err := listContainers(ctx)
	if err != nil {
		return err
	}
	targets, warnings := discoverDumps(containers)
	for _, w := range warnings {
		run.Warn(w)
	}
	byName := map[string]Container{}
	for _, c := range containers {
		byName[c.Name] = c
	}
	var manifest []ManifestEntry
	_ = readJSON(filepath.Join(dumpsDir, manifestName), &manifest)
	keep := map[string]ManifestEntry{}
	for _, m := range manifest {
		keep[m.Dump] = m
	}
	failures := 0
	for _, t := range targets {
		if skip[t.Stack] || t.Problem != "" {
			continue
		}
		if !safeName.MatchString(t.Stack) || !safeName.MatchString(t.Container) {
			run.Warn("nome inseguro, pulando: " + t.Container)
			continue
		}
		dir := filepath.Join(dumpsDir, t.Stack)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
		started := time.Now()
		var entries []ManifestEntry
		switch t.Kind {
		case "postgres":
			if !t.Running {
				run.Warn(t.Container + " está parado: o dump anterior continua valendo")
				continue
			}
			entry, err := pgDump(ctx, byName[t.Container], dir)
			if err != nil {
				run.Warn(fmt.Sprintf("dump de %s falhou: %v", t.Container, err))
				failures++
				continue
			}
			entries = append(entries, entry)
		case "sqlite":
			for i, src := range t.Files {
				name := fmt.Sprintf("%s.%d.%s.sqlite", t.Container, i, strings.TrimSuffix(filepath.Base(src), filepath.Ext(src)))
				dest := filepath.Join(dir, name)
				if err := sqliteBackup(ctx, src, dest); err != nil {
					run.Warn(fmt.Sprintf("dump de %s (%s) falhou: %v", t.Container, src, err))
					failures++
					continue
				}
				entries = append(entries, ManifestEntry{Kind: "sqlite", Dump: filepath.Join(t.Stack, name), Source: src})
			}
		}
		for _, e := range entries {
			e.Stack, e.Container, e.CreatedAt = t.Stack, t.Container, time.Now()
			keep[e.Dump] = e
			info, _ := os.Stat(filepath.Join(dumpsDir, e.Dump))
			size := int64(0)
			if info != nil {
				size = info.Size()
			}
			run.Log("info", fmt.Sprintf("dump %s → %s (%s, %s)", t.Container, e.Dump, humanBytes(size),
				time.Since(started).Round(time.Second)))
		}
	}
	manifest = manifest[:0]
	for _, m := range keep {
		manifest = append(manifest, m)
	}
	if err := writeJSONAtomic(filepath.Join(dumpsDir, manifestName), manifest, 0o600); err != nil {
		return err
	}
	if failures > 0 {
		return fmt.Errorf("%d dump(s) falharam", failures)
	}
	return nil
}

func pgIdentity(c Container) (user, db string) {
	user, db = c.Labels[labelPgUser], c.Labels[labelPgDB]
	if !safeName.MatchString(user) {
		user = ""
	}
	if !safeName.MatchString(db) {
		db = ""
	}
	return
}

// pgCommand monta o comando dentro do container. Sem label, usa as variáveis
// POSTGRES_USER e POSTGRES_DB do próprio container: o agente não precisa da senha.
func pgCommand(c Container, tool string, extra string) string {
	user, db := pgIdentity(c)
	u := `"${POSTGRES_USER:-postgres}"`
	d := `"${POSTGRES_DB:-${POSTGRES_USER:-postgres}}"`
	if user != "" {
		u = user
	}
	if db != "" {
		d = db
	}
	return fmt.Sprintf("%s -U %s -d %s %s", tool, u, d, extra)
}

func pgDump(ctx context.Context, c Container, dir string) (ManifestEntry, error) {
	name := c.Name + ".pgdump"
	final := filepath.Join(dir, name)
	tmp := final + ".tmp"
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return ManifestEntry{}, err
	}
	cmd := exec.CommandContext(ctx, "docker", "exec", c.Name, "sh", "-c", pgCommand(c, "pg_dump", "-Fc"))
	cmd.Stdout = f
	var stderr strings.Builder
	cmd.Stderr = &stderr
	err = cmd.Run()
	closeErr := f.Close()
	if err != nil {
		os.Remove(tmp)
		return ManifestEntry{}, fmt.Errorf("%v: %s", err, strings.TrimSpace(stderr.String()))
	}
	if closeErr != nil {
		os.Remove(tmp)
		return ManifestEntry{}, closeErr
	}
	if info, _ := os.Stat(tmp); info == nil || info.Size() == 0 {
		os.Remove(tmp)
		return ManifestEntry{}, fmt.Errorf("dump vazio")
	}
	if err := os.Rename(tmp, final); err != nil {
		return ManifestEntry{}, err
	}
	user, db := pgIdentity(c)
	return ManifestEntry{Kind: "postgres", Dump: filepath.Join(filepath.Base(dir), name), PgUser: user, PgDB: db}, nil
}

// sqliteBackup faz uma cópia consistente com o app rodando (VACUUM INTO).
func sqliteBackup(ctx context.Context, src, dest string) error {
	if _, err := os.Stat(src); err != nil {
		return err
	}
	tmp := dest + ".tmp"
	os.Remove(tmp)
	db, err := sql.Open("sqlite", "file:"+src+"?_pragma=busy_timeout(30000)")
	if err != nil {
		return err
	}
	defer db.Close()
	if _, err := db.ExecContext(ctx, "VACUUM INTO '"+strings.ReplaceAll(tmp, "'", "''")+"'"); err != nil {
		os.Remove(tmp)
		return err
	}
	if err := os.Chmod(tmp, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, dest)
}

// ── Importação (restauração dos bancos) ───────────────────────────────

// importDumps devolve os dumps do manifesto aos bancos. Para cada stack:
// para os containers que não são o banco, importa, e sobe de novo.
func importDumps(ctx context.Context, logf func(level, msg string), dumpsDir string, stacks []string) error {
	var manifest []ManifestEntry
	if err := readJSON(filepath.Join(dumpsDir, manifestName), &manifest); err != nil {
		return fmt.Errorf("sem manifesto de dumps em %s (restaure o conjunto do servidor antes): %w", dumpsDir, err)
	}
	wanted := map[string]bool{}
	for _, s := range stacks {
		wanted[s] = true
	}
	containers, err := listContainers(ctx)
	if err != nil {
		return err
	}
	byName := map[string]Container{}
	for _, c := range containers {
		byName[c.Name] = c
	}
	var failures []string
	for _, m := range manifest {
		if len(wanted) > 0 && !wanted[m.Stack] {
			continue
		}
		db, ok := byName[m.Container]
		if !ok {
			failures = append(failures, m.Container+": container não existe (suba a stack antes)")
			continue
		}
		// Os outros containers da stack param durante a importação.
		var others []string
		for _, c := range containers {
			if c.Project == db.Project && c.Name != db.Name && c.Running {
				others = append(others, c.ID)
			}
		}
		if m.Kind == "sqlite" {
			others = append(others, db.ID) // o arquivo é do próprio app
		}
		if len(others) > 0 {
			logf("info", fmt.Sprintf("%s: parando %d container(s) para importar", m.Stack, len(others)))
			if _, err := docker(ctx, append([]string{"stop", "-t", "60"}, others...)...); err != nil {
				failures = append(failures, err.Error())
				continue
			}
		}
		err := importOne(ctx, logf, dumpsDir, m, db)
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", m.Dump, err))
		} else {
			logf("info", fmt.Sprintf("importado: %s → %s", m.Dump, m.Container))
		}
		if len(others) > 0 {
			if _, err := docker(context.Background(), append([]string{"start"}, others...)...); err != nil {
				failures = append(failures, err.Error())
			}
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf("importação com falhas: %s", strings.Join(failures, "; "))
	}
	return nil
}

func importOne(ctx context.Context, logf func(level, msg string), dumpsDir string, m ManifestEntry, db Container) error {
	path := filepath.Join(dumpsDir, m.Dump)
	switch m.Kind {
	case "postgres":
		if err := waitHealthy(ctx, db.Name, 3*time.Minute); err != nil {
			return err
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		cmd := exec.CommandContext(ctx, "docker", "exec", "-i", db.Name, "sh", "-c",
			pgCommand(db, "pg_restore", "--clean --if-exists --no-owner --exit-on-error"))
		cmd.Stdin = f
		out, err := cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("%v: %s", err, lastLines(strings.TrimSpace(string(out)), 5))
		}
		return nil
	case "sqlite":
		if m.Source == "" {
			return fmt.Errorf("manifesto sem o caminho original")
		}
		for _, suffix := range []string{"-wal", "-shm"} {
			os.Remove(m.Source + suffix)
		}
		return copyFile(path, m.Source)
	}
	return fmt.Errorf("tipo desconhecido %q", m.Kind)
}

func waitHealthy(ctx context.Context, name string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		out, err := docker(ctx, "inspect", "-f", "{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{end}}", name)
		state := strings.Fields(string(out))
		if err == nil && len(state) > 0 && state[0] == "true" && (len(state) == 1 || state[1] == "healthy") {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("%s não ficou pronto em %s", name, timeout)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
}

func copyFile(src, dest string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	info, err := os.Stat(dest)
	perm := os.FileMode(0o644)
	if err == nil {
		perm = info.Mode().Perm()
	}
	tmp := dest + ".bergakup-tmp"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, perm)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(tmp)
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	if info != nil {
		if st, ok := statOwner(info); ok {
			_ = os.Chown(tmp, st.uid, st.gid)
		}
	}
	return os.Rename(tmp, dest)
}

// dumpsSummary vai no sinal de vida: o que a interface mostra na tela de stacks.
func dumpsSummary(targets []DumpTarget) json.RawMessage {
	data, _ := json.Marshal(targets)
	return data
}
