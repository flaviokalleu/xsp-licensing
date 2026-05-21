package tamper

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
)

// SelfSHA256 retorna hash do próprio binário em execução.
func SelfSHA256() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	f, err := os.Open(exe)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}
