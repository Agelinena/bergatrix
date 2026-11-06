package main

// Segredos: a web cifra no navegador com a chave pública do agente (sealed
// box: X25519 + XSalsa20-Poly1305, compatível com libsodium). Só o agente,
// com a chave privada de /etc/bergakup/agent.json, consegue abrir. O banco
// da web guarda apenas o texto cifrado.

import (
	"crypto/rand"
	"encoding/base64"
	"errors"

	"golang.org/x/crypto/nacl/box"
)

func generateKeys() (public, private string, err error) {
	pub, priv, err := box.GenerateKey(rand.Reader)
	if err != nil {
		return "", "", err
	}
	return base64.StdEncoding.EncodeToString(pub[:]), base64.StdEncoding.EncodeToString(priv[:]), nil
}

type Opener struct {
	pub, priv *[32]byte
}

func decodeKey(s string) (*[32]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(raw) != 32 {
		return nil, errors.New("chave inválida em agent.json")
	}
	var key [32]byte
	copy(key[:], raw)
	return &key, nil
}

func newOpener(id *Identity) (*Opener, error) {
	pub, err := decodeKey(id.PublicKey)
	if err != nil {
		return nil, err
	}
	priv, err := decodeKey(id.PrivateKey)
	if err != nil {
		return nil, err
	}
	return &Opener{pub: pub, priv: priv}, nil
}

// Open abre um segredo. what entra na mensagem de erro ("senha do repositório").
func (o *Opener) Open(sealed, what string) (string, error) {
	if sealed == "" {
		return "", errors.New(what + ": não definido na interface")
	}
	raw, err := base64.StdEncoding.DecodeString(sealed)
	if err != nil {
		return "", errors.New(what + ": formato inválido")
	}
	out, ok := box.OpenAnonymous(nil, raw, o.pub, o.priv)
	if !ok {
		return "", errors.New(what + ": não abre com a chave deste agente (digite de novo na interface)")
	}
	return string(out), nil
}
