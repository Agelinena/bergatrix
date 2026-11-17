package main

// Testes do caso de 17/11/2026: o notebook voltou da suspensão com a lista do
// Nextcloud velha, mandou a conversa dele por cima da que o PC do trabalho
// tinha enviado à tarde, e um envio que caiu deixou o arquivo cortado lá.

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const remoteSession = "Claude/projects/bergatrix/s.jsonl"

// twoPCs monta A e B com a mesma conversa já sincronizada.
func twoPCs(t *testing.T) (*fakeNextcloud, *pc, *pc, string) {
	nc := newFakeNextcloud(t)
	a := newPC(t, nc, "pc-a")
	session := jsonl(map[string]string{"type": "user", "cwd": a.project})
	write(t, filepath.Join(a.folder(), "s.jsonl"), session)
	a.sync(t)
	b := newPC(t, nc, "pc-b")
	write(t, filepath.Join(b.syncDir, ".claude.json"), fmt.Sprintf(`{"projects":{%q:{}}}`, filepath.ToSlash(b.project)))
	b.sync(t)
	a.sync(t)
	if read(t, filepath.Join(b.folder(), "s.jsonl")) != session {
		t.Fatal("B não recebeu a conversa")
	}
	return nc, a, b, session
}

func serverHas(nc *fakeNextcloud, text string) bool {
	nc.mu.Lock()
	defer nc.mu.Unlock()
	for _, data := range nc.files {
		if strings.Contains(string(data), text) {
			return true
		}
	}
	return false
}

func conflictCopies(t *testing.T, dir string) []string {
	t.Helper()
	matches, _ := filepath.Glob(filepath.Join(dir, "s.conflito-*.jsonl"))
	return matches
}

// A lista do Nextcloud que A tem está velha (sem refresh) e A manda a conversa
// dele: a de B, que chegou antes, não pode sumir.
func TestStaleListNeverOverwritesOtherPC(t *testing.T) {
	nc, a, b, session := twoPCs(t)

	afternoon := session + jsonl(map[string]string{"type": "assistant", "text": "trabalho da tarde no B"})
	write(t, filepath.Join(b.folder(), "s.jsonl"), afternoon)
	b.sync(t)

	// A não olha o servidor (lista velha) e acrescenta outra coisa.
	write(t, filepath.Join(a.folder(), "s.jsonl"), session+jsonl(map[string]string{"type": "cost-state"}))
	if err := a.engine.Cycle(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	copies := conflictCopies(t, a.folder())
	if len(copies) == 1 {
		// A cópia de conflito sobe na volta seguinte.
		a.sync(t)
	}
	if !serverHas(nc, "trabalho da tarde no B") {
		t.Fatal("a conversa de B sumiu do Nextcloud")
	}
	if len(copies) != 1 || !strings.Contains(read(t, copies[0]), "trabalho da tarde no B") {
		t.Fatalf("A devia guardar a versão de B como conflito: %v", copies)
	}
}

// A lista velha, mas a de B é só continuação da de A: A recebe sem conflito.
func TestStaleListTakesContinuation(t *testing.T) {
	nc, a, b, session := twoPCs(t)
	longer := session + jsonl(map[string]string{"type": "assistant", "text": "continuação"})
	write(t, filepath.Join(b.folder(), "s.jsonl"), longer)
	b.sync(t)

	// A toca o arquivo sem mudar o conteúdo (mtime novo) e não olha o servidor.
	touched := time.Now()
	os.Chtimes(filepath.Join(a.folder(), "s.jsonl"), touched, touched)
	if err := a.engine.Cycle(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if got, _ := nc.file(remoteSession); string(got) != longer {
		t.Fatalf("Nextcloud = %q", got)
	}
	if got := read(t, filepath.Join(a.folder(), "s.jsonl")); got != longer {
		t.Fatalf("A = %q", got)
	}
	if n := len(conflictCopies(t, a.folder())); n != 0 {
		t.Fatalf("%d cópias de conflito sem motivo", n)
	}
}

// Envio que chega cortado não pode substituir o arquivo bom.
func TestTruncatedUploadKeepsServerFile(t *testing.T) {
	nc, a, _, session := twoPCs(t)
	write(t, filepath.Join(a.folder(), "s.jsonl"), session+jsonl(map[string]string{"text": strings.Repeat("x", 500)}))

	nc.mu.Lock()
	nc.truncate = 20
	nc.mu.Unlock()
	// A volta pode devolver erro (o envio falhou); o que importa é o servidor.
	_ = a.engine.Cycle(context.Background(), true)
	if got, _ := nc.file(remoteSession); string(got) != session {
		t.Fatalf("o arquivo bom foi trocado por um cortado: %q", got)
	}
	nc.mu.Lock()
	for p := range nc.files {
		if strings.HasSuffix(p, tmpSuffix) {
			t.Errorf("temporário ficou no Nextcloud: %s", p)
		}
	}
	nc.truncate = 0
	nc.mu.Unlock()
}

// Chegou de outro PC uma versão que não continua a daqui (mais curta ou
// diferente): a daqui é guardada antes de ser trocada.
func TestDownloadNeverDropsLocalWork(t *testing.T) {
	nc, _, b, session := twoPCs(t)
	afternoon := session + jsonl(map[string]string{"type": "assistant", "text": "trabalho da tarde no B"})
	write(t, filepath.Join(b.folder(), "s.jsonl"), afternoon)
	b.sync(t)

	// Outro PC (com versão antiga do app) põe lá a versão velha.
	nc.mu.Lock()
	nc.files[remoteSession] = []byte(session + jsonl(map[string]string{"type": "cost-state"}))
	nc.mu.Unlock()
	b.sync(t)

	copies := conflictCopies(t, b.folder())
	if len(copies) != 1 || read(t, copies[0]) != afternoon {
		t.Fatalf("o trabalho de B devia ficar numa cópia: %v", copies)
	}
}

// Temporário de envio de outro PC não é baixado.
func TestRemoteTempIsIgnored(t *testing.T) {
	nc, a, _, _ := twoPCs(t)
	nc.mu.Lock()
	nc.files["Claude/projects/bergatrix/s.jsonl.123"+tmpSuffix] = []byte("pela metade")
	nc.mu.Unlock()
	a.sync(t)
	matches, _ := filepath.Glob(filepath.Join(a.folder(), "*"+tmpSuffix))
	if len(matches) != 0 {
		t.Fatalf("baixou temporário: %v", matches)
	}
}
