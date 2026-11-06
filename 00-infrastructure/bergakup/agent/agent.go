package main

// O laço do agente:
//   - sinal de vida a cada 30 s, com o que ele descobriu no Docker;
//   - se a API tem uma revisão nova do plano, baixa, valida, grava e aplica;
//   - escuta comandos da web (long poll);
//   - o agendador (cron) dispara backups, prune e check pelo plano local.
//
// Trabalho pesado (backup, prune, check, restore, import) roda numa fila só,
// um por vez. Consultas (snapshots, ls, teste) rodam em paralelo.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/robfig/cron/v3"
)

type task struct {
	key   string
	label string
	fn    func(ctx context.Context)
}

type Agent struct {
	id       *Identity
	opener   *Opener
	client   *Client
	reporter *Reporter
	hostname string

	mu       sync.RWMutex
	plan     *Plan
	applyErr string
	rejected int
	cron     *cron.Cron

	tasks  chan task
	qmu    sync.Mutex
	queued map[string]bool
	light  chan struct{}

	dmu         sync.Mutex
	discovery   map[string]any
	discoveryAt time.Time
}

func newAgent(id *Identity) (*Agent, error) {
	opener, err := newOpener(id)
	if err != nil {
		return nil, err
	}
	hostname, _ := os.Hostname()
	client := newClient(id.APIURL, id.Token)
	a := &Agent{
		id: id, opener: opener, client: client, reporter: newReporter(client), hostname: hostname,
		tasks: make(chan task, 200), queued: map[string]bool{}, light: make(chan struct{}, 4),
	}
	var saved Plan
	if err := readJSON(planPath(), &saved); err == nil {
		if err := a.applyPlan(&saved, false); err != nil {
			log.Printf("plano local inválido: %v", err)
		} else {
			log.Printf("plano local carregado: revisão %d", saved.Revision)
		}
	}
	return a, nil
}

func (a *Agent) currentPlan() *Plan {
	a.mu.RLock()
	defer a.mu.RUnlock()
	if a.plan == nil {
		return &Plan{}
	}
	return a.plan
}

// applyPlan troca o plano e refaz o agendador. Um plano inválido não substitui
// o anterior.
func (a *Agent) applyPlan(p *Plan, save bool) error {
	if err := p.validate(); err != nil {
		return err
	}
	if save {
		if err := writeJSONAtomic(planPath(), p, 0o600); err != nil {
			return fmt.Errorf("não consegui gravar o plano: %w", err)
		}
	}
	c := cron.New(cron.WithLocation(p.location()), cron.WithParser(cronParser))
	for _, j := range p.Jobs {
		if !j.Enabled {
			continue
		}
		job := j
		if _, err := c.AddFunc(job.Schedule, func() {
			a.enqueue("backup:"+job.ID, "backup "+job.Name, func(ctx context.Context) {
				a.backupJob(ctx, job.ID, "schedule", "")
			})
		}); err != nil {
			return err
		}
		if job.PruneSchedule != "" {
			if _, err := c.AddFunc(job.PruneSchedule, func() {
				a.enqueue("prune:"+job.RepositoryID, "prune "+job.Name, func(ctx context.Context) {
					a.pruneRepo(ctx, job.RepositoryID, job.ID, "", "schedule")
				})
			}); err != nil {
				return err
			}
		}
		if job.CheckSchedule != "" {
			if _, err := c.AddFunc(job.CheckSchedule, func() {
				a.enqueue("check:"+job.RepositoryID, "check "+job.Name, func(ctx context.Context) {
					a.checkRepo(ctx, job.RepositoryID, job.ID, job.CheckSubset, "", "schedule")
				})
			}); err != nil {
				return err
			}
		}
	}
	a.mu.Lock()
	old := a.cron
	a.plan = p
	a.cron = c
	a.applyErr = ""
	a.mu.Unlock()
	if old != nil {
		old.Stop() // não espera: uma tarefa em andamento termina na fila
	}
	c.Start()
	return nil
}

func (a *Agent) enqueue(key, label string, fn func(ctx context.Context)) bool {
	a.qmu.Lock()
	if a.queued[key] {
		a.qmu.Unlock()
		log.Printf("%s já está na fila, ignorando", label)
		return false
	}
	a.queued[key] = true
	a.qmu.Unlock()
	select {
	case a.tasks <- task{key: key, label: label, fn: fn}:
		return true
	default:
		a.qmu.Lock()
		delete(a.queued, key)
		a.qmu.Unlock()
		log.Printf("fila cheia, descartando %s", label)
		return false
	}
}

