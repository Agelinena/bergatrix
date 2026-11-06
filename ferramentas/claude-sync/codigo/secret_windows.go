package main

// Windows: a senha de app é cifrada com DPAPI (CryptProtectData), presa à
// conta do Windows. Outro usuário, ou o arquivo copiado para outro PC, não
// consegue abrir.

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"
)

var (
	crypt32           = syscall.NewLazyDLL("crypt32.dll")
	kernel32          = syscall.NewLazyDLL("kernel32.dll")
	procProtectData   = crypt32.NewProc("CryptProtectData")
	procUnprotectData = crypt32.NewProc("CryptUnprotectData")
	procLocalFree     = kernel32.NewProc("LocalFree")
)

const cryptprotectUIForbidden = 0x1

var dpapiEntropy = []byte("claude-sync/v1")

type dataBlob struct {
	size uint32
	data *byte
}

func blobOf(b []byte) *dataBlob {
	if len(b) == 0 {
		return &dataBlob{}
	}
	return &dataBlob{size: uint32(len(b)), data: &b[0]}
}

func (b *dataBlob) bytes() []byte {
	out := make([]byte, b.size)
	copy(out, unsafe.Slice(b.data, b.size))
	return out
}

func dpapi(proc *syscall.LazyProc, in []byte) ([]byte, error) {
	var out dataBlob
	r, _, err := proc.Call(
		uintptr(unsafe.Pointer(blobOf(in))), 0,
		uintptr(unsafe.Pointer(blobOf(dpapiEntropy))), 0, 0,
		cryptprotectUIForbidden, uintptr(unsafe.Pointer(&out)))
	if r == 0 {
		return nil, err
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(out.data)))
	return out.bytes(), nil
}

func secretPath(store *Store) string { return filepath.Join(store.Dir, "credential.dpapi") }

func saveSecret(store *Store, _ string, secret string) error {
	sealed, err := dpapi(procProtectData, []byte(secret))
	if err != nil {
		return err
	}
	return writeAtomic(secretPath(store), sealed, 0o600)
}

func loadSecret(store *Store, _ string) (string, error) {
	sealed, err := os.ReadFile(secretPath(store))
	if errors.Is(err, os.ErrNotExist) {
		return "", errNoSecret
	}
	if err != nil {
		return "", err
	}
	plain, err := dpapi(procUnprotectData, sealed)
	if err != nil {
		return "", err
	}
	return string(plain), nil
}

func deleteSecret(store *Store, _ string) error {
	err := os.Remove(secretPath(store))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}
