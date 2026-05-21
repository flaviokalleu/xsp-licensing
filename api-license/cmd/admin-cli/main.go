// admin-cli: utilitário para gerar segredos e criar a primeira KEY localmente.
// Uso:
//   go run ./cmd/admin-cli gen-secrets       # imprime HMAC, JWT, Ed25519 (b64)
//   go run ./cmd/admin-cli gen-key           # gera uma KEY no formato XSP-XXXX-...
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"os"

	xcrypto "github.com/xsp/api-license/internal/crypto"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		return
	}
	switch os.Args[1] {
	case "gen-secrets":
		genSecrets()
	case "gen-key":
		k, err := xcrypto.GenerateLicenseKey()
		if err != nil {
			fmt.Println("error:", err)
			os.Exit(1)
		}
		fmt.Println(k)
	case "hash-key":
		if len(os.Args) < 3 {
			fmt.Println("usage: admin-cli hash-key XSP-AAAA-BBBB-CCCC-DDDD")
			os.Exit(1)
		}
		fmt.Println(xcrypto.HashKey(os.Args[2]))
	default:
		usage()
	}
}

func usage() {
	fmt.Println(`xsp admin-cli
  gen-secrets   -> output HMAC, JWT, ADMIN_TOKEN, RELEASE_MASTER_KEY and Ed25519 keypair
  gen-key       -> generate one license KEY
  hash-key KEY  -> print argon2 hash of given key`)
}

func genSecrets() {
	hmacSecret := make([]byte, 32)
	jwtSecret := make([]byte, 32)
	adminTok := make([]byte, 32)
	master := make([]byte, 32)
	rand.Read(hmacSecret)
	rand.Read(jwtSecret)
	rand.Read(adminTok)
	rand.Read(master)
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		fmt.Println("error:", err)
		os.Exit(1)
	}
	fmt.Println("# Cole no .env da api-license/")
	fmt.Printf("HMAC_PUBLIC_SECRET=%s\n", hex.EncodeToString(hmacSecret))
	fmt.Printf("JWT_SECRET=%s\n", hex.EncodeToString(jwtSecret))
	fmt.Printf("ADMIN_TOKEN=%s\n", base64.RawURLEncoding.EncodeToString(adminTok))
	fmt.Printf("RELEASE_MASTER_KEY=%s\n", hex.EncodeToString(master))
	fmt.Printf("ED25519_PRIVATE_KEY_B64=%s\n", base64.StdEncoding.EncodeToString(priv))
	fmt.Printf("ED25519_PUBLIC_KEY_B64=%s\n", base64.StdEncoding.EncodeToString(pub))
}