func (a *Agent) worker(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case t := <-a.tasks:
			log.Printf("iniciando %s", t.label)
			func() {
				defer func() {
					if r := recover(); r != nil {
						log.Printf("pânico em %s: %v", t.label, r)
					}
				}()
				t.fn(ctx)
			}()
			a.qmu.Lock()
			delete(a.queued, t.key)
			a.qmu.Unlock()
		}
	}
}

// ── Sinal de vida e plano ─────────────────────────────────────────────

func (a *Agent) discoveryInfo(ctx context.Context, force bool) map[string]any {
	a.dmu.Lock()
	defer a.dmu.Unlock()
	if !force && a.discovery != nil && time.Since(a.discoveryAt) < 5*time.Minute {
		return a.discovery
	}
	info := map[string]any{"hostname": a.hostname, "updated_at": time.Now()}
	if out, err := exec.CommandContext(ctx, resticBin, "version").Output(); err == nil {
		info["restic_version"] = strings.TrimSpace(string(out))
	} else {
		info["restic_version"] = ""
		info["restic_error"] = err.Error()
	}
	containers, err := listContainers(ctx)
	if err != nil {
		info["docker_error"] = err.Error()
	} else {
		type item struct {
			Name    string `json:"name"`
			Service string `json:"service"`
			Image   string `json:"image"`
			Running bool   `json:"running"`
			Health  string `json:"health,omitempty"`
			Dump    string `json:"dump,omitempty"`
		}
		stacks := map[string][]item{}
		for _, c := range containers {
			stack := c.Project
			if stack == "" {
				stack = "(sem compose)"
			}
			stacks[stack] = append(stacks[stack], item{c.Name, c.Service, c.Image, c.Running, c.Health, c.Labels[labelDump]})
		}
		names := make([]string, 0, len(stacks))
		for s := range stacks {
			names = append(names, s)
		}
		sort.Strings(names)
		var list []map[string]any
		for _, s := range names {
			list = append(list, map[string]any{"name": s, "containers": stacks[s]})
		}
		targets, warnings := discoverDumps(containers)
		info["stacks"] = list
		info["dumps"] = targets
		info["warnings"] = warnings
	}
	plan := a.currentPlan()
	info["stacks_order"] = readStacksOrder(plan.Host.StacksFile)
	states := loadJobStates()
	blocked := map[string]string{}
	for id, st := range states {
		if st.BlockedSince != nil {
			blocked[id] = st.BlockReason
		}
	}
	info["retention_blocked"] = blocked
	a.discovery, a.discoveryAt = info, time.Now()
	return info
}

func (a *Agent) heartbeat(ctx context.Context, force bool) {
	plan := a.currentPlan()
	a.mu.RLock()
	applyErr := a.applyErr
	a.mu.RUnlock()
	body := map[string]any{"version": version, "applied_revision": plan.Revision,
		"info": a.discoveryInfo(ctx, force)}
	if applyErr != "" {
		body["apply_error"] = applyErr
	}
	var resp struct {
		Revision int `json:"revision"`
	}
	if err := a.client.do(ctx, "POST", "/heartbeat", body, &resp); err != nil {
		log.Printf("API indisponível (sigo com a revisão %d): %v", plan.Revision, err)
		return
	}
	a.mu.RLock()
	rejected := a.rejected
	a.mu.RUnlock()
	if resp.Revision <= plan.Revision || resp.Revision == rejected {
		return
	}
	var next Plan
	if err := a.client.do(ctx, "GET", "/plan", nil, &next); err != nil {
		log.Printf("não consegui baixar o plano %d: %v", resp.Revision, err)
		return
	}
	if err := a.applyPlan(&next, true); err != nil {
		log.Printf("plano %d recusado: %v", next.Revision, err)
		a.mu.Lock()
		a.applyErr, a.rejected = err.Error(), next.Revision
		a.mu.Unlock()
		return
	}
	log.Printf("plano aplicado: revisão %d (%d tarefas)", next.Revision, len(next.Jobs))
	// Confirma já, sem esperar o próximo ciclo.
	_ = a.client.do(ctx, "POST", "/heartbeat", map[string]any{"version": version,
		"applied_revision": next.Revision, "info": map[string]any{}}, nil)
}

func (a *Agent) heartbeatLoop(ctx context.Context) {
	for {
		a.heartbeat(ctx, false)
		select {
		case <-ctx.Done():
			return
		case <-time.After(30 * time.Second):
		}
	}
}

