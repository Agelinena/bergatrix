package main

// O plano: a configuração inteira deste agente, como a API monta em
// app/bergakup/plan.py. Os campos de segredo chegam cifrados (seal.go).

import (
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/robfig/cron/v3"
)

type Plan struct {
	Revision      int               `json:"revision"`
	Host          HostCfg           `json:"host"`
	SMTP          *SMTPCfg          `json:"smtp"`
	Storages      []Storage         `json:"storages"`
	Datasets      []Dataset         `json:"datasets"`
	Repositories  []Repository      `json:"repositories"`
	Jobs          []Job             `json:"jobs"`
	StackPolicies map[string]string `json:"stack_policies"`
}

type HostCfg struct {
	Timezone   string `json:"timezone"`
	RepoRoot   string `json:"repo_root"`
	StacksFile string `json:"stacks_file"`
	DumpsDir   string `json:"dumps_dir"`
}

type SMTPCfg struct {
	Host     string   `json:"host"`
	Port     int      `json:"port"`
	Username string   `json:"username"`
	Sender   string   `json:"sender"`
	To       []string `json:"to"`
	Security string   `json:"security"`
	Password string   `json:"password"` // cifrado
}

type Storage struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Kind     string `json:"kind"` // b2 | local | rest | sftp
	Endpoint string `json:"endpoint"`
	Region   string `json:"region"`
	Bucket   string `json:"bucket"`
	Path     string `json:"path"`
	Username string `json:"username"`
	Secret   string `json:"secret"` // cifrado
	LockDays int    `json:"lock_days"`
}

type Dataset struct {
	ID          string   `json:"id"`
	Slug        string   `json:"slug"`
	Name        string   `json:"name"`
	Kind        string   `json:"kind"`
	Paths       []string `json:"paths"`
	Excludes    []string `json:"excludes"`
	Consistency string   `json:"consistency"` // none | policies | cold
}

type Repository struct {
	ID        string `json:"id"`
	DatasetID string `json:"dataset_id"`
	StorageID string `json:"storage_id"`
	URL       string `json:"url"`
	Password  string `json:"password"` // cifrado
}

type Retention struct {
	Last    int `json:"last"`
	Daily   int `json:"daily"`
	Weekly  int `json:"weekly"`
	Monthly int `json:"monthly"`
}

type Job struct {
	ID            string    `json:"id"`
	Name          string    `json:"name"`
	RepositoryID  string    `json:"repository_id"`
	Enabled       bool      `json:"enabled"`
	Schedule      string    `json:"schedule"`
	Retention     Retention `json:"retention"`
	PruneSchedule string    `json:"prune_schedule"`
	CheckSchedule string    `json:"check_schedule"`
	CheckSubset   string    `json:"check_subset"`
	AnomalyPct    float64   `json:"anomaly_pct"`
	PingURL       string    `json:"ping_url"`
}

func planPath() string { return filepath.Join(stateDir, "plan.json") }

func (p *Plan) location() *time.Location {
	if p.Host.Timezone != "" {
		if loc, err := time.LoadLocation(p.Host.Timezone); err == nil {
			return loc
		}
	}
	return time.Local
}

func (p *Plan) repository(id string) (*Repository, error) {
	for i := range p.Repositories {
		if p.Repositories[i].ID == id {
			return &p.Repositories[i], nil
		}
	}
	return nil, fmt.Errorf("repositório %s não existe no plano (revisão %d)", id, p.Revision)
}

func (p *Plan) storage(id string) (*Storage, error) {
	for i := range p.Storages {
		if p.Storages[i].ID == id {
			return &p.Storages[i], nil
		}
	}
	return nil, fmt.Errorf("destino %s não existe no plano", id)
}

func (p *Plan) dataset(id string) (*Dataset, error) {
	for i := range p.Datasets {
		if p.Datasets[i].ID == id {
			return &p.Datasets[i], nil
		}
	}
	return nil, fmt.Errorf("conjunto %s não existe no plano", id)
}

func (p *Plan) job(id string) (*Job, error) {
	for i := range p.Jobs {
		if p.Jobs[i].ID == id {
			return &p.Jobs[i], nil
		}
	}
	return nil, fmt.Errorf("tarefa %s não existe no plano", id)
}

var cronParser = cron.NewParser(cron.Minute | cron.Hour | cron.Dom | cron.Month | cron.Dow | cron.Descriptor)

// validate recusa um plano que o agente não consegue executar. O plano
// anterior continua valendo e o erro aparece na interface.
func (p *Plan) validate() error {
	var problems []string
	for _, j := range p.Jobs {
		for name, expr := range map[string]string{"agenda": j.Schedule, "prune": j.PruneSchedule, "check": j.CheckSchedule} {
			if expr == "" {
				continue
			}
			if _, err := cronParser.Parse(expr); err != nil {
				problems = append(problems, fmt.Sprintf("tarefa %q, %s %q: %v", j.Name, name, expr, err))
			}
		}
		if _, err := p.repository(j.RepositoryID); err != nil {
			problems = append(problems, err.Error())
		}
	}
	for _, r := range p.Repositories {
		if _, err := p.dataset(r.DatasetID); err != nil {
			problems = append(problems, err.Error())
		}
		if _, err := p.storage(r.StorageID); err != nil {
			problems = append(problems, err.Error())
		}
	}
	for _, d := range p.Datasets {
		for _, path := range d.Paths {
			if !filepath.IsAbs(path) {
				problems = append(problems, fmt.Sprintf("conjunto %q: caminho não absoluto %q", d.Slug, path))
			}
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("plano recusado: %s", strings.Join(problems, "; "))
	}
	return nil
}
