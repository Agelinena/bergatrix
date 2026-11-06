package main

// Recuperação de desastre, sem a web. Com o kit impresso (endereços dos
// repositórios e a senha de recuperação) e uma chave do B2, restaura direto
// do repositório. Ordem sugerida no kit:
//   1. docker   → repositório, composes, .env e /etc/bergakup (identidade do agente)
//   2. servidor → /srv/appdata e os dumps dos bancos
//   3. subir tudo e importar os dumps
//   4. userdata → por último, pode levar horas (350 GB+)

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/term"
)

var b2Region = regexp.MustCompile(`s3\.([a-z0-9-]+)\.backblazeb2\.com`)

type prompter struct{ in *bufio.Reader }

func (p *prompter) ask(question, fallback string) string {
	if fallback != "" {
		fmt.Printf("%s [%s]: ", question, fallback)
	} else {
		fmt.Printf("%s: ", question)
	}
	line, _ := p.in.ReadString('\n')
	line = strings.TrimSpace(line)
	if line == "" {
		return fallback
	}
	return line
}

func (p *prompter) secret(question string) string {
	fmt.Printf("%s: ", question)
	data, err := term.ReadPassword(int(syscall.Stdin))
	fmt.Println()
	if err != nil {
		line, _ := p.in.ReadString('\n')
		return strings.TrimSpace(line)
	}
	return strings.TrimSpace(string(data))
}

func (p *prompter) yes(question string, def bool) bool {
	hint := "s/N"
	if def {
		hint = "S/n"
	}
	answer := strings.ToLower(p.ask(question+" ("+hint+")", ""))
	if answer == "" {
		return def
	}
	return strings.HasPrefix(answer, "s") || strings.HasPrefix(answer, "y")
}

func cmdRecover(ctx context.Context) error {
	if err := requireRoot(); err != nil {
		return err
	}
	if _, err := exec.LookPath(resticBin); err != nil {
		return fmt.Errorf("restic não encontrado: instale antes (o install.sh do agente instala)")
	}
	p := &prompter{in: bufio.NewReader(os.Stdin)}
	fmt.Println(`Recuperação de desastre do Bergakup
Tenha em mãos o kit de recuperação e uma Application Key do B2 (crie uma nova no painel do B2).
Ordem: docker → servidor → subir tudo e importar dumps → userdata.`)
	console := &Run{Kind: "recover"}
	for {
		fmt.Println()
		repo := p.ask("Endereço do repositório (do kit)", "")
		if repo == "" {
			break
		}
		env := []string{"RESTIC_REPOSITORY=" + repo, "RESTIC_CACHE_DIR=" + filepath.Join(cacheDir, "restic")}
		switch {
		case strings.HasPrefix(repo, "s3:"):
			region := ""
			if m := b2Region.FindStringSubmatch(repo); m != nil {
				region = m[1]
			}
			env = append(env, "AWS_ACCESS_KEY_ID="+p.ask("B2 Key ID", ""),
				"AWS_SECRET_ACCESS_KEY="+p.secret("B2 Application Key"),
				"AWS_DEFAULT_REGION="+p.ask("Região", region))
		case strings.HasPrefix(repo, "rest:"):
			if user := p.ask("Usuário do rest-server (vazio se não tiver)", ""); user != "" {
				env = append(env, "RESTIC_REST_USERNAME="+user, "RESTIC_REST_PASSWORD="+p.secret("Senha do rest-server"))
			}
		}
		env = append(env, "RESTIC_PASSWORD="+p.secret("Senha de recuperação (do kit)"))
		r := &Restic{env: env, hostname: "recuperacao"}

		list, err := r.Snapshots(ctx, console)
		if err != nil {
			fmt.Println("Não consegui ler o repositório:", err)
			continue
		}
		if len(list) == 0 {
			fmt.Println("O repositório não tem snapshots.")
			continue
		}
		start := max(0, len(list)-8)
		for i := len(list) - 1; i >= start; i-- {
			s := list[i]
			fmt.Printf("  [%d] %s  %s  %s\n", len(list)-1-i, s.ShortID, s.Time.Local().Format("02/01/2006 15:04"),
				strings.Join(s.Paths, ", "))
		}
		choice, _ := strconv.Atoi(p.ask("Qual snapshot", "0"))
		if choice < 0 || choice >= len(list) {
			choice = 0
		}
		snap := list[len(list)-1-choice]
		target := p.ask("Restaurar em (\"/\" = lugar original)", "/")
		fmt.Printf("Vai restaurar %s (%s) em %s, sobrescrevendo os arquivos que existirem.\n", snap.ShortID,
			strings.Join(snap.Paths, ", "), target)
		if !p.yes("Continuar?", false) {
			continue
		}
		if err := r.Restore(ctx, console, snap.ID, target, nil); err != nil {
			fmt.Println("A restauração falhou:", err)
			continue
		}
		fmt.Println("Restaurado.")
		if !p.yes("Restaurar outro repositório?", true) {
			break
		}
	}

	fmt.Println()
	if p.yes("Subir as stacks agora (subir-tudo.sh)?", true) {
		root := p.ask("Pasta do repositório bergatrix", guessRepoRoot())
		cmd := exec.CommandContext(ctx, filepath.Join(root, "00-infrastructure", "subir-tudo.sh"))
		cmd.Dir, cmd.Stdout, cmd.Stderr = root, os.Stdout, os.Stderr
		if err := cmd.Run(); err != nil {
			fmt.Println("O subir-tudo.sh terminou com erro:", err)
		}
	}
	if p.yes("Importar os dumps dos bancos agora?", true) {
		dir := p.ask("Pasta dos dumps", "/srv/appdata/bergakup/dumps")
		if err := importDumps(ctx, func(level, msg string) { fmt.Printf("[%s] %s\n", level, msg) }, dir, nil); err != nil {
			fmt.Println(err)
		}
	}
	fmt.Println(`
Próximos passos:
  - Se /etc/bergakup foi restaurado (conjunto docker), o agente volta com a mesma identidade:
      systemctl enable --now bergakup-agent
    Os segredos guardados na web continuam abrindo com essa chave.
  - Senão, registre um agente novo (bergakup-agent enroll --force) e digite os segredos de novo na interface.
  - Restaure o userdata por último, pela interface ou por aqui.`)
	return nil
}

func guessRepoRoot() string {
	var id Identity
	if readJSON(identityPath(), &id) == nil {
		var plan Plan
		if readJSON(planPath(), &plan) == nil && plan.Host.RepoRoot != "" {
			return plan.Host.RepoRoot
		}
	}
	if home, err := os.UserHomeDir(); err == nil {
		return filepath.Join(home, "bergatrix")
	}
	return "/root/bergatrix"
}
