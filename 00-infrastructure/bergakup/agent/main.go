// bergakup-agent: executa o backup da Bergatrix no host.
//
//	bergakup-agent enroll --api http://127.0.0.1:8087 --code bkc_... --name servidor --repo-root /home/eu/bergatrix
//	bergakup-agent run                 serviço (systemd: bergakup-agent.service)
//	bergakup-agent recover             recuperação de desastre, sem a web (kit de recuperação)
//	bergakup-agent import-dumps [--dir /srv/appdata/bergakup/dumps] [stack...]
//	bergakup-agent version
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

var version = "dev"

func main() {
	log.SetFlags(0) // o journald já põe data e hora
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	var err error
	switch os.Args[1] {
	case "enroll":
		err = cmdEnroll(ctx, os.Args[2:])
	case "run":
		err = cmdRun(ctx)
	case "recover":
		err = cmdRecover(ctx)
	case "import-dumps":
		err = cmdImportDumps(ctx, os.Args[2:])
	case "version", "--version", "-v":
		fmt.Println("bergakup-agent", version)
	default:
		usage()
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "erro:", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `uso: bergakup-agent <comando>

  enroll        registra este host na interface (código gerado em Agente → Instalar)
  run           roda o serviço (normalmente pelo systemd)
  recover       recuperação de desastre: restaura direto do repositório, sem a web
  import-dumps  devolve os dumps aos bancos (depois de restaurar o servidor)
  version       mostra a versão`)
}

func requireRoot() error {
	if os.Geteuid() != 0 {
		return fmt.Errorf("rode como root: o agente lê todos os dados e controla o Docker")
	}
	return nil
}

func cmdEnroll(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("enroll", flag.ExitOnError)
	api := fs.String("api", "http://127.0.0.1:8087", "endereço da API do Bergakup neste host")
	code := fs.String("code", "", "código de instalação (gerado na interface)")
	name := fs.String("name", "", "nome deste agente (ex.: servidor)")
	repoRoot := fs.String("repo-root", "", "pasta do repositório bergatrix neste host")
	force := fs.Bool("force", false, "substitui um registro existente")
	_ = fs.Parse(args)
	if err := requireRoot(); err != nil {
		return err
	}
	if *code == "" || *name == "" {
		return fmt.Errorf("informe --code e --name")
	}
	if _, err := os.Stat(identityPath()); err == nil && !*force {
		return fmt.Errorf("este host já está registrado (%s). Use --force para registrar de novo", identityPath())
	}
	pub, priv, err := generateKeys()
	if err != nil {
		return err
	}
	hostname, _ := os.Hostname()
	var resp struct {
		AgentID string `json:"agent_id"`
		Token   string `json:"token"`
	}
	client := newClient(*api, "")
	reqCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := client.do(reqCtx, "POST", "/enroll", map[string]any{
		"code": strings.TrimSpace(*code), "name": *name, "hostname": hostname, "public_key": pub,
		"version": version, "repo_root": strings.TrimRight(*repoRoot, "/"),
	}, &resp); err != nil {
		return err
	}
	id := &Identity{APIURL: *api, AgentID: resp.AgentID, Token: resp.Token, Name: *name, PublicKey: pub, PrivateKey: priv}
	if err := writeJSONAtomic(identityPath(), id, 0o600); err != nil {
		return err
	}
	fmt.Printf("Agente %q registrado. Identidade em %s.\nAgora: systemctl enable --now bergakup-agent\n", *name, identityPath())
	return nil
}

func cmdRun(ctx context.Context) error {
	if err := requireRoot(); err != nil {
		return err
	}
	for _, dir := range []string{stateDir, cacheDir} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
	}
	id, err := loadIdentity()
	if err != nil {
		return err
	}
	agent, err := newAgent(id)
	if err != nil {
		return err
	}
	agent.Run(ctx)
	return nil
}

func cmdImportDumps(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("import-dumps", flag.ExitOnError)
	dir := fs.String("dir", "/srv/appdata/bergakup/dumps", "pasta dos dumps")
	_ = fs.Parse(args)
	if err := requireRoot(); err != nil {
		return err
	}
	return importDumps(ctx, func(level, msg string) { fmt.Printf("[%s] %s\n", level, msg) }, *dir, fs.Args())
}
