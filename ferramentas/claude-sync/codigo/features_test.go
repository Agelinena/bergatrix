package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"image/png"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTagHookKeepsTheRestOfSettings(t *testing.T) {
	original := []byte(`{"model":"opus","hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo outro"}]}],"Stop":[{"hooks":[{"type":"command","command":"x"}]}]}}`)
	exe := `C:\Users\Lucas\OneDrive - Assist Cloud\it's\claude-sync.exe`
	with, err := withTagHook(original, tagHook(exe))
	if err != nil {
		t.Fatal(err)
	}
	again, _ := withTagHook(with, tagHook(exe))
	if !bytes.Equal(with, again) {
		t.Fatal("aplicar duas vezes mudou o arquivo")
	}
	var parsed map[string]any
	json.Unmarshal(with, &parsed)
	if parsed["model"] != "opus" {
		t.Fatal("perdeu outra configuração")
	}
	groups := parsed["hooks"].(map[string]any)["UserPromptSubmit"].([]any)
	if len(groups) != 2 {
		t.Fatalf("grupos = %d (o hook do usuário + a etiqueta)", len(groups))
	}
	cmd := groups[1].(map[string]any)["hooks"].([]any)[0].(map[string]any)["command"].(string)
	if !strings.HasSuffix(cmd, " tag") || !strings.Contains(cmd, "claude-sync") {
		t.Fatalf("comando = %s", cmd)
	}
	if strings.HasPrefix(cmd, "'") && !strings.Contains(cmd, `it'\''s`) {
		t.Fatalf("aspas do bash erradas: %s", cmd)
	}

	stripped, _ := withTagHook(with, nil)
	if strings.Contains(string(stripped), "claude-sync") || !strings.Contains(string(stripped), "echo outro") {
		t.Fatalf("tirar a etiqueta = %s", stripped)
	}
	unchanged, _ := withTagHook(original, nil)
	if !bytes.Equal(unchanged, original) {
		t.Fatal("sem etiqueta para tirar, o arquivo devia ficar igual byte a byte")
	}
	if _, err := withTagHook([]byte("{quebrado"), nil); err == nil {
		t.Fatal("aceitou settings.json inválido")
	}
}

func TestTagLine(t *testing.T) {
	host := hostname()
	if got := tagLine(&Config{}); !strings.HasPrefix(got, "[PC: "+host+" · ") {
		t.Fatal(got)
	}
	if got := tagLine(&Config{PCName: "notebook-casa"}); !strings.Contains(got, "notebook-casa") || !strings.Contains(got, host) {
		t.Fatal(got)
	}
}

// O hook de um PC nunca chega a outro, mesmo com o settings.json sincronizado.
func TestSettingsSyncCarriesNoTagHook(t *testing.T) {
	nc := newFakeNextcloud(t)
	a := newPC(t, nc, "pc-a")
	b := newPC(t, nc, "pc-b")
	for name, p := range map[string]*pc{`C:\a\claude-sync.exe`: a, "/home/b/claude-sync": b} {
		hook := tagHook(name)
		p.engine.cfg.GlobalItems = append(p.engine.cfg.GlobalItems, settingsFile)
		p.engine.transformUp = func(rp string, d []byte) []byte { out, _ := withTagHook(d, nil); return out }
		p.engine.transformDown = func(rp string, d []byte) []byte { out, _ := withTagHook(d, hook); return out }
	}
	settingsA, _ := withTagHook([]byte(`{"model":"opus"}`), tagHook(`C:\a\claude-sync.exe`))
	write(t, filepath.Join(a.syncDir, settingsFile), string(settingsA))
	a.sync(t)
	remote, _ := nc.file("Claude/global/settings.json")
	if strings.Contains(string(remote), "claude-sync") || !strings.Contains(string(remote), "opus") {
		t.Fatalf("no Nextcloud: %s", remote)
	}
	b.sync(t)
	local := read(t, filepath.Join(b.syncDir, settingsFile))
	if !strings.Contains(local, "/home/b/claude-sync") || strings.Contains(local, `C:\a`) || !strings.Contains(local, "opus") {
		t.Fatalf("no PC B: %s", local)
	}
	b.sync(t)
	if c := b.engine.Status().Counts; c.Conflicts != 0 || c.Up != 0 {
		t.Fatalf("o hook local gerou envio ou conflito: %+v", c)
	}
}

