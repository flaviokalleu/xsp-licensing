// install-server.go — XSP Licensing: instalador do servidor central.
// Binário único: bundle.zip embutido contém todos os arquivos do stack.
//
// Build (rode do diretório licensing/):
//   Windows: .\build-installer.ps1
//   Linux:   make build-installer
package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// bundle.zip é gerado pelo build-installer.ps1 / Makefile antes de compilar.
//
//go:embed bundle.zip
var bundleZip []byte

// extractFiles extrai bundle.zip para o diretório atual.
// Pula .env e htpasswd (gerados com segredos únicos durante a instalação).
func extractFiles() {
	skip := map[string]bool{
		".env":                      true,
		"api-license/auth/htpasswd": true,
	}
	r, err := zip.NewReader(bytes.NewReader(bundleZip), int64(len(bundleZip)))
	if err != nil {
		die("bundle.zip inválido: " + err.Error())
	}
	for _, f := range r.File {
		// Normaliza separadores: PowerShell no Windows grava zip com '\' em vez de '/'
		cleanName := strings.ReplaceAll(f.Name, "\\", "/")
		name := filepath.FromSlash(cleanName)
		if f.FileInfo().IsDir() {
			os.MkdirAll(name, 0755)
			continue
		}
		if skip[cleanName] {
			continue
		}
		os.MkdirAll(filepath.Dir(name), 0755)
		rc, err := f.Open()
		if err != nil {
			continue
		}
		data, _ := io.ReadAll(rc)
		rc.Close()
		perm := os.FileMode(0644)
		if strings.HasSuffix(cleanName, ".sh") || strings.HasSuffix(cleanName, ".py") {
			perm = 0755
		}
		os.WriteFile(name, data, perm)
	}
}

// ── cores ANSI ────────────────────────────────────────────────────────────────
const (
	clrRed = "\033[1;31m"
	clrGrn = "\033[1;32m"
	clrYel = "\033[1;33m"
	clrCyn = "\033[1;36m"
	clrNC  = "\033[0m"
)

func step(msg string) { fmt.Printf("%s→%s %s\n", clrCyn, clrNC, msg) }
func ok(msg string)   { fmt.Printf("%s✓%s %s\n", clrGrn, clrNC, msg) }
func warn(msg string) { fmt.Printf("%s⚠%s  %s\n", clrYel, clrNC, msg) }
func die(msg string)  { fmt.Fprintf(os.Stderr, "%s✗ ERRO:%s %s\n", clrRed, clrNC, msg); os.Exit(1) }

// ── Caddyfiles embutidos ──────────────────────────────────────────────────────

const caddyMultiSubdominio = `###############################################################################
#  XSP — Caddyfile multi-subdomínio (modo S)
###############################################################################
{
    email {$ACME_EMAIL}
}

{$API_HOST} {
    encode gzip zstd
    reverse_proxy api:8443 {
        health_uri /healthz
        health_interval 15s
    }
    log { output stdout; format console }
}

{$ADM_HOST} {
    encode gzip zstd
    reverse_proxy admin:80
}

{$PORTAL_HOST} {
    encode gzip zstd
    reverse_proxy portal:80
}

{$REG_HOST} {
    reverse_proxy registry:5000 {
        header_up X-Forwarded-Proto {scheme}
    }
}

{$PUBLIC_HOST} {
    encode gzip
    root * /srv
    @install path /install.sh
    header @install Content-Type "text/x-shellscript; charset=utf-8"
    file_server
    try_files {path} {path}.html /index.html
}
`

const caddyDominioUnico = `###############################################################################
#  XSP — Caddyfile domínio único, paths (modo U)
###############################################################################
{
    email {$ACME_EMAIL}
}

{$PUBLIC_HOST} {
    encode gzip zstd

    handle_path /api/* {
        reverse_proxy api:8443 {
            health_uri /healthz
            health_interval 15s
        }
    }

    handle_path /admin/* {
        reverse_proxy admin:80
    }

    handle_path /portal/* {
        reverse_proxy portal:80
    }

    handle {
        root * /srv
        @install path /install.sh
        header @install Content-Type "text/x-shellscript; charset=utf-8"
        file_server
        try_files {path} {path}.html /index.html
    }

    log { output stdout; format console }
}

{$PUBLIC_HOST}:5000 {
    reverse_proxy registry:5000 {
        header_up X-Forwarded-Proto {scheme}
    }
}
`