// ── Comandos da web ───────────────────────────────────────────────────

type Command struct {
	ID     string         `json:"id"`
	Kind   string         `json:"kind"`
	Params map[string]any `json:"params"`
}

func (c *Command) str(key string) string {
	if v, ok := c.Params[key].(string); ok {
		return v
	}
	return ""
}

func (c *Command) strs(key string) []string {
	raw, _ := c.Params[key].([]any)
	var out []string
	for _, v := range raw {
		if s, ok := v.(string); ok && s != "" {
			out = append(out, s)
		}
	}
	return out
}

func (c *Command) boolean(key string) bool {
	v, _ := c.Params[key].(bool)
	return v
}

func (a *Agent) commandLoop(ctx context.Context) {
	for ctx.Err() == nil {
		var commands []Command
		if err := a.client.do(ctx, "GET", "/commands?wait=25", nil, &commands); err != nil {
			select {
			case <-ctx.Done():
				return
			case <-time.After(10 * time.Second):
			}
			continue
		}
		for _, cmd := range commands {
			a.dispatch(ctx, cmd)
		}
	}
}

func (a *Agent) dispatch(ctx context.Context, cmd Command) {
	switch cmd.Kind {
	case "snapshots", "ls", "test", "discover":
		go func() {
			a.light <- struct{}{}
			defer func() { <-a.light }()
			a.lightCommand(ctx, cmd)
		}()
		return
	}
	queued := a.enqueue("cmd:"+cmd.ID, cmd.Kind, func(ctx context.Context) { a.heavyCommand(ctx, cmd) })
	if !queued {
		a.startRun(cmd.Kind, cmd.Kind, "", cmd.str("repository_id"), cmd.ID, "manual").
			Finish(errors.New("fila do agente cheia; tente de novo"), nil)
	}
}

func (a *Agent) lightCommand(ctx context.Context, cmd Command) {
	repoID := cmd.str("repository_id")
	switch cmd.Kind {
	case "discover":
		run := a.startRun("discover", "descoberta", "", "", cmd.ID, "manual")
		info := a.discoveryInfo(ctx, true)
		a.heartbeat(ctx, false)
		run.Finish(nil, map[string]any{"stacks": len(asSlice(info["stacks"]))})
	case "snapshots":
		a.repoTask(ctx, "snapshots", repoID, "", cmd.ID, "manual",
			func(ctx context.Context, run *Run, r *Restic, summary map[string]any) error {
				return a.refreshSnapshots(ctx, run, r)
			})
	case "test":
		a.repoTask(ctx, "test", repoID, "", cmd.ID, "manual",
			func(ctx context.Context, run *Run, r *Restic, summary map[string]any) error {
				err := r.Test(ctx, run)
				summary["ok"] = err == nil
				return err
			})
	case "ls":
		a.repoTask(ctx, "ls", repoID, "", cmd.ID, "manual",
			func(ctx context.Context, run *Run, r *Restic, summary map[string]any) error {
				dir := cmd.str("path")
				if dir == "" {
					dir = "/"
				}
				entries, truncated, err := r.Ls(ctx, nil, cmd.str("snapshot_id"), dir, 3000)
				if entries == nil {
					entries = []LsEntry{}
				}
				summary["path"], summary["entries"], summary["truncated"] = dir, entries, truncated
				return err
			})
	}
}

func asSlice(v any) []map[string]any {
	s, _ := v.([]map[string]any)
	return s
}

