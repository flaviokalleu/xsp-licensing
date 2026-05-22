package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/xsp/installer/internal/api"
	"github.com/xsp/installer/internal/config"
	"github.com/xsp/installer/internal/docker"
	"github.com/xsp/installer/internal/system"
	"github.com/xsp/installer/internal/tui"
)

func main() {
	tui.Banner(config.Version)

	if err := system.RequireRoot(); err != nil {
		tui.Fatal(err)
	}
	if err := system.RequireUbuntu("20", "22", "24"); err != nil {
		tui.Fatal(err)
	}

	// === Coleta entradas ===
	key := strings.ToUpper(tui.Prompt("Informe sua KEY (XSP-XXXX-XXXX-XXXX-XXXX): "))
	if !strings.HasPrefix(key, "XSP-") || len(key) < 19 {
		tui.Fatal(fmt.Errorf("KEY inválida"))
	}
	domain := tui.Prompt("Domínio público (ex: painel.seudominio.com): ")
	if _, err := url.Parse("https://" + domain); err != nil || domain == "" {
		tui.Fatal(fmt.Errorf("domínio inválido"))
	}
	email := tui.Prompt("E-mail do administrador: ")
	if !strings.Contains(email, "@") {
		tui.Fatal(fmt.Errorf("email inválido"))
	}

	// === Pré-checagens ===
	tui.Step("Verificando portas...")
	if busy := system.ScanPortsBusy(80, 443); len(busy) > 0 {
		tui.Fatal(fmt.Errorf("portas ocupadas: %v — libere antes de continuar", busy))
	}

	tui.Step("Calculando fingerprint da máquina...")
	hwid, parts := system.ComputeHWID()
	osName, osVer := system.DetectOS()

	// === Ativação ===
	tui.Step("Ativando licença na API...")
	cli := api.New(config.APIBaseURL, config.HMACPublicSecret)
	resp, err := cli.Activate(api.ActivateReq{
		Key: key, HWID: hwid, Hostname: system.Hostname(),
		PublicIP: system.PublicIP(), Domain: domain, Email: email,
		OS: osName, OSVersion: osVer,
		PanelVersion: config.Version, InstallerVersion: config.Version,
		Fingerprint: parts,
	})
	if err != nil {
		tui.Fatal(fmt.Errorf("ativação falhou: %w", err))
	}
	tui.Success("Licença ativa até %s", resp.ExpiresAt.Format("02/01/2006 15:04"))

	// === Docker ===
	tui.Step("Instalando Docker (se necessário)...")
	if err := docker.EnsureInstalled(); err != nil {
		tui.Fatal(err)
	}

	tui.Step("Autenticando no registry privado...")
	if err := docker.Login(config.RegistryURL, "license", resp.RegistryToken); err != nil {
		tui.Fatal(err)
	}

	// === Baixa imagens ===
	tui.Step("Baixando imagens Docker...")
	images := extractImages(resp.Manifest)
	for _, img := range images {
		fmt.Printf("  • %s\n", img.Ref)
		if err := docker.Pull(img.Ref); err != nil {
			tui.Fatal(err)
		}
		if err := docker.VerifyDigest(img.Ref, img.SHA256); err != nil {
			tui.Fatal(err)
		}
	}

	// === Gera config ===
	tui.Step("Gerando configuração em %s...", config.InstallPath)
	if err := os.MkdirAll(config.InstallPath, 0750); err != nil {
		tui.Fatal(err)
	}
	dbRoot, _ := randomHex(16)
	dbPass, _ := randomHex(16)
	publicSecret := config.HMACPublicSecret // mesmo que o instalador

	envData := map[string]string{
		"LICENSE_KEY":         key,
		"INSTALLATION_ID":     resp.InstallationID,
		"PUBLIC_SECRET":       publicSecret,
		"PANEL_VERSION":       config.Version,
		"PANEL_DOMAIN":        domain,
		"PANEL_EMAIL":         email,
		"DB_NAME":             "xsp_panel",
		"DB_USER":             "xsp",
		"DB_PASS":             dbPass,
		"DB_ROOT_PASS":        dbRoot,
		"REGISTRY_URL":        config.RegistryURL,
		"PANEL_IMAGE":         firstImageRef(images, "panel"),
		"NGINX_IMAGE":         firstImageRef(images, "nginx"),
		"DB_IMAGE":            "mariadb:11",
		"ED25519_PUBKEY_B64":  config.Ed25519PublicKeyB64,
		"API_BASE_URL":        config.APIBaseURL,
		"MASTER_KEY_SEALED":   resp.MasterKeySealed,
		"MASTER_KEY_NONCE":    resp.MasterKeyNonce,
	}
	if err := writeEnv(filepath.Join(config.InstallPath, ".env"), envData); err != nil {
		tui.Fatal(err)
	}
	if err := writeFile(filepath.Join(config.InstallPath, "docker-compose.yml"),
		composeYAML); err != nil {
		tui.Fatal(err)
	}
	if err := writeFile(filepath.Join(config.InstallPath, "license.key"), key+"\n"); err != nil {
		tui.Fatal(err)
	}

	// === Sobe stack ===
	tui.Step("Subindo containers...")
	if err := docker.ComposeUp(config.InstallPath); err != nil {
		tui.Fatal(err)
	}

	// === Health check ===
	tui.Step("Aguardando painel ficar pronto (até 90s)...")
	if err := system.HealthCheck("http://localhost/healthz", 90); err != nil {
		tui.Fatal(fmt.Errorf("painel não respondeu: %w", err))
	}

	tui.Success("Instalação concluída!")
	fmt.Println()
	fmt.Printf("  Painel: https://%s\n", domain)
	fmt.Printf("  Admin:  configure em https://%s/admin\n", domain)
	fmt.Printf("  Logs:   docker compose -f %s/docker-compose.yml logs -f\n", config.InstallPath)
	fmt.Println()
}

