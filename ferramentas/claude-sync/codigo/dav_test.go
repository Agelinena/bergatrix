package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// O Traefik oferece HTTP/2. O cliente tem que falar HTTP/1.1 mesmo assim
// (em HTTP/2 um PUT cortado ficou gravado pela metade) e funcionar.
func TestDavUsesHTTP1OverTLS(t *testing.T) {
	var proto int
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		proto = r.ProtoMajor
		w.Write([]byte("ok"))
	}))
	srv.EnableHTTP2 = true
	srv.StartTLS()
	defer srv.Close()

	d := newDav(srv.URL, "u", "p")
	d.client.Transport.(*http.Transport).TLSClientConfig.RootCAs = srv.Client().Transport.(*http.Transport).TLSClientConfig.RootCAs
	data, err := d.Get(context.Background(), "arquivo")
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "ok" || proto != 1 {
		t.Fatalf("resposta %q por HTTP/%d", data, proto)
	}
}
