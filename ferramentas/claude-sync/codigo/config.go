package main

// Configuração e estado ficam fora da pasta sincronizada, na pasta de dados
// do app (%APPDATA%\claude-sync no Windows). A senha de app nunca vai para
// estes arquivos: fica no cofre do sistema (secret_*.go).

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"
)

// Itens da raiz da pasta do Claude que podem ser sincronizados, além das conversas.
var allGlobalItems = []string{"CLAUDE.md", "agents", "commands", "skills", "settings.json"}
var defaultGlobalItems = []string{"CLAUDE.md", "agents", "commands", "skills"}

type Config struct {
	Server          string            `json:"server"`
	User            string            `json:"user"`
	SyncDir         string            `json:"syncDir"`
	RemoteDir       string            `json:"remoteDir"`
	GlobalItems     []string          `json:"globalItems"`
	IntervalSeconds int               `json:"intervalSeconds"`
	Links           map[string]string `json:"links"`   // projeto → caminho dele neste PC
	Aliases         map[string]string `json:"aliases"` // caminho ou nome de pasta → projeto
}

type FileState struct {
	ETag  string `json:"etag"`
	Size  int64  `json:"size"`
	MTime int64  `json:"mtime"`
}

type State struct {
	Files map[string]FileState `json:"files"`
}

type Store struct {
	Dir string
	mu  sync.Mutex
}

func appDir() (string, error) {
	if dir := os.Getenv("CLAUDE_SYNC_HOME"); dir != "" {
		return dir, os.MkdirAll(dir, 0o700)
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(base, "claude-sync")
	return dir, os.MkdirAll(dir, 0o700)
}

func defaultConfig() *Config {
	home, _ := os.UserHomeDir()
	return &Config{
		SyncDir:         filepath.Join(home, "ClaudeSync"),
		RemoteDir:       "Claude",
		GlobalItems:     append([]string(nil), defaultGlobalItems...),
		IntervalSeconds: 30,
		Links:           map[string]string{},
		Aliases:         map[string]string{},
	}
}

func (s *Store) LoadConfig() (*Config, error) {
	cfg := defaultConfig()
	data, err := os.ReadFile(filepath.Join(s.Dir, "config.json"))
	if errors.Is(err, os.ErrNotExist) {
		return cfg, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, err
	}
	if cfg.Links == nil {
		cfg.Links = map[string]string{}
	}
	if cfg.Aliases == nil {
		cfg.Aliases = map[string]string{}
	}
	if cfg.IntervalSeconds < 10 {
		cfg.IntervalSeconds = 10
	}
	if cfg.RemoteDir == "" {
		cfg.RemoteDir = "Claude"
	}
	return cfg, nil
}

func (s *Store) SaveConfig(cfg *Config) error {
	return s.writeJSON("config.json", cfg)
}

func (s *Store) LoadState() *State {
	st := &State{Files: map[string]FileState{}}
	if data, err := os.ReadFile(filepath.Join(s.Dir, "state.json")); err == nil {
		_ = json.Unmarshal(data, st)
	}
	if st.Files == nil {
		st.Files = map[string]FileState{}
	}
	return st
}

func (s *Store) SaveState(st *State) error {
	return s.writeJSON("state.json", st)
}

func (s *Store) writeJSON(name string, v any) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, err := json.MarshalIndent(v, "", " ")
	if err != nil {
		return err
	}
	return writeAtomic(filepath.Join(s.Dir, name), data, 0o600)
}

// writeAtomic grava ao lado e renomeia: quem lê nunca vê o arquivo pela metade.
func writeAtomic(path string, data []byte, perm os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + tmpSuffix
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

const tmpSuffix = ".claude-sync.tmp"