const caddyIP = `###############################################################################
#  XSP — Caddyfile modo IP / HTTP (modo I)
###############################################################################
{
    auto_https off
}

:80 {
    encode gzip
    root * /srv
    @install path /install.sh
    header @install Content-Type "text/x-shellscript; charset=utf-8"
    file_server
    try_files {path} {path}.html /index.html
}

:8080 {
    encode gzip zstd
    reverse_proxy api:8443 {
        health_uri /healthz
        health_interval 15s
    }
}

:8081 {
    encode gzip zstd
    reverse_proxy admin:80
}

:8082 {
    encode gzip zstd
    reverse_proxy portal:80
}

:5000 {
    reverse_proxy registry:5000 {
        header_up X-Forwarded-Proto {scheme}
    }
}
`

const overrideUnico = `services:
  caddy:
    ports:
      - "5000:5000"
`

const overrideIP = `services:
  caddy:
    ports:
      - "8080:8080"
      - "8081:8081"
      - "8082:8082"
      - "5000:5000"
`

// ── .env: leitura e escrita ───────────────────────────────────────────────────

type envMap map[string]string

func loadEnv(path string) envMap {
	m := make(envMap)
	f, err := os.Open(path)
	if err != nil {
		return m
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		m[strings.TrimSpace(parts[0])] = parts[1]
	}
	return m
}

func (m envMap) get(k string) string  { return m[k] }
func (m envMap) set(k, v string)      { m[k] = v }
func (m envMap) has(k string) bool    { v, ok := m[k]; return ok && v != "" }

// save preserva comentários e ordem do arquivo, só atualiza/adiciona valores
func (m envMap) save(path string) {
	data, _ := os.ReadFile(path)
	raw := strings.TrimRight(string(data), "\n")
	if raw == "" {
		raw = ""
	}
	lines := strings.Split(raw, "\n")

	written := make(map[string]bool)
	var out []string
	for _, line := range lines {
		if strings.HasPrefix(line, "#") || !strings.Contains(line, "=") {
			out = append(out, line)
			continue
		}
		k := strings.SplitN(line, "=", 2)[0]
		k = strings.TrimSpace(k)
		if v, exists := m[k]; exists {
			out = append(out, k+"="+v)
			written[k] = true
		} else {
			out = append(out, line)
		}
	}
	for k, v := range m {
		if !written[k] {
			out = append(out, k+"="+v)
		}
	}
	os.WriteFile(path, []byte(strings.Join(out, "\n")+"\n"), 0600)
}

// ── execução de comandos ──────────────────────────────────────────────────────

func run(args ...string) error {
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func runSh(sh string) error {
	return run("sh", "-c", sh)
}

// quiet roda sem mostrar saída; retorna true se exitcode 0
func quiet(args ...string) bool {
	return exec.Command(args[0], args[1:]...).Run() == nil
}

func capture(args ...string) string {
	out, _ := exec.Command(args[0], args[1:]...).Output()
	return strings.TrimSpace(string(out))
}

// ── prompt interativo ─────────────────────────────────────────────────────────

var stdin = bufio.NewReader(os.Stdin)

func prompt(label, def string) string {
	if def != "" {
		fmt.Printf("  %s [%s]: ", label, def)
	} else {
		fmt.Printf("  %s: ", label)
	}
	line, _ := stdin.ReadString('\n')
	line = strings.TrimSpace(line)
	if line == "" {
		return def
	}
	return line
}

// ── geração de segredos (stdlib pura) ────────────────────────────────────────

func randHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		die("crypto/rand falhou: " + err.Error())
	}
	return hex.EncodeToString(b)
}

func randB64URL(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// buildSecrets retorna mapa com todos os segredos gerados e a senha admin em claro
func buildSecrets() (envMap, string) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		die("Ed25519 GenerateKey: " + err.Error())
	}
	adminPassClear := randHex(12) // mostrada uma vez; PHP aceita plaintext se não começa com $2y$
	return envMap{
		"HMAC_PUBLIC_SECRET":       randHex(32),
		"JWT_SECRET":               randHex(32),
		"ADMIN_TOKEN":              randB64URL(32),
		"RELEASE_MASTER_KEY":       randHex(32),
		"ED25519_PRIVATE_KEY_B64":  base64.StdEncoding.EncodeToString(priv),
		"ED25519_PUBLIC_KEY_B64":   base64.StdEncoding.EncodeToString(pub),
		"DB_PASS":                  randHex(16),
		"REG_PASS":                 randHex(16),
		"ADMIN_DASH_PASS":          adminPassClear,
	}, adminPassClear
}

