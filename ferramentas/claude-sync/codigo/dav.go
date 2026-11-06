package main

// O mínimo de WebDAV do Nextcloud: listar (PROPFIND), baixar, enviar e
// criar pasta. O Nextcloud propaga o etag de um arquivo para todas as pastas
// acima dele, então uma pasta com o etag igual ao da última vez não mudou por
// dentro e não precisa ser percorrida.

import (
	"bytes"
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

type Dav struct {
	root     string // https://servidor/remote.php/dav/files/<usuário>
	rootPath string
	user     string
	password string
	client   *http.Client
}

type DavEntry struct {
	Path string
	Dir  bool
	ETag string
	Size int64
}

var errUnauthorized = errors.New("o Nextcloud recusou a senha de app (401): entre de novo")

func newDav(server, user, password string) *Dav {
	root := strings.TrimRight(server, "/") + "/remote.php/dav/files/" + url.PathEscape(user)
	u, _ := url.Parse(root)
	return &Dav{root: root, rootPath: strings.TrimRight(u.Path, "/"), user: user, password: password,
		client: &http.Client{Timeout: 2 * time.Minute}}
}

func escapePath(p string) string {
	parts := strings.Split(strings.Trim(p, "/"), "/")
	for i, part := range parts {
		parts[i] = url.PathEscape(part)
	}
	return strings.Join(parts, "/")
}

func (d *Dav) do(ctx context.Context, method, path string, body []byte, headers map[string]string) (*http.Response, []byte, error) {
	target := d.root
	if p := strings.Trim(path, "/"); p != "" {
		target += "/" + escapePath(p)
	}
	req, err := http.NewRequestWithContext(ctx, method, target, bytes.NewReader(body))
	if err != nil {
		return nil, nil, err
	}
	req.SetBasicAuth(d.user, d.password)
	req.Header.Set("User-Agent", userAgent())
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := d.client.Do(req)
	if err != nil {
		return nil, nil, fmt.Errorf("sem conexão com o Nextcloud: %w", err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if resp.StatusCode == http.StatusUnauthorized {
		return resp, nil, errUnauthorized
	}
	return resp, data, err
}

type multistatus struct {
	Responses []struct {
		Href     string `xml:"href"`
		Propstat []struct {
			Status string `xml:"status"`
			Prop   struct {
				ETag         string    `xml:"getetag"`
				Length       string    `xml:"getcontentlength"`
				ResourceType *struct { // presente em toda resposta; Collection marca pasta
					Collection *struct{} `xml:"collection"`
				} `xml:"resourcetype"`
			} `xml:"prop"`
		} `xml:"propstat"`
	} `xml:"response"`
}

const propfindBody = `<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop>` +
	`<d:getetag/><d:getcontentlength/><d:resourcetype/></d:prop></d:propfind>`

// Propfind lista `path` (depth "0") ou ele e os filhos diretos (depth "1").
// Uma pasta que não existe devolve nil, sem erro.
func (d *Dav) Propfind(ctx context.Context, path, depth string) ([]DavEntry, error) {
	resp, data, err := d.do(ctx, "PROPFIND", path, []byte(propfindBody),
		map[string]string{"Depth": depth, "Content-Type": "application/xml"})
	if err != nil {
		return nil, err
	}
	if resp.StatusCode == http.StatusNotFound {
		return nil, nil
	}
	if resp.StatusCode != http.StatusMultiStatus {
		return nil, fmt.Errorf("PROPFIND %s: HTTP %d", path, resp.StatusCode)
	}
	var ms multistatus
	if err := xml.Unmarshal(data, &ms); err != nil {
		return nil, fmt.Errorf("PROPFIND %s: resposta inválida: %w", path, err)
	}
	var entries []DavEntry
	for _, r := range ms.Responses {
		u, err := url.Parse(r.Href)
		if err != nil {
			continue
		}
		p := u.Path
		if unescaped, err := url.PathUnescape(p); err == nil {
			p = unescaped
		}
		p = strings.Trim(strings.TrimPrefix(p, d.rootPath), "/")
		entry := DavEntry{Path: p}
		found := false
		for _, ps := range r.Propstat {
			if ps.Status != "" && !strings.Contains(ps.Status, " 200") {
				continue
			}
			found = true
			if ps.Prop.ETag != "" {
				entry.ETag = strings.Trim(ps.Prop.ETag, `"`)
			}
			if ps.Prop.ResourceType != nil && ps.Prop.ResourceType.Collection != nil {
				entry.Dir = true
			}
			if n, err := strconv.ParseInt(ps.Prop.Length, 10, 64); err == nil {
				entry.Size = n
			}
		}
		if found {
			entries = append(entries, entry)
		}
	}
	return entries, nil
}

func (d *Dav) Get(ctx context.Context, path string) ([]byte, error) {
	resp, data, err := d.do(ctx, http.MethodGet, path, nil, nil)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: HTTP %d", path, resp.StatusCode)
	}
	return data, nil
}

func (d *Dav) Mkcol(ctx context.Context, path string) error {
	resp, _, err := d.do(ctx, "MKCOL", path, nil, nil)
	if err != nil {
		return err
	}
	// 405: a pasta já existe.
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusMethodNotAllowed {
		return fmt.Errorf("MKCOL %s: HTTP %d", path, resp.StatusCode)
	}
	return nil
}

// Move renomeia uma pasta ou arquivo no servidor (sem sobrescrever o destino).
func (d *Dav) Move(ctx context.Context, from, to string) error {
	resp, _, err := d.do(ctx, "MOVE", from, nil, map[string]string{
		"Destination": d.root + "/" + escapePath(to),
		"Overwrite":   "F",
	})
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("MOVE %s → %s: HTTP %d", from, to, resp.StatusCode)
	}
	return nil
}

// Put envia o arquivo e devolve o etag novo (vazio se o servidor não mandar).
func (d *Dav) Put(ctx context.Context, path string, data []byte, mtime time.Time) (string, error) {
	resp, _, err := d.do(ctx, http.MethodPut, path, data, map[string]string{
		"Content-Type": "application/octet-stream",
		"X-OC-Mtime":   strconv.FormatInt(mtime.Unix(), 10),
	})
	if err != nil {
		return "", err
	}
	switch resp.StatusCode {
	case http.StatusOK, http.StatusCreated, http.StatusNoContent:
	default:
		return "", fmt.Errorf("PUT %s: HTTP %d", path, resp.StatusCode)
	}
	etag := resp.Header.Get("OC-ETag")
	if etag == "" {
		etag = resp.Header.Get("ETag")
	}
	return strings.Trim(etag, `"`), nil
}
