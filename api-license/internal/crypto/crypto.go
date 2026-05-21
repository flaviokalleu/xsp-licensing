package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"golang.org/x/crypto/argon2"
)

// ===== License KEY generation =====

const keyAlphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"

func GenerateLicenseKey() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	groups := make([]string, 4)
	for i := 0; i < 4; i++ {
		chunk := raw[i*4 : (i+1)*4]
		sum := uint64(chunk[0])<<24 | uint64(chunk[1])<<16 | uint64(chunk[2])<<8 | uint64(chunk[3])
		g := make([]byte, 4)
		for j := 0; j < 4; j++ {
			g[j] = keyAlphabet[sum&31]
			sum >>= 5
		}
		groups[i] = string(g)
	}
	return "XSP-" + strings.Join(groups, "-"), nil
}

func NormalizeKey(k string) string {
	k = strings.ToUpper(strings.TrimSpace(k))
	return k
}

func HashKey(key string) string {
	key = NormalizeKey(key)
	h := argon2.IDKey([]byte(key), []byte("xsp-license-salt-v1"), 1, 64*1024, 4, 32)
	return base64.RawStdEncoding.EncodeToString(h)
}

// ===== HMAC request signature =====

func SignHMAC(secret, payload []byte) string {
	m := hmac.New(sha256.New, secret)
	m.Write(payload)
	return hex.EncodeToString(m.Sum(nil))
}

func VerifyHMAC(secret, payload []byte, given string) bool {
	expected := SignHMAC(secret, payload)
	return subtle.ConstantTimeCompare([]byte(expected), []byte(given)) == 1
}

// ===== Ed25519 license token =====

type LicenseToken struct {
	Sub       string   `json:"sub"`        // installation_id
	LicenseID string   `json:"lic"`
	HWID      string   `json:"hwid"`
	Plan      string   `json:"plan"`
	Features  []string `json:"feat"`
	IssuedAt  int64    `json:"iat"`
	ExpiresAt int64    `json:"exp"`        // token ttl (24h)
	NotAfter  int64    `json:"nbf_panel"`  // licença expira_em
	Nonce     string   `json:"nonce"`
}

type Signer struct {
	priv ed25519.PrivateKey
	pub  ed25519.PublicKey
}

func NewSignerFromB64(privB64, pubB64 string) (*Signer, error) {
	pb, err := base64.StdEncoding.DecodeString(privB64)
	if err != nil {
		return nil, fmt.Errorf("priv b64: %w", err)
	}
	pubb, err := base64.StdEncoding.DecodeString(pubB64)
	if err != nil {
		return nil, fmt.Errorf("pub b64: %w", err)
	}
	// Aceita raw 64/32 bytes ou PEM/DER (tenta raw primeiro)
	if len(pb) == ed25519.PrivateKeySize && len(pubb) == ed25519.PublicKeySize {
		return &Signer{priv: ed25519.PrivateKey(pb), pub: ed25519.PublicKey(pubb)}, nil
	}
	return nil, errors.New("expected raw Ed25519 keys (64/32 bytes)")
}

// Issue produces base64url(payload).base64url(signature)
func (s *Signer) Issue(tok LicenseToken) (string, error) {
	body, err := json.Marshal(tok)
	if err != nil {
		return "", err
	}
	hdr := []byte(`{"alg":"EdDSA","typ":"XSP1"}`)
	encHdr := base64.RawURLEncoding.EncodeToString(hdr)
	encBody := base64.RawURLEncoding.EncodeToString(body)
	signing := encHdr + "." + encBody
	sig := ed25519.Sign(s.priv, []byte(signing))
	return signing + "." + base64.RawURLEncoding.EncodeToString(sig), nil
}

// ===== AES-256-GCM master key sealing for HWID-bound delivery =====

// SealMasterKey encrypts the release master key with key=sha256(hwid||nonce).
// Returns base64(nonce|ciphertext|tag).
func SealMasterKey(masterHex, hwid string) (sealedB64 string, nonceHex string, err error) {
	mk, err := hex.DecodeString(masterHex)
	if err != nil {
		return "", "", err
	}
	nonce := make([]byte, 12)
	if _, err := rand.Read(nonce); err != nil {
		return "", "", err
	}
	keyMat := sha256.Sum256([]byte(hwid + "|" + hex.EncodeToString(nonce)))
	block, err := aes.NewCipher(keyMat[:])
	if err != nil {
		return "", "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", "", err
	}
	ct := gcm.Seal(nil, nonce, mk, nil)
	return base64.StdEncoding.EncodeToString(append(nonce, ct...)), hex.EncodeToString(nonce), nil
}

// ===== Nonce / time-skew helpers =====

func RandomNonce(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func WithinClockSkew(clientTs int64, maxSkew time.Duration) bool {
	d := time.Now().Unix() - clientTs
	if d < 0 {
		d = -d
	}
	return time.Duration(d)*time.Second <= maxSkew
}