func TestMoveRemoteFolderOtherPCsFollow(t *testing.T) {
	nc := newFakeNextcloud(t)
	a := newPC(t, nc, "pc-a")
	b := newPC(t, nc, "pc-b")
	session := jsonl(map[string]string{"cwd": a.project})
	write(t, filepath.Join(a.folder(), "s.jsonl"), session)
	a.sync(t)
	b.engine.cfg.Links["bergatrix"] = b.project
	b.sync(t)

	// O app do PC A troca a pasta, movendo.
	store := &Store{Dir: t.TempDir()}
	app, err := newApp(store, func() {})
	if err != nil {
		t.Fatal(err)
	}
	app.cfg.Server, app.cfg.User = nc.server.URL, testUser
	if err := saveSecret(store, testUser, "app-pass"); err != nil {
		t.Fatal(err)
	}
	app.connectLocked()
	if err := app.SetRemoteDir(context.Background(), "Backups/Conversas", true); err == nil {
		// Backups não existe: o app cria os pais antes de mover.
	} else {
		t.Fatal(err)
	}
	if _, ok := nc.file("Backups/Conversas/projects/bergatrix/s.jsonl"); !ok {
		t.Fatal("não moveu")
	}
	if _, ok := nc.file("Claude/" + movedMarker); !ok {
		t.Fatal("faltou o aviso na pasta antiga")
	}
	if app.Status().RemoteDir != "Backups/Conversas" {
		t.Fatal("a configuração não mudou")
	}

	// O PC B ainda aponta para a pasta antiga: segue o aviso sem baixar tudo de novo.
	moved := make(chan string, 1)
	b.engine.onRemoteMoved = func(dir string) { moved <- dir }
	write(t, filepath.Join(b.folder(), "s.jsonl"), session+`{"text":"no B"}`+"\n")
	b.sync(t)
	if got := <-moved; got != "Backups/Conversas" {
		t.Fatalf("seguiu para %q", got)
	}
	if b.engine.remoteRoot() != "Backups/Conversas" {
		t.Fatal("o motor do B não trocou de pasta")
	}
	data, _ := nc.file("Backups/Conversas/projects/bergatrix/s.jsonl")
	if !strings.Contains(string(data), "no B") {
		t.Fatal("a continuação do B não foi para a pasta nova")
	}
	for p := range nc.files {
		if strings.HasPrefix(p, "Claude/") && p != "Claude/"+movedMarker {
			t.Fatalf("o B recriou a pasta antiga: %s", p)
		}
	}
	if c := b.engine.Status().Counts; c.Down != 1 || c.Conflicts != 0 {
		t.Fatalf("o B baixou de novo depois de seguir: %+v", c)
	}
}

func TestRemoteDirValidation(t *testing.T) {
	for _, bad := range []string{"", "/", "a/../b", "a/./b", "a:b", `a\..\b`} {
		if _, err := normalizeRemoteDir(bad); err == nil {
			t.Errorf("aceitou %q", bad)
		}
	}
	if got, _ := normalizeRemoteDir(" /Backups//Claude/ "); got != "" {
		t.Logf("barra dupla: %q", got)
	}
	if got, err := normalizeRemoteDir("/Backups/Claude/"); err != nil || got != "Backups/Claude" {
		t.Fatalf("%q %v", got, err)
	}
}

func TestTrayIcons(t *testing.T) {
	for _, tone := range []string{"ok", "busy", "error", "idle"} {
		ico := windowsIcon(tone)
		var header [3]uint16
		binary.Read(bytes.NewReader(ico), binary.LittleEndian, &header)
		if header != [3]uint16{0, 1, 3} {
			t.Fatalf("cabeçalho do .ico = %v", header)
		}
		img, err := png.Decode(bytes.NewReader(pngBytes(drawIcon(64, tone))))
		if err != nil || img.Bounds().Dx() != 64 {
			t.Fatal(err)
		}
		if dir := os.Getenv("CLAUDE_SYNC_ICON_PREVIEW"); dir != "" {
			os.WriteFile(filepath.Join(dir, "icon-"+tone+".png"), pngBytes(drawIcon(128, tone)), 0o644)
		}
	}
}
