package main

// Testes do caso de 17/11/2026: o notebook voltou da suspensão com a lista do
// Nextcloud velha, mandou a conversa dele por cima da que o PC do trabalho
// tinha enviado à tarde, um envio que caiu deixou o arquivo cortado lá, e
// depois os dois PCs ficaram trocando versões entre si.

import (
	"bytes"
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
	session := jsonl(map[string]string{"type": "user", "cwd": a.project, "timestamp": "2026-11-07T10:00:00Z"})
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

func conflictCopies(t *testing.T, dir string) []string {
	t.Helper()
	matches, _ := filepath.Glob(filepath.Join(dir, "*conflito*"))
	return matches
}

func serverSession(nc *fakeNextcloud) string {
	data, _ := nc.file(remoteSession)
	return string(data)
}

func msg(kind, text, ts string) string {
	return jsonl(map[string]string{"type": kind, "text": text, "timestamp": ts})
}

// A está com a lista do Nextcloud velha e manda a conversa dele: a de B, que
// chegou antes, não pode sumir. As duas partes são juntadas, sem cópia de conflito.
func TestStaleListNeverOverwritesOtherPC(t *testing.T) {
	nc, a, b, session := twoPCs(t)

	afternoon := session + msg("assistant", "trabalho da tarde no B", "2026-11-17T17:00:00Z")
	write(t, filepath.Join(b.folder(), "s.jsonl"), afternoon)
	b.sync(t)

	// A não olha o servidor (lista velha) e acrescenta outra coisa.
	write(t, filepath.Join(a.folder(), "s.jsonl"), session+jsonl(map[string]string{"type": "cost-state"}))
	if err := a.engine.Cycle(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(serverSession(nc), "trabalho da tarde no B") {
		t.Fatal("a conversa de B sumiu do Nextcloud")
	}
	a.sync(t) // a junção sobe
	b.sync(t)

	for name, p := range map[string]*pc{"A": a, "B": b} {
		got := read(t, filepath.Join(p.folder(), "s.jsonl"))
		if !strings.Contains(got, "trabalho da tarde no B") || !strings.Contains(got, "cost-state") {
			t.Errorf("%s não tem as duas partes: %q", name, got)
		}
		if got != serverSession(nc) {
			t.Errorf("%s diferente do Nextcloud", name)
		}
		if c := conflictCopies(t, p.folder()); len(c) != 0 {
			t.Errorf("%s: cópias de conflito sem necessidade: %v", name, c)
		}
	}
}

// A lista velha, mas a de B é só continuação da de A: A recebe sem conflito.
func TestStaleListTakesContinuation(t *testing.T) {
	_, a, b, session := twoPCs(t)
	longer := session + msg("assistant", "continuação", "2026-11-17T17:00:00Z")
	write(t, filepath.Join(b.folder(), "s.jsonl"), longer)
	b.sync(t)

	// A toca o arquivo sem mudar o conteúdo (mtime novo) e não olha o servidor.
	touched := time.Now()
	os.Chtimes(filepath.Join(a.folder(), "s.jsonl"), touched, touched)
	if err := a.engine.Cycle(context.Background(), false); err != nil {
		t.Fatal(err)
	}
	if got := read(t, filepath.Join(a.folder(), "s.jsonl")); got != longer {
		t.Fatalf("A = %q", got)
	}
}

// Os dois PCs mudaram a conversa ao mesmo tempo: em poucas voltas os dois e o
// Nextcloud ficam iguais, e depois disso ninguém manda mais nada.
func TestDivergedPCsConverge(t *testing.T) {
	nc, a, b, session := twoPCs(t)
	write(t, filepath.Join(a.folder(), "s.jsonl"), session+msg("user", "no notebook", "2026-11-17T19:38:00Z"))
	write(t, filepath.Join(b.folder(), "s.jsonl"), session+msg("assistant", "tarde no trabalho", "2026-11-17T17:00:00Z"))
	for i := 0; i < 3; i++ {
		a.sync(t)
		b.sync(t)
	}
	want := serverSession(nc)
	if !strings.Contains(want, "no notebook") || !strings.Contains(want, "tarde no trabalho") {
		t.Fatalf("Nextcloud perdeu uma das partes: %q", want)
	}
	if strings.Index(want, "tarde no trabalho") > strings.Index(want, "no notebook") {
		t.Error("a junção devia seguir a ordem de horário")
	}
	for name, p := range map[string]*pc{"A": a, "B": b} {
		if got := read(t, filepath.Join(p.folder(), "s.jsonl")); got != want {
			t.Errorf("%s não convergiu: %q", name, got)
		}
	}
	upsBefore := a.engine.Status().Counts.Up + b.engine.Status().Counts.Up
	a.sync(t)
	b.sync(t)
	if after := a.engine.Status().Counts.Up + b.engine.Status().Counts.Up; after != upsBefore {
		t.Fatalf("depois de convergir ainda mandaram %d envios", after-upsBefore)
	}
}

// Servidor que grava envio cortado (o que o HTTP/2 fez): o app percebe, o
// outro PC não baixa a conversa quebrada, e a volta seguinte conserta.
func TestTruncatedUploadIsDetectedAndHealed(t *testing.T) {
	nc, a, b, session := twoPCs(t)
	full := session + msg("assistant", strings.Repeat("x", 500), "2026-11-17T17:00:00Z")
	write(t, filepath.Join(a.folder(), "s.jsonl"), full)

	nc.mu.Lock()
	nc.truncate = len(session) + 20
	nc.mu.Unlock()
	if err := a.engine.Cycle(context.Background(), true); err == nil || !strings.Contains(err.Error(), "incompleto") {
		t.Fatalf("envio cortado não foi percebido: %v", err)
	}
	b.sync(t)
	if got := read(t, filepath.Join(b.folder(), "s.jsonl")); got != session {
		t.Fatalf("B baixou a conversa cortada: %q", got)
	}

	nc.mu.Lock()
	nc.truncate = 0
	nc.mu.Unlock()
	a.sync(t)
	if serverSession(nc) != full {
		t.Fatalf("o Nextcloud não foi consertado: %q", serverSession(nc))
	}
	b.sync(t)
	if read(t, filepath.Join(b.folder(), "s.jsonl")) != full {
		t.Fatal("B não recebeu a conversa inteira")
	}
}

// Chegou de outro PC uma versão que não continua a daqui (mais curta ou
// diferente): nada da daqui se perde.
func TestDownloadNeverDropsLocalWork(t *testing.T) {
	nc, _, b, session := twoPCs(t)
	afternoon := session + msg("assistant", "trabalho da tarde no B", "2026-11-17T17:00:00Z")
	write(t, filepath.Join(b.folder(), "s.jsonl"), afternoon)
	b.sync(t)

	// Outro PC (com versão antiga do app) põe lá a versão velha.
	nc.mu.Lock()
	nc.files[remoteSession] = []byte(session + jsonl(map[string]string{"type": "cost-state"}))
	nc.mu.Unlock()
	b.sync(t)
	b.sync(t)

	for where, got := range map[string]string{"B": read(t, filepath.Join(b.folder(), "s.jsonl")), "Nextcloud": serverSession(nc)} {
		if !strings.Contains(got, "trabalho da tarde no B") || !strings.Contains(got, "cost-state") {
			t.Errorf("%s não tem as duas partes: %q", where, got)
		}
	}
}

func TestMergeIsDeterministic(t *testing.T) {
	base := msg("user", "oi", "2026-11-07T10:00:00Z")
	x := base + msg("user", "x", "2026-11-17T10:00:00Z") + jsonl(map[string]string{"type": "cost-state", "n": "1"})
	y := base + msg("user", "y", "2026-11-17T09:00:00Z") + msg("user", "z", "2026-11-17T11:00:00Z")
	xy, o1 := mergeConversation([]byte(x), []byte(y))
	yx, o2 := mergeConversation([]byte(y), []byte(x))
	if o1 != merged || o2 != merged || !bytes.Equal(xy, yx) {
		t.Fatalf("junção depende da ordem:\n%s\n---\n%s", xy, yx)
	}
	if got, o := mergeConversation(xy, []byte(x)); o != keepMine || !bytes.Equal(got, xy) {
		t.Fatal("versão que já tem tudo devia ficar")
	}
	if !strings.HasPrefix(string(xy), base) || strings.Count(string(xy), "\n") != 5 {
		t.Fatalf("junção errada: %q", xy)
	}
}

// skills/synced e ocultos são do Claude Code de cada PC: não sobem nem descem.
func TestManagedSkillsStayLocal(t *testing.T) {
	nc, a, b, _ := twoPCs(t)
	write(t, filepath.Join(a.syncDir, "skills", "minha", "SKILL.md"), "minha skill")
	write(t, filepath.Join(a.syncDir, "skills", "synced", "x", "manifest.json"), "{}")
	write(t, filepath.Join(a.syncDir, "skills", ".trash", "velha", "SKILL.md"), "lixo")
	write(t, filepath.Join(a.syncDir, "skills", "minha", ".last-complete-round"), "1")
	nc.mu.Lock()
	nc.files["Claude/global/skills/synced/y/manifest.json"] = []byte("{}")
	nc.mu.Unlock()
	a.sync(t)
	b.sync(t)

	if _, ok := nc.file("Claude/global/skills/minha/SKILL.md"); !ok {
		t.Error("a skill do usuário não subiu")
	}
	nc.mu.Lock()
	for p := range nc.files {
		if strings.Contains(p, "/.trash/") || strings.Contains(p, ".last-complete-round") || strings.Contains(p, "synced/x/") {
			t.Errorf("subiu o que é do Claude Code: %s", p)
		}
	}
	nc.mu.Unlock()
	if _, err := os.Stat(filepath.Join(b.syncDir, "skills", "synced")); err == nil {
		t.Error("B baixou skills/synced")
	}
	if read(t, filepath.Join(b.syncDir, "skills", "minha", "SKILL.md")) != "minha skill" {
		t.Error("B não recebeu a skill do usuário")
	}
}

// Temporário de envio da 0.2.2 que ficou no Nextcloud não é baixado.
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
