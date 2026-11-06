// claude-sync: conversas do Claude Code no Nextcloud, de qualquer PC.
//
//	claude-sync                abre a interface (e sobe o app, se não estiver rodando)
//	claude-sync --background   sobe sem abrir o navegador (início automático)
//	claude-sync version
//
// Só uma cópia roda por vez: abrir de novo só abre a interface da que já está rodando.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"
)

var version = "dev"

const defaultPort = "47823"

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "version" || os.Args[1] == "--version") {
		fmt.Println("claude-sync", version)
		return
	}
	background := flag.Bool("background", false, "não abre o navegador")
	port := flag.String("port", defaultPort, "porta da interface local")
	noBrowser := flag.Bool("no-browser", false, "nunca abre o navegador (testes)")
	flag.Parse()
	if *noBrowser {
		*background = true
	}

	dir, err := appDir()
	if err != nil {
		fatal(err)
	}
	setupLog(dir)
	address := "127.0.0.1:" + *port
	url := "http://" + address + "/"

	listener, err := net.Listen("tcp", address)
	if err != nil {
		// Já está rodando: só mostra a interface.
		if !*background {
			_ = openBrowser(url)
		}
		return
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	app, err := newApp(&Store{Dir: dir}, stop)
	if err != nil {
		fatal(err)
	}
	server := &http.Server{Handler: newWebServer(app, *port), ReadHeaderTimeout: 10 * time.Second}
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("interface: %v", err)
			stop()
		}
	}()
	go app.engine.Run(ctx)
	log.Printf("claude-sync %s em %s", version, url)
	if !*noBrowser && (!*background || !app.Configured()) {
		_ = openBrowser(url)
	}

	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = server.Shutdown(shutdown)
	// Uma última volta para mandar o que mudou desde a anterior.
	_ = app.engine.Cycle(shutdown, false)
	log.Print("encerrado")
}

func setupLog(dir string) {
	path := filepath.Join(dir, "claude-sync.log")
	if info, err := os.Stat(path); err == nil && info.Size() > 2<<20 {
		_ = os.Rename(path, path+".1")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	// No Windows o app não tem console: o log vai só para o arquivo.
	log.SetOutput(io.MultiWriter(f, os.Stderr))
	log.SetFlags(log.LstdFlags)
}

func fatal(err error) {
	log.Print("erro: ", err)
	fmt.Fprintln(os.Stderr, "erro:", err)
	os.Exit(1)
}
