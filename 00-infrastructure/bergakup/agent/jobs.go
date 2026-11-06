package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ── Estado das tarefas (detecção de anomalia) ─────────────────────────

type JobState struct {
	TotalFiles   int64      `json:"total_files"`
	LastSuccess  time.Time  `json:"last_success"`
	BlockedSince *time.Time `json:"blocked_since,omitempty"`
	BlockReason  string     `json:"block_reason,omitempty"`
}

var jobStateMu sync.Mutex

func jobStatePath() string { return filepath.Join(stateDir, "jobstate.json") }

func loadJobStates() map[string]JobState {
	states := map[string]JobState{}
	_ = readJSON(jobStatePath(), &states)
	return states
}

func updateJobState(id string, fn func(*JobState)) {
	jobStateMu.Lock()
	defer jobStateMu.Unlock()
	states := loadJobStates()
	st := states[id]
	fn(&st)
	states[id] = st
	_ = writeJSONAtomic(jobStatePath(), states, 0o600)
}

// ── Backup ────────────────────────────────────────────────────────────

func (a *Agent) backupJob(ctx context.Context, jobID, trigger, commandID string) {
	plan := a.currentPlan()
	job, err := plan.job(jobID)
	if err != nil {
		run := a.startRun("backup", "backup", "", "", commandID, trigger)
		run.Finish(err, nil)
		return
	}
	run := a.startRun("backup", job.Name, job.ID, job.RepositoryID, commandID, trigger)
	summary := map[string]any{}
	err = a.doBackup(ctx, run, plan, job, summary)
	run.Finish(err, summary)
	ping(job.PingURL, err == nil)
}

func (a *Agent) doBackup(ctx context.Context, run *Run, plan *Plan, job *Job, summary map[string]any) error {
	r, err := a.restic(plan, job.RepositoryID)
	if err != nil {
		return err
	}
	ds := r.Dataset
	summary["dataset"] = ds.Slug
	run.Log("info", fmt.Sprintf("conjunto %s → %s", ds.Slug, r.Repo.URL))

	paths := append([]string(nil), ds.Paths...)
	excludes := append([]string(nil), ds.Excludes...)

	// Uma origem vazia ou ausente (NAS desmontado, disco que não subiu) daria
	// um snapshot vazio, e a retenção depois apagaria os bons. Melhor falhar.
	for _, p := range paths {
		if err := checkSource(p); err != nil {
			return err
		}
	}
	if err := r.Unlock(ctx, run); err != nil {
		run.Log("warn", "unlock: "+err.Error())
	}

	quiesce := newQuiesce(readStacksOrder(plan.Host.StacksFile))
	if ds.Consistency == "policies" || ds.Consistency == "cold" {
		skip := map[string]bool{}
		for stack, mode := range plan.StackPolicies {
			if mode == "skip" {
				skip[stack] = true
				for _, p := range ds.Paths {
					excludes = append(excludes, filepath.Join(p, stack))
				}
			}
		}
		if dir := plan.Host.DumpsDir; dir != "" && !underAny(dir, paths) {
			paths = append(paths, dir)
		}
		if err := a.runDumps(ctx, run, plan.Host.DumpsDir, skip); err != nil {
			run.Warn("dumps: " + err.Error())
		}
		modes := map[string]string{}
		if ds.Consistency == "cold" {
			for _, stack := range quiesce.order {
				modes[stack] = "stop"
			}
		} else {
			for stack, mode := range plan.StackPolicies {
				if mode == "stop" || mode == "pause" {
					modes[stack] = mode
				}
			}
		}
		if len(modes) > 0 {
			if err := quiesce.Apply(ctx, run, modes); err != nil {
				if rerr := quiesce.Resume(run); rerr != nil {
					run.Warn(rerr.Error())
				}
				return fmt.Errorf("não consegui parar as stacks: %w", err)
			}
		}
	}
	resumed := false
	resume := func() {
		if resumed || quiesce.empty() {
			return
		}
		resumed = true
		if err := quiesce.Resume(run); err != nil {
			run.Warn(err.Error())
		}
	}
	defer resume()

	tags := []string{"bergakup", "dataset:" + ds.Slug}
	result, err := r.Backup(ctx, run, paths, excludes, tags)
	resume() // as stacks voltam assim que a cópia termina
	if errors.Is(err, ErrResticPartial) {
		run.Warn(err.Error())
	} else if err != nil {
		return err
	}
	if result == nil {
		return errors.New("backup sem resumo")
	}
	summary["snapshot_id"] = result.SnapshotID
	summary["files_new"] = result.FilesNew
	summary["files_changed"] = result.FilesChanged
	summary["files_unmodified"] = result.FilesUnmodified
	summary["total_files"] = result.TotalFilesProcessed
	summary["total_bytes"] = result.TotalBytesProcessed
	summary["data_added"] = result.DataAdded
	summary["data_added_packed"] = result.DataAddedPacked
	run.Log("info", fmt.Sprintf("snapshot %s: %d novos, %d alterados, %d iguais · %s enviados",
		short(result.SnapshotID), result.FilesNew, result.FilesChanged, result.FilesUnmodified,
		humanBytes(max(result.DataAddedPacked, result.DataAdded))))

	// Anomalia: muita coisa mudou (ou sumiu) de uma vez. Pode ser ransomware ou
	// um disco errado. A retenção fica suspensa até alguém confirmar na interface,
	// para os snapshots bons não saírem da janela.
	reason := ""
	prev := loadJobStates()[job.ID]
	if job.AnomalyPct > 0 && prev.TotalFiles > 0 && result.TotalFilesProcessed > 0 {
		changed := float64(result.FilesNew+result.FilesChanged) * 100 / float64(result.TotalFilesProcessed)
		shrink := (1 - float64(result.TotalFilesProcessed)/float64(prev.TotalFiles)) * 100
		if changed > job.AnomalyPct {
			reason = fmt.Sprintf("%.0f%% dos arquivos mudaram desde o último backup", changed)
		} else if shrink > job.AnomalyPct {
			reason = fmt.Sprintf("%.0f%% dos arquivos sumiram desde o último backup (%d → %d)", shrink,
				prev.TotalFiles, result.TotalFilesProcessed)
		}
	}
	updateJobState(job.ID, func(st *JobState) {
		st.TotalFiles = result.TotalFilesProcessed
		st.LastSuccess = time.Now()
		if reason != "" && st.BlockedSince == nil {
			now := time.Now()
			st.BlockedSince, st.BlockReason = &now, reason
		}
	})
	state := loadJobStates()[job.ID]
	if state.BlockedSince != nil {
		summary["retention_blocked"] = state.BlockReason
		msg := "Retenção suspensa: " + state.BlockReason + ". Nada é apagado até você confirmar na interface (Conjuntos → Liberar retenção)."
		run.Warn(msg)
		if reason != "" {
			a.reporter.send("/notify", map[string]any{"level": "error", "title": "Anomalia no backup: " + job.Name,
				"body": msg, "run_id": run.ID}, false)
		}
	} else if err := r.Forget(ctx, run, tags, job.Retention); err != nil {
		run.Warn("retenção: " + err.Error())
	}

	if err := a.refreshSnapshots(ctx, run, r); err != nil {
		run.Warn("lista de snapshots: " + err.Error())
	}
	return nil
}

