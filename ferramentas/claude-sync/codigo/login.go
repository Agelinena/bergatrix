package main

// Login Flow v2 do Nextcloud, o mesmo do app de desktop: o navegador abre o
// login (que passa pelo Authentik), e o app recebe uma senha de app própria,
// que aparece em Dispositivos e sessões e pode ser revogada de lá.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

type loginFlow struct {
	Login string `json:"login"`
	Poll  struct {
		Token    string `json:"token"`
		Endpoint string `json:"endpoint"`
	} `json:"poll"`
}

type loginResult struct {
	Server      string `json:"server"`
	LoginName   string `json:"loginName"`
	AppPassword string `json:"appPassword"`
}

func userAgent() string {
	host, _ := os.Hostname()
	if host == "" {
		host = "PC"
	}
	return "claude-sync (" + host + ")"
}

func normalizeServer(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", errors.New("informe o endereço do Nextcloud")
	}
	if !strings.Contains(raw, "://") {
		raw = "https://" + raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return "", errors.New("endereço inválido")
	}
	if u.Scheme != "https" && !isLoopbackHost(u.Hostname()) {
		return "", errors.New("use https:// (a senha de app não pode trafegar sem TLS)")
	}
	return strings.TrimRight(u.Scheme+"://"+u.Host+u.Path, "/"), nil
}

func isLoopbackHost(host string) bool {
	return host == "localhost" || host == "127.0.0.1" || host == "::1"
}

var httpClient = &http.Client{Timeout: 30 * time.Second}

func startLogin(ctx context.Context, server string) (*loginFlow, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, server+"/index.php/login/v2", nil)
	req.Header.Set("User-Agent", userAgent())
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("não consegui falar com o Nextcloud: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("o servidor não parece ser um Nextcloud (HTTP %d)", resp.StatusCode)
	}
	var flow loginFlow
	if err := json.NewDecoder(resp.Body).Decode(&flow); err != nil || flow.Login == "" || flow.Poll.Token == "" {
		return nil, errors.New("resposta inesperada do Nextcloud no login")
	}
	return &flow, nil
}

// pollLogin espera o login terminar no navegador (até 20 minutos).
func pollLogin(ctx context.Context, flow *loginFlow) (*loginResult, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Minute)
	defer cancel()
	form := url.Values{"token": {flow.Poll.Token}}.Encode()
	for {
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, flow.Poll.Endpoint, strings.NewReader(form))
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		req.Header.Set("User-Agent", userAgent())
		resp, err := httpClient.Do(req)
		if err == nil {
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				var result loginResult
				if err := json.Unmarshal(body, &result); err != nil || result.AppPassword == "" {
					return nil, errors.New("resposta inesperada do Nextcloud no fim do login")
				}
				return &result, nil
			}
		}
		select {
		case <-ctx.Done():
			return nil, errors.New("o login não foi concluído a tempo")
		case <-time.After(2 * time.Second):
		}
	}
}

// userID devolve o ID usado no caminho do WebDAV (pode ser diferente do nome de login).
func userID(ctx context.Context, server, login, password string) (string, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, server+"/ocs/v2.php/cloud/user?format=json", nil)
	req.SetBasicAuth(login, password)
	req.Header.Set("OCS-APIRequest", "true")
	req.Header.Set("User-Agent", userAgent())
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("não consegui ler o usuário (HTTP %d)", resp.StatusCode)
	}
	var out struct {
		OCS struct {
			Data struct {
				ID string `json:"id"`
			} `json:"data"`
		} `json:"ocs"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil || out.OCS.Data.ID == "" {
		return "", errors.New("resposta inesperada ao ler o usuário")
	}
	return out.OCS.Data.ID, nil
}

// revokeAppPassword apaga a senha de app no servidor (ao desconectar).
func revokeAppPassword(ctx context.Context, server, user, password string) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodDelete, server+"/ocs/v2.php/core/apppassword", nil)
	req.SetBasicAuth(user, password)
	req.Header.Set("OCS-APIRequest", "true")
	if resp, err := httpClient.Do(req); err == nil {
		resp.Body.Close()
	}
}
