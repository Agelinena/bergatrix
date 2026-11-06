package main

// Docker pelo CLI (docker ps/inspect/stop/start/pause/exec). O agente roda
// como root no host e não depende de nenhum container estar no ar.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
)

type Container struct {
	ID      string
	Name    string
	Image   string
	Project string
	Service string
	Running bool
	Paused  bool
	Health  string
	Labels  map[string]string
	Mounts  []Mount
}

type Mount struct {
	Source      string `json:"Source"`
	Destination string `json:"Destination"`
}

func docker(ctx context.Context, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "docker", args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return out, fmt.Errorf("docker %s: %v: %s", args[0], err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

func listContainers(ctx context.Context) ([]Container, error) {
	out, err := docker(ctx, "ps", "-aq", "--no-trunc")
	if err != nil {
		return nil, err
	}
	ids := strings.Fields(string(out))
	if len(ids) == 0 {
		return nil, nil
	}
	out, err = docker(ctx, append([]string{"inspect"}, ids...)...)
	if err != nil {
		return nil, err
	}
	var raw []struct {
		ID     string `json:"Id"`
		Name   string `json:"Name"`
		Config struct {
			Image  string            `json:"Image"`
			Labels map[string]string `json:"Labels"`
		} `json:"Config"`
		State struct {
			Running bool `json:"Running"`
			Paused  bool `json:"Paused"`
			Health  *struct {
				Status string `json:"Status"`
			} `json:"Health"`
		} `json:"State"`
		Mounts []Mount `json:"Mounts"`
	}
	if err := json.Unmarshal(out, &raw); err != nil {
		return nil, fmt.Errorf("docker inspect: %w", err)
	}
	containers := make([]Container, 0, len(raw))
	for _, r := range raw {
		c := Container{
			ID: r.ID, Name: strings.TrimPrefix(r.Name, "/"), Image: r.Config.Image,
			Labels: r.Config.Labels, Mounts: r.Mounts, Running: r.State.Running, Paused: r.State.Paused,
		}
		if c.Labels == nil {
			c.Labels = map[string]string{}
		}
		c.Project = c.Labels["com.docker.compose.project"]
		c.Service = c.Labels["com.docker.compose.service"]
		if r.State.Health != nil {
			c.Health = r.State.Health.Status
		}
		containers = append(containers, c)
	}
	return containers, nil
}

// hostPath traduz um caminho de dentro do container para o host, pelos mounts.
func (c *Container) hostPath(inside string) (string, bool) {
	best := -1
	var result string
	for _, m := range c.Mounts {
		dest := strings.TrimRight(m.Destination, "/")
		if inside == dest || strings.HasPrefix(inside, dest+"/") {
			if len(dest) > best {
				best = len(dest)
				result = m.Source + strings.TrimPrefix(inside, dest)
			}
		}
	}
	return result, best >= 0
}

// readStacksOrder lê o stacks.txt: uma pasta por linha; o nome da stack (o
// projeto do compose) é o nome da pasta.
func readStacksOrder(path string) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var order []string
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(strings.TrimRight(line, "/"), "/")
		order = append(order, parts[len(parts)-1])
	}
	return order
}

// Quiesce guarda o que foi parado ou pausado, para devolver exatamente ao
// estado anterior: só sobe de novo o que estava rodando.
type Quiesce struct {
	order   []string
	stopped map[string][]string // stack -> ids
	paused  map[string][]string
}

func newQuiesce(order []string) *Quiesce {
	return &Quiesce{order: order, stopped: map[string][]string{}, paused: map[string][]string{}}
}

func (q *Quiesce) empty() bool { return len(q.stopped) == 0 && len(q.paused) == 0 }

// orderedStacks devolve as stacks na ordem do stacks.txt; as que não estão
// na lista vão no fim, em ordem alfabética.
func orderedStacks(order []string, stacks map[string]bool) []string {
	var result []string
	seen := map[string]bool{}
	for _, s := range order {
		if stacks[s] && !seen[s] {
			result = append(result, s)
			seen[s] = true
		}
	}
	var rest []string
	for s := range stacks {
		if !seen[s] {
			rest = append(rest, s)
		}
	}
	sort.Strings(rest)
	return append(result, rest...)
}

// Apply para (ou pausa) as stacks pedidas, na ordem inversa de subida.
func (q *Quiesce) Apply(ctx context.Context, run *Run, modes map[string]string) error {
	containers, err := listContainers(ctx)
	if err != nil {
		return err
	}
	byStack := map[string][]Container{}
	stacks := map[string]bool{}
	for _, c := range containers {
		if c.Project != "" && modes[c.Project] != "" {
			byStack[c.Project] = append(byStack[c.Project], c)
			stacks[c.Project] = true
		}
	}
	list := orderedStacks(q.order, stacks)
	for i := len(list) - 1; i >= 0; i-- {
		stack := list[i]
		var ids, names []string
		for _, c := range byStack[stack] {
			if c.Running && !c.Paused {
				ids = append(ids, c.ID)
				names = append(names, c.Name)
			}
		}
		if len(ids) == 0 {
			continue
		}
		switch modes[stack] {
		case "stop":
			run.Log("info", fmt.Sprintf("parando %s: %s", stack, strings.Join(names, ", ")))
			if _, err := docker(ctx, append([]string{"stop", "-t", "60"}, ids...)...); err != nil {
				return err
			}
			q.stopped[stack] = ids
		case "pause":
			run.Log("info", fmt.Sprintf("pausando %s: %s", stack, strings.Join(names, ", ")))
			if _, err := docker(ctx, append([]string{"pause"}, ids...)...); err != nil {
				return err
			}
			q.paused[stack] = ids
		}
	}
	return nil
}

// Resume devolve tudo, na ordem de subida. Usa um contexto próprio: tem que
// rodar mesmo se o agente estiver sendo desligado.
func (q *Quiesce) Resume(run *Run) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	stacks := map[string]bool{}
	for s := range q.stopped {
		stacks[s] = true
	}
	for s := range q.paused {
		stacks[s] = true
	}
	var failures []string
	for _, stack := range orderedStacks(q.order, stacks) {
		if ids := q.paused[stack]; len(ids) > 0 {
			run.Log("info", "retomando "+stack)
			if _, err := docker(ctx, append([]string{"unpause"}, ids...)...); err != nil {
				failures = append(failures, err.Error())
			}
		}
		if ids := q.stopped[stack]; len(ids) > 0 {
			run.Log("info", "subindo "+stack)
			if _, err := docker(ctx, append([]string{"start"}, ids...)...); err != nil {
				failures = append(failures, err.Error())
			}
		}
	}
	q.stopped, q.paused = map[string][]string{}, map[string][]string{}
	if len(failures) > 0 {
		return fmt.Errorf("não consegui subir tudo de volta: %s", strings.Join(failures, "; "))
	}
	return nil
}
