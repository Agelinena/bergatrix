package main

// Arquivos do agente no host:
//   /etc/bergakup/agent.json        identidade: API, token e o par de chaves (0600)
//   /var/lib/bergakup/plan.json     última revisão do plano aplicada
//   /var/lib/bergakup/jobstate.json último resultado de cada tarefa (detecção de anomalia)
//   /var/lib/bergakup/outbox.json   relatórios ainda não entregues à API
//   /var/cache/bergakup/restic      cache do restic (recriável)

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

var (
	etcDir   = envOr("BERGAKUP_ETC", "/etc/bergakup")
	stateDir = envOr("BERGAKUP_STATE", "/var/lib/bergakup")
	cacheDir = envOr("BERGAKUP_CACHE", "/var/cache/bergakup")
)

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

type Identity struct {
	APIURL     string `json:"api_url"`
	AgentID    string `json:"agent_id"`
	Token      string `json:"token"`
	Name       string `json:"name"`
	PublicKey  string `json:"public_key"`
	PrivateKey string `json:"private_key"`
}

func identityPath() string { return filepath.Join(etcDir, "agent.json") }

func loadIdentity() (*Identity, error) {
	var id Identity
	if err := readJSON(identityPath(), &id); err != nil {
		return nil, fmt.Errorf("agente não registrado (%s): rode 'bergakup-agent enroll' antes: %w", identityPath(), err)
	}
	return &id, nil
}

func readJSON(path string, v any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

// writeJSONAtomic grava num arquivo temporário e renomeia: uma queda no meio
// nunca deixa o arquivo pela metade.
func writeJSONAtomic(path string, v any, perm os.FileMode) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, perm); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