func (a *Agent) heavyCommand(ctx context.Context, cmd Command) {
	repoID := cmd.str("repository_id")
	switch cmd.Kind {
	case "backup":
		a.backupJob(ctx, cmd.str("job_id"), "manual", cmd.ID)
	case "forget":
		a.forgetJob(ctx, cmd.str("job_id"), cmd.ID)
	case "prune":
		a.pruneRepo(ctx, repoID, "", cmd.ID, "manual")
	case "check":
		subset := cmd.str("subset")
		a.checkRepo(ctx, repoID, "", subset, cmd.ID, "manual")
	case "unlock":
		jobID := cmd.str("job_id")
		run := a.startRun("unlock", "liberar retenção", jobID, repoID, cmd.ID, "manual")
		if jobID != "" {
			updateJobState(jobID, func(st *JobState) { st.BlockedSince, st.BlockReason = nil, "" })
			run.Log("info", "retenção liberada: o próximo backup volta a aplicar a retenção")
			a.discoveryInfo(ctx, true)
		}
		var err error
		if repoID != "" {
			var r *Restic
			if r, err = a.restic(a.currentPlan(), repoID); err == nil {
				err = r.Unlock(ctx, run)
			}
		}
		run.Finish(err, nil)
	case "init":
		a.repoTask(ctx, "init", repoID, "", cmd.ID, "manual",
			func(ctx context.Context, run *Run, r *Restic, summary map[string]any) error {
				recovery, err := a.opener.Open(cmd.str("recovery"), "senha de recuperação")
				if err != nil {
					return err
				}
				if r.Test(ctx, nil) == nil {
					run.Log("info", "o repositório já existe e a senha confere: só acrescento a chave de recuperação")
				} else if err := r.Init(ctx, run); err != nil {
					return err
				}
				if err := r.KeyAdd(ctx, run, recovery); err != nil {
					return fmt.Errorf("repositório criado, mas a chave de recuperação falhou: %w", err)
				}
				summary["recovery_key_added"] = true
				return a.refreshSnapshots(ctx, run, r)
			})
	case "restore":
		a.repoTask(ctx, "restore", repoID, "", cmd.ID, "manual",
			func(ctx context.Context, run *Run, r *Restic, summary map[string]any) error {
				return a.restore(ctx, run, r, cmd.str("snapshot_id"), cmd.str("target"), cmd.strs("includes"),
					cmd.boolean("stop_stacks"), summary)
			})
	case "import_dumps":
		plan := a.currentPlan()
		run := a.startRun("import_dumps", "importar dumps", "", "", cmd.ID, "manual")
		err := importDumps(ctx, run.Log, plan.Host.DumpsDir, cmd.strs("stacks"))
		run.Finish(err, map[string]any{"stacks": cmd.strs("stacks")})
	default:
		a.startRun(cmd.Kind, cmd.Kind, "", repoID, cmd.ID, "manual").
			Finish(fmt.Errorf("comando desconhecido: %s", cmd.Kind), nil)
	}
}

// restore devolve arquivos de um snapshot. Sem destino, volta para o lugar
// original. Com stop_stacks, para antes as stacks que usam esses caminhos.
func (a *Agent) restore(ctx context.Context, run *Run, r *Restic, snapshot, target string, includes []string,
	stop bool, summary map[string]any) error {
	if snapshot == "" {
		return errors.New("snapshot não informado")
	}
	inPlace := target == "" || target == "/"
	if inPlace {
		target = "/"
		if len(includes) == 0 {
			return errors.New("restauração no lugar original precisa de pastas escolhidas (por segurança, nunca o snapshot inteiro)")
		}
	}
	summary["target"], summary["includes"], summary["snapshot"] = target, includes, snapshot
	quiesce := newQuiesce(readStacksOrder(a.currentPlan().Host.StacksFile))
	if stop && inPlace {
		containers, err := listContainers(ctx)
		if err != nil {
			return err
		}
		modes := map[string]string{}
		for _, c := range containers {
			for _, m := range c.Mounts {
				for _, inc := range includes {
					if underAny(m.Source, []string{inc}) || underAny(inc, []string{m.Source}) {
						if c.Project != "" {
							modes[c.Project] = "stop"
						}
					}
				}
			}
		}
		if len(modes) > 0 {
			stacks := make([]string, 0, len(modes))
			for s := range modes {
				stacks = append(stacks, s)
			}
			sort.Strings(stacks)
			summary["stopped_stacks"] = stacks
			if err := quiesce.Apply(ctx, run, modes); err != nil {
				if rerr := quiesce.Resume(run); rerr != nil {
					run.Warn(rerr.Error())
				}
				return err
			}
		}
	}
	err := r.Restore(ctx, run, snapshot, target, includes)
	if !quiesce.empty() {
		if rerr := quiesce.Resume(run); rerr != nil {
			run.Warn(rerr.Error())
		}
	}
	return err
}

// ── Execução ──────────────────────────────────────────────────────────

func (a *Agent) Run(ctx context.Context) {
	go a.reporter.loop(ctx)
	go a.worker(ctx)
	go a.commandLoop(ctx)
	log.Printf("bergakup-agent %s no ar (agente %s, API %s)", version, a.id.Name, a.id.APIURL)
	a.heartbeatLoop(ctx)
	a.mu.RLock()
	c := a.cron
	a.mu.RUnlock()
	if c != nil {
		<-c.Stop().Done()
	}
}

func prettyJSON(v any) string {
	data, _ := json.MarshalIndent(v, "", "  ")
	return string(data)
}