// genHtpasswd gera api-license/auth/htpasswd via container httpd
func genHtpasswd(user, pass string) error {
	os.MkdirAll("api-license/auth", 0755)
	out, err := exec.Command("docker", "run", "--rm",
		"httpd:2-alpine", "htpasswd", "-Bbn", user, pass).Output()
	if err != nil {
		return err
	}
	return os.WriteFile("api-license/auth/htpasswd", out, 0640)
}

// ── detecção de IP público ────────────────────────────────────────────────────

func publicIP() string {
	for _, svc := range []string{"https://ifconfig.me", "https://api.ipify.org"} {
		if ip := capture("curl", "-s", "--max-time", "5", svc); ip != "" {
			return ip
		}
	}
	raw := capture("hostname", "-I")
	return strings.Fields(raw)[0]
}

// ── backupFile ────────────────────────────────────────────────────────────────

func backupFile(path string) {
	if data, err := os.ReadFile(path); err == nil {
		os.WriteFile(path+".bak", data, 0644)
	}
}

// ── personaliza install-painel.sh para www-public/ ───────────────────────────

func personalizeInstallSh(env envMap) error {
	data, err := os.ReadFile("install-painel.sh")
	if err != nil {
		return err
	}
	proto := "https"
	if env.get("ACCESS_MODE") == "I" {
		proto = "http"
	}
	apiH := env.get("API_HOST")
	regH := env.get("REG_HOST")
	hmac := env.get("HMAC_PUBLIC_SECRET")

	content := string(data)
	content = strings.ReplaceAll(content, "__HMAC_PUBLIC_SECRET_64_HEX_CHARS__", hmac)
	content = strings.ReplaceAll(content, "https://license.seudominio.com", proto+"://"+apiH)
	content = strings.ReplaceAll(content, "registry.seudominio.com", regH)
	content = strings.ReplaceAll(content, "__INSTALL_URL__", proto+"://"+env.get("PUBLIC_HOST")+"/install.sh")
	return os.WriteFile("www-public/install.sh", []byte(content), 0755)
}

// ── resumo final ──────────────────────────────────────────────────────────────

func printSummary(env envMap, adminPassClear string, showPass bool) {
	mode    := env.get("ACCESS_MODE")
	pubH    := env.get("PUBLIC_HOST")
	apiH    := env.get("API_HOST")
	admH    := env.get("ADM_HOST")
	regH    := env.get("REG_HOST")
	admUser := env.get("ADM_USER")
	if admUser == "" {
		admUser = "admin"
	}

	var adminURL, apiURL, regURL, landURL, installURL string
	switch mode {
	case "I":
		adminURL   = "http://" + admH
		apiURL     = "http://" + apiH + "/healthz"
		regURL     = "http://" + regH
		landURL    = "http://" + pubH
		installURL = "http://" + pubH + "/install.sh"
	case "U":
		adminURL   = "https://" + pubH + "/admin/"
		apiURL     = "https://" + pubH + "/api/healthz"
		regURL     = "https://" + regH
		landURL    = "https://" + pubH
		installURL = "https://" + pubH + "/install.sh"
	default: // S
		adminURL   = "https://" + admH
		apiURL     = "https://" + apiH + "/healthz"
		regURL     = "https://" + regH
		landURL    = "https://" + pubH
		installURL = "https://" + pubH + "/install.sh"
	}

	fmt.Println()
	fmt.Printf("%s══════════════════════════════════════════════════════════════════%s\n", clrGrn, clrNC)
	fmt.Printf("%s  XSP LICENSING — instalação concluída.%s\n", clrGrn, clrNC)
	fmt.Printf("%s══════════════════════════════════════════════════════════════════%s\n", clrGrn, clrNC)
	fmt.Println()
	fmt.Printf("  %sAdmin Dashboard:%s     %s\n", clrCyn, clrNC, adminURL)
	fmt.Printf("    usuário: %s\n", admUser)
	if showPass {
		fmt.Printf("    senha:   %s%s%s\n", clrGrn, adminPassClear, clrNC)
	} else {
		fmt.Println("    senha:   (definida no .env como ADMIN_DASH_PASS)")
	}
	fmt.Println()
	fmt.Printf("  %sAPI de Licença:%s      %s\n", clrCyn, clrNC, apiURL)
	fmt.Printf("  %sDocker Registry:%s     %s\n", clrCyn, clrNC, regURL)
	fmt.Printf("  %sLanding pública:%s     %s\n", clrCyn, clrNC, landURL)
	fmt.Println("                          (cliente acessa aqui para instalar)")
	fmt.Println()
	fmt.Printf("  %sComandos úteis:%s\n", clrYel, clrNC)
	fmt.Println("    make status            — estado dos containers")
	fmt.Println("    make logs              — logs em tempo real")
	fmt.Println("    make logs S=api        — logs de um serviço")
	fmt.Println("    make release           — empacota nova release do painel")
	fmt.Println("    make down              — para tudo")
	fmt.Println()
	fmt.Printf("  %sPróximos passos:%s\n", clrYel, clrNC)
	fmt.Println()
	fmt.Println("    1. Publique o painel (1ª vez e a cada atualização):")
	fmt.Printf("       %smake release%s\n", clrCyn, clrNC)
	fmt.Println()
	fmt.Println("    2. Acesse o admin dashboard → clique em 'Gerar KEY'")
	fmt.Printf("       %s%s%s\n", clrCyn, adminURL, clrNC)
	fmt.Println()
	fmt.Println("    3. O dashboard mostra o comando pronto para copiar e enviar ao cliente:")
	fmt.Printf("       %scurl -sSL %s | sudo bash -s -- XSP-XXXX-XXXX%s\n", clrCyn, installURL, clrNC)
	fmt.Println()
	fmt.Printf("    %s⚠ Cada KEY permite exatamente 1 instalação.%s\n", clrYel, clrNC)
	fmt.Println()
}