type imgRef struct {
	Ref    string `json:"ref"`
	SHA256 string `json:"sha256"`
	Name   string
}

func extractImages(manifest map[string]any) []imgRef {
	imgs, _ := manifest["images"].([]any)
	var out []imgRef
	for _, x := range imgs {
		m, ok := x.(map[string]any)
		if !ok {
			continue
		}
		ref, _ := m["ref"].(string)
		sum, _ := m["sha256"].(string)
		if ref == "" {
			continue
		}
		name := ref
		if i := strings.LastIndex(ref, "/"); i >= 0 {
			name = ref[i+1:]
		}
		if i := strings.Index(name, ":"); i >= 0 {
			name = name[:i]
		}
		out = append(out, imgRef{Ref: ref, SHA256: sum, Name: name})
	}
	return out
}

func firstImageRef(list []imgRef, contains string) string {
	for _, im := range list {
		if strings.Contains(im.Name, contains) {
			return im.Ref
		}
	}
	if len(list) > 0 {
		return list[0].Ref
	}
	return ""
}

func writeEnv(path string, m map[string]string) error {
	var sb strings.Builder
	sb.WriteString("# Gerado pelo instalador XSP. Não edite manualmente.\n")
	for k, v := range m {
		sb.WriteString(k)
		sb.WriteString("=")
		sb.WriteString(v)
		sb.WriteString("\n")
	}
	return os.WriteFile(path, []byte(sb.String()), 0600)
}

func writeFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0640)
}

func randomHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

const composeYAML = `services:
  panel:
    image: ${PANEL_IMAGE}
    restart: unless-stopped
    env_file: .env
    environment:
      XSP_LICENSE_KEY: ${LICENSE_KEY}
      XSP_INSTALLATION_ID: ${INSTALLATION_ID}
      XSP_PUBLIC_SECRET: ${PUBLIC_SECRET}
      XSP_VERSION: ${PANEL_VERSION}
      XSP_API_BASE: ${API_BASE_URL}
      XSP_MASTER_KEY_SEALED: ${MASTER_KEY_SEALED}
      XSP_MASTER_KEY_NONCE: ${MASTER_KEY_NONCE}
      DB_HOST: db
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASS: ${DB_PASS}
    volumes:
      - /etc/machine-id:/etc/machine-id:ro
      - xsp_state:/var/lib/xsp
      - xsp_uploads:/var/www/html/uploads
    depends_on:
      db:
        condition: service_healthy
    security_opt: ["no-new-privileges:true"]
    cap_drop: ["ALL"]
    cap_add: ["NET_BIND_SERVICE", "CHOWN", "SETUID", "SETGID"]
    networks: [xsp]

  db:
    image: ${DB_IMAGE}
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASS}
      MARIADB_DATABASE: ${DB_NAME}
      MARIADB_USER: ${DB_USER}
      MARIADB_PASSWORD: ${DB_PASS}
    volumes:
      - dbdata:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      retries: 20
    networks: [xsp]

  nginx:
    image: ${NGINX_IMAGE}
    restart: unless-stopped
    ports: ["80:80", "443:443"]
    volumes:
      - ./certs:/etc/nginx/certs:ro
    depends_on: [panel]
    networks: [xsp]

volumes:
  xsp_state:
  xsp_uploads:
  dbdata:

networks:
  xsp:
`
