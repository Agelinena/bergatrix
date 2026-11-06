package main

// macOS: a bandeja (barra de menus) exigiria cgo, e os binários são
// compilados sem cgo. O app roda sem ícone; a interface fica no navegador.

import "context"

func runTray(context.Context, *App, string, func(), bool) {}