// inDocker detecta se está rodando dentro de um container Docker.
func inDocker() bool {
	_, err := os.Stat("/.dockerenv")
	return err == nil
}

// ── main ──────────────────────────────────────────────────────────────────────

func main() {
	fmt.Print("\033[H\033[2J") // clear
	fmt.Println(" ╔══════════════════════════════════════════════════════════════════╗")
	fmt.Println(" ║   XSP LICENSING — Servidor Central (100% Docker)                 ║")
	fmt.Println(" ║   Sobe API + Admin + DB + Redis + Registry + Caddy (TLS auto)    ║")
	fmt.Println(" ╚══════════════════════════════════════════════════════════════════╝")
	fmt.Println()

	// ── extrai arquivos embutidos para o diretório atual ────────────────────
	step("Extraindo arquivos do pacote...")
	extractFiles()
	ok("Arquivos extraídos.")

	// ── pré-condições ────────────────────────────────────────────────────────
	if os.Getuid() != 0 {
		die("Rode como root: sudo ./install-server  |  docker run ... (veja README)")
	}
	// Dentro de container Docker pulamos checagem de OS do host
	if !inDocker() {
		osID := capture("sh", "-c", `. /etc/os-release && echo $ID`)
		if osID != "ubuntu" && osID != "debian" {
			die("SO não suportado: " + osID + " (requer ubuntu ou debian)")
		}
	}

	// ── .env: carrega ou cria ────────────────────────────────────────────────
	env := loadEnv(".env")
	mode := env.get("ACCESS_MODE")

	if mode == "" {
		// ── coleta interativa ────────────────────────────────────────────────
		fmt.Println("Como este servidor vai ser acessado?")
		fmt.Println("  [S] Subdomínios separados com TLS  — recomendado para produção")
		fmt.Println("  [U] Um único domínio (paths /api, /admin...) + registry na porta 5000")
		fmt.Println("  [I] Somente IP, sem TLS (HTTP)     — para testes locais")
		fmt.Println()

		for {
			mode = strings.ToUpper(prompt("Escolha [S/U/I]", "S"))
			if mode == "S" || mode == "U" || mode == "I" {
				break
			}
			warn("Opção inválida. Digite S, U ou I.")
		}

		switch mode {
		case "I":
			warn("Modo IP: sem TLS. Não use em produção com dados reais.")
			fmt.Println()
			ip := publicIP()
			ip = prompt("IP público da VPS", ip)
			if ip == "" {
				die("IP obrigatório.")
			}
			env.set("PUBLIC_HOST", ip)
			env.set("API_HOST", ip+":8080")
			env.set("ADM_HOST", ip+":8081")
			env.set("PORTAL_HOST", ip+":8082")
			env.set("REG_HOST", ip+":5000")
			env.set("ACME_EMAIL", "noreply@localhost")

		case "U":
			fmt.Println("Informe o domínio único que aponta para esta VPS:")
			ph := prompt("Domínio (ex: painel.seudominio.com)", "")
			ae := prompt("E-mail Let's Encrypt", "")
			if ph == "" {
				die("Domínio obrigatório.")
			}
			if ae == "" {
				die("E-mail obrigatório.")
			}
			env.set("PUBLIC_HOST", ph)
			env.set("API_HOST", ph+"/api") // API_BASE no builder = https://dominio/api
			env.set("ADM_HOST", ph)
			env.set("PORTAL_HOST", ph)
			env.set("REG_HOST", ph+":5000")
			env.set("ACME_EMAIL", ae)

		default: // S
			fmt.Println("Configure os domínios (DEVEM já apontar para esta VPS):")
			apiH := prompt("API           (ex: license.seudominio.com)", "")
			admH := prompt("Admin         (ex: admin.seudominio.com)", "")
			porH := prompt("Portal        (ex: minha.seudominio.com)", "")
			regH := prompt("Registry      (ex: registry.seudominio.com)", "")
			pubH := prompt("Landing/inst. (ex: seudominio.com)", "")
			acme := prompt("E-mail Let's Encrypt", "")
			for _, v := range []string{apiH, admH, porH, regH, pubH, acme} {
				if v == "" {
					die("Todos os campos são obrigatórios.")
				}
			}
			env.set("API_HOST", apiH)
			env.set("ADM_HOST", admH)
			env.set("PORTAL_HOST", porH)
			env.set("REG_HOST", regH)
			env.set("PUBLIC_HOST", pubH)
			env.set("ACME_EMAIL", acme)
		}

		admUser := prompt("Usuário admin-dashboard", "admin")
		env.set("ADM_USER", admUser)
		env.set("REG_USER", "license")
		env.set("ACCESS_MODE", mode)
		env.set("PANEL_VERSION", "10.0.3")

		// INSTALL_URL: URL pública do install.sh (usada pelo admin dashboard)
		proto := "https"
		if mode == "I" {
			proto = "http"
		}
		env.set("API_SCHEME", proto)
		env.set("INSTALL_URL", proto+"://"+env.get("PUBLIC_HOST")+"/install.sh")
		collected := env

		// copia .env.example como base se .env não existir
		if _, err := os.Stat(".env"); err != nil {
			if src, err := os.ReadFile(".env.example"); err == nil {
				os.WriteFile(".env", src, 0600)
				env = loadEnv(".env") // recarrega para preservar comentários
				// reaplica as entradas coletadas
				for k, v := range map[string]string{
					"ACCESS_MODE": mode, "ADM_USER": admUser, "REG_USER": "license", "PANEL_VERSION": "10.0.3",
					"PUBLIC_HOST": collected.get("PUBLIC_HOST"), "API_HOST": collected.get("API_HOST"),
					"ADM_HOST": collected.get("ADM_HOST"), "PORTAL_HOST": collected.get("PORTAL_HOST"),
					"REG_HOST": collected.get("REG_HOST"), "ACME_EMAIL": collected.get("ACME_EMAIL"),
					"API_SCHEME": collected.get("API_SCHEME"), "INSTALL_URL": collected.get("INSTALL_URL"),
				} {
					env.set(k, v)
				}
			}
		}
		env.save(".env")
		ok(".env inicializado (modo: " + mode + ").")
	} else {
		ok("Configuração já encontrada no .env (modo: " + mode + "). Pulando coleta.")
	}
	if !env.has("API_SCHEME") {
		proto := "https"
		if mode == "I" {
			proto = "http"
		}
		env.set("API_SCHEME", proto)
	}
	if !env.has("INSTALL_URL") && env.get("PUBLIC_HOST") != "" {
		env.set("INSTALL_URL", env.get("API_SCHEME")+"://"+env.get("PUBLIC_HOST")+"/install.sh")
	}

	// ── Docker ──────────────────────────────────────────────────────────────
	if _, err := exec.LookPath("docker"); err != nil {
		step("Instalando Docker...")
		if err := runSh("curl -fsSL https://get.docker.com | sh"); err != nil {
			die("Falha ao instalar Docker.")
		}
		run("systemctl", "enable", "--now", "docker")
		ok("Docker instalado.")
	} else {
		ok("Docker já presente.")
	}
	if !quiet("docker", "compose", "version") {
		runSh("apt-get install -y -qq docker-compose-plugin")
	}

	// ── Firewall (só no host, não dentro de container) ───────────────────────
	if !inDocker() {
		if _, err := exec.LookPath("ufw"); err == nil {
			step("Configurando firewall...")
			run("ufw", "--force", "reset")
			run("ufw", "default", "deny", "incoming")
			run("ufw", "default", "allow", "outgoing")
			run("ufw", "allow", "OpenSSH")
			run("ufw", "allow", "80/tcp")
			run("ufw", "allow", "443/tcp")
			switch mode {
			case "U":
				run("ufw", "allow", "5000/tcp")
				ok("UFW ativo (22, 80, 443, 5000).")
			case "I":
				run("ufw", "allow", "8080/tcp")
				run("ufw", "allow", "8081/tcp")
				run("ufw", "allow", "8082/tcp")
				run("ufw", "allow", "5000/tcp")
				ok("UFW ativo (22, 80, 8080, 8081, 8082, 5000).")
			default:
				ok("UFW ativo (22, 80, 443).")
			}
			run("ufw", "--force", "enable")
		}
	}

	// ── Segredos (idempotente) ────────────────────────────────────────────────
	step("Gerando segredos...")
	secrets, adminPassClear := buildSecrets()
	showPass := false
	for k, v := range secrets {
		if !env.has(k) {
			env.set(k, v)
			if k == "ADMIN_DASH_PASS" {
				showPass = true
			}
			fmt.Printf("  %s+%s %s\n", clrGrn, clrNC, k)
		} else {
			fmt.Printf("  · %s (já existia)\n", k)
		}
	}
	env.save(".env")

	if showPass {
		fmt.Println()
		fmt.Printf("  %s▶ SENHA DO ADMIN-DASHBOARD: %s%s\n", clrGrn, adminPassClear, clrNC)
		fmt.Println("    (anote agora — não será mostrada de novo)")
		fmt.Println()
	}

	// htpasswd do registry
	if _, err := os.Stat("api-license/auth/htpasswd"); err != nil {
		step("Gerando htpasswd do registry...")
		regUser := env.get("REG_USER")
		if regUser == "" {
			regUser = "license"
		}
		if err := genHtpasswd(regUser, env.get("REG_PASS")); err != nil {
			die("Falha ao gerar htpasswd: " + err.Error())
		}
		ok("api-license/auth/htpasswd gerado.")
	}

	// ── Caddyfile por modo ────────────────────────────────────────────────────
	switch mode {
	case "U":
		step("Gerando Caddyfile (domínio único, paths + registry :5000)...")
		backupFile("Caddyfile")
		os.WriteFile("Caddyfile", []byte(caddyDominioUnico), 0644)
		os.WriteFile("docker-compose.override.yml", []byte(overrideUnico), 0644)
		ok("Caddyfile e docker-compose.override.yml prontos.")
	case "I":
		step("Gerando Caddyfile (IP / HTTP, portas separadas)...")
		backupFile("Caddyfile")
		os.WriteFile("Caddyfile", []byte(caddyIP), 0644)
		os.WriteFile("docker-compose.override.yml", []byte(overrideIP), 0644)
		ok("Caddyfile e docker-compose.override.yml prontos.")
	default: // S — Caddyfile original usa variáveis de ambiente; nada a fazer
		os.Remove("docker-compose.override.yml")
	}

	// ── www-public ────────────────────────────────────────────────────────────
	step("Preparando landing pública...")
	os.MkdirAll("www-public", 0755)
	if data, err := os.ReadFile("landing/index.html"); err == nil {
		os.WriteFile("www-public/index.html", data, 0644)
	}
	if err := personalizeInstallSh(env); err != nil {
		warn("Não foi possível gerar www-public/install.sh: " + err.Error())
	} else {
		ok("install.sh personalizado em www-public/")
	}

	// ── Stack Docker ──────────────────────────────────────────────────────────
	step("Subindo stack Docker (pode levar 2-3 min na 1ª vez)...")
	if err := run("docker", "compose", "up", "-d", "--build"); err != nil {
		die("Falha ao subir stack: " + err.Error())
	}

	// ── Aguarda API ───────────────────────────────────────────────────────────
	step("Aguardando API ficar pronta...")
	for i := range 40 {
		if quiet("docker", "compose", "exec", "-T", "api",
			"wget", "-qO-", "http://localhost:8443/healthz") {
			ok("API responde.")
			break
		}
		if i == 39 {
			die("API não subiu. Verifique: docker compose logs api")
		}
		time.Sleep(3 * time.Second)
	}

	if mode != "I" {
		step("Aguardando Caddy emitir certificados (~30s)...")
		time.Sleep(8 * time.Second)
	}

	// ── Resumo ────────────────────────────────────────────────────────────────
	printSummary(env, adminPassClear, showPass)
}