func checkSource(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("origem %s indisponível: %w", path, err)
	}
	if !info.IsDir() {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("origem %s: %w", path, err)
	}
	defer f.Close()
	if _, err := f.Readdirnames(1); errors.Is(err, io.EOF) {
		return fmt.Errorf("origem %s está vazia (montagem caiu?): backup cancelado para não gerar um snapshot vazio", path)
	}
	return nil
}

func underAny(path string, roots []string) bool {
	for _, root := range roots {
		rel, err := filepath.Rel(root, path)
		if err == nil && rel != ".." && !strings.HasPrefix(rel, "../") {
			return true
		}
	}
	return false
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// ping avisa um monitor externo (padrão Healthchecks: /fail em caso de falha).
// Ele dispara um alerta se o ping não chegar: cobre até o agente morto.
func ping(url string, ok bool) {
	if url == "" {
		return
	}
	if !ok {
		url = strings.TrimRight(url, "/") + "/fail"
	}
	client := &http.Client{Timeout: 10 * time.Second}
	if resp, err := client.Get(url); err == nil {
		resp.Body.Close()
	}
}

// ── Manutenção ────────────────────────────────────────────────────────

func (a *Agent) refreshSnapshots(ctx context.Context, run *Run, r *Restic) error {
	list, err := r.Snapshots(ctx, run)
	if err != nil {
		return err
	}
	if list == nil {
		list = []SnapshotInfo{}
	}
	a.reporter.send("/snapshots", map[string]any{"repository_id": r.Repo.ID, "snapshots": list}, false)
	return nil
}

func (a *Agent) repoTask(ctx context.Context, kind, repoID, jobID, commandID, trigger string,
	fn func(ctx context.Context, run *Run, r *Restic, summary map[string]any) error) {
	plan := a.currentPlan()
	label := kind
	if repo, err := plan.repository(repoID); err == nil {
		label = kind + " " + repo.URL
	}
	run := a.startRun(kind, label, jobID, repoID, commandID, trigger)
	summary := map[string]any{}
	r, err := a.restic(plan, repoID)
	if err == nil {
		err = fn(ctx, run, r, summary)
	}
	run.Finish(err, summary)
}

func (a *Agent) forgetJob(ctx context.Context, jobID, commandID string) {
	plan := a.currentPlan()
	job, err := plan.job(jobID)
	if err != nil {
		a.startRun("forget", "forget", "", "", commandID, "manual").Finish(err, nil)
		return
	}
	a.repoTask(ctx, "forget", job.RepositoryID, job.ID, commandID, "manual",
		func(ctx context.Context, run *Run, r *Restic, summary map[string]any) error {
			if st := loadJobStates()[job.ID]; st.BlockedSince != nil {
				return errors.New("retenção suspensa por anomalia: libere na interface antes")
			}
			if err := r.Forget(ctx, run, []string{"bergakup", "dataset:" + r.Dataset.Slug}, job.Retention); err != nil {
				return err
			}
			return a.refreshSnapshots(ctx, run, r)
		})
}

func (a *Agent) pruneRepo(ctx context.Context, repoID, jobID, commandID, trigger string) {
	a.repoTask(ctx, "prune", repoID, jobID, commandID, trigger,
		func(ctx context.Context, run *Run, r *Restic, summary map[string]any) error {
			if r.Storage.LockDays > 0 {
				run.Log("info", fmt.Sprintf("destino com Object Lock de %d dias: o espaço só é liberado no B2 quando o lock vence", r.Storage.LockDays))
			}
			return r.Prune(ctx, run)
		})
}

func (a *Agent) checkRepo(ctx context.Context, repoID, jobID, subset, commandID, trigger string) {
	a.repoTask(ctx, "check", repoID, jobID, commandID, trigger,
		func(ctx context.Context, run *Run, r *Restic, summary map[string]any) error {
			summary["subset"] = subset
			return r.Check(ctx, run, subset)
		})
}
