//go:build windows || linux

package main

// Ícone na bandeja: a "setinha" da barra de tarefas no Windows, a área de
// notificação no Linux (StatusNotifierItem; no GNOME precisa da extensão
// AppIndicator). Clique: abre a interface. Menu: estado, abrir,
// sincronizar agora, fechar.

import (
	"context"
	"time"

	"fyne.io/systray"
)

func trayState(st AppStatus) (text, tone string) {
	e := st.Engine
	switch {
	case !st.Connected:
		return "Falta entrar no Nextcloud", "idle"
	case !st.Active:
		return "Falta ativar a pasta", "idle"
	case e.LastError != "":
		return "Sem conexão com o Nextcloud", "error"
	case e.Syncing:
		return "Sincronizando…", "busy"
	case e.Running && e.LastSync != "":
		return "Sincronizado às " + e.LastSync, "ok"
	case e.Running:
		return "Sincronizando…", "busy"
	}
	return "Pausado", "idle"
}

func runTray(ctx context.Context, app *App, url string, quit func(), headless bool) {
	if headless {
		return
	}
	onReady := func() {
		systray.SetIcon(trayIcon("idle"))
		systray.SetTitle("claude-sync")
		systray.SetTooltip("claude-sync")
		systray.SetOnTapped(func() { _ = openBrowser(url) })

		state := systray.AddMenuItem("claude-sync", "")
		state.Disable()
		systray.AddSeparator()
		open := systray.AddMenuItem("Abrir o claude-sync", "Abre a interface no navegador")
		syncNow := systray.AddMenuItem("Sincronizar agora", "")
		systray.AddSeparator()
		exit := systray.AddMenuItem("Fechar", "Para a sincronização até abrir de novo")

		go func() {
			ticker := time.NewTicker(2 * time.Second)
			defer ticker.Stop()
			lastText, lastTone := "", ""
			update := func() {
				text, tone := trayState(app.Status())
				if tone != lastTone {
					systray.SetIcon(trayIcon(tone))
					lastTone = tone
				}
				if text != lastText {
					systray.SetTooltip("claude-sync · " + text)
					state.SetTitle(text)
					lastText = text
				}
			}
			update()
			for {
				select {
				case <-ctx.Done():
					systray.Quit()
					return
				case <-open.ClickedCh:
					_ = openBrowser(url)
				case <-syncNow.ClickedCh:
					app.SyncNow()
				case <-exit.ClickedCh:
					quit()
				case <-ticker.C:
					update()
				}
			}
		}()
	}
	// Sem bandeja (Linux sem StatusNotifier), Run volta logo e o app segue sem ícone.
	systray.Run(onReady, func() {})
}
