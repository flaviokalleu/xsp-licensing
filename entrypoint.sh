#!/usr/bin/env bash
###############################################################################
#  XSP LICENSING — Instalador do servidor central
#  Roda dentro do container Docker; acessa o Docker do host via socket montado.
###############################################################################
set -uo pipefail

APP="/app"          # arquivos embutidos na imagem
WORK="${PWD}"       # diretório montado do host (-w /root)

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; CYN=$'\033[1;36m'; NC=$'\033[0m'
step() { echo "${CYN}→${NC} $*"; }
ok()   { echo "${GRN}✓${NC} $*"; }
warn() { echo "${YEL}⚠${NC}  $*"; }
die()  { echo "${RED}✗ ERRO:${NC} $*" >&2; exit 1; }

clear
cat <<'BANNER'
 ╔══════════════════════════════════════════════════════════════════╗
 ║   XSP LICENSING — Servidor Central (100% Docker)                 ║
 ║   Sobe API + Admin + DB + Redis + Registry + Caddy (TLS auto)    ║
 ╚══════════════════════════════════════════════════════════════════╝
BANNER
echo

# ── Copia arquivos do container para o diretório de trabalho do host ──────────
step "Extraindo arquivos..."
for item in api-license admin-dashboard customer-portal landing builder \
            painel-image xsp-loader docker-compose.yml Makefile \
            .env.example install-painel.sh Caddyfile; do
  src="$APP/$item"
  dst="$WORK/$item"
  [[ -e "$src" ]] || continue
  if [[ -d "$src" ]]; then
    cp -rn "$src" "$dst" 2>/dev/null || true   # -n: não sobrescreve existentes
  elif [[ ! -f "$dst" ]]; then
    cp "$src" "$dst"
  fi
done
ok "Arquivos prontos."

# ── Carrega .env existente ────────────────────────────────────────────────────
load_env() {
  [[ -f "$WORK/.env" ]] || return
  set -a
  # shellcheck disable=SC1090
  source <(grep -v '^\s*#' "$WORK/.env" | grep '=')
  set +a
}
load_env

MODE="${ACCESS_MODE:-}"

# Variáveis com defaults para evitar erros de nounset
PUBLIC_HOST="${PUBLIC_HOST:-}"
API_HOST="${API_HOST:-}"
ADM_HOST="${ADM_HOST:-}"
PORTAL_HOST="${PORTAL_HOST:-}"
REG_HOST="${REG_HOST:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
ADM_USER="${ADM_USER:-admin}"
REG_USER="${REG_USER:-license}"
PANEL_VERSION="${PANEL_VERSION:-10.0.3}"
INSTALL_URL="${INSTALL_URL:-}"

# ── Coleta interativa (só se ainda não configurado) ───────────────────────────
if [[ -z "$MODE" ]]; then
  echo "Como este servidor vai ser acessado?"
  echo "  [S] Subdomínios separados com TLS  — recomendado para produção"
  echo "  [U] Um único domínio (paths /api, /admin...) + registry na porta 5000"
  echo "  [I] Somente IP, sem TLS (HTTP)     — para testes locais"
  echo
  ask() {
    local prompt="$1" var="$2" default="${3:-}"
    printf "%s" "$prompt" >/dev/tty
    local val=""
    if [ -t 0 ]; then
      IFS= read -r val || val=""
    else
      IFS= read -r val </dev/tty 2>/dev/null || val=""
    fi
    val="${val:-$default}"
    printf -v "$var" '%s' "$val"
  }

  while true; do
    ask "  Escolha [S/U/I] (padrão I): " MODE "I"
    MODE="${MODE^^}"
    [[ "$MODE" =~ ^[SUI]$ ]] && break
    warn "Digite S, U ou I."
  done

  case "$MODE" in
    I)
      warn "Modo IP: sem TLS. Não use em produção."
      PUBLIC_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
      ask "  IP público da VPS [$PUBLIC_IP]: " inp "$PUBLIC_IP"
      PUBLIC_HOST="$inp"
      API_HOST="$PUBLIC_HOST:8080"
      ADM_HOST="$PUBLIC_HOST:8081"
      PORTAL_HOST="$PUBLIC_HOST:8082"
      REG_HOST="$PUBLIC_HOST:5000"
      ACME_EMAIL="noreply@localhost"
      INSTALL_URL="http://$PUBLIC_HOST/install.sh"
      ;;
    U)
      ask "  Domínio único (ex: painel.seudominio.com): " PUBLIC_HOST ""
      [[ -n "$PUBLIC_HOST" ]] || die "Domínio obrigatório."
      ask "  E-mail Let's Encrypt: " ACME_EMAIL ""
      [[ -n "$ACME_EMAIL" ]] || die "E-mail obrigatório."
      API_HOST="$PUBLIC_HOST/api"
      ADM_HOST="$PUBLIC_HOST"
      PORTAL_HOST="$PUBLIC_HOST"
      REG_HOST="$PUBLIC_HOST:5000"
      INSTALL_URL="https://$PUBLIC_HOST/install.sh"
      ;;
    S)
      ask "  API           (ex: license.seudominio.com): " API_HOST ""
      ask "  Admin         (ex: admin.seudominio.com): "   ADM_HOST ""
      ask "  Portal        (ex: minha.seudominio.com): "   PORTAL_HOST ""
      ask "  Registry      (ex: registry.seudominio.com): " REG_HOST ""
      ask "  Landing/inst. (ex: seudominio.com): "         PUBLIC_HOST ""
      ask "  E-mail Let's Encrypt: "                       ACME_EMAIL ""
      for v in "$API_HOST" "$ADM_HOST" "$PORTAL_HOST" "$REG_HOST" "$PUBLIC_HOST" "$ACME_EMAIL"; do
        [[ -n "$v" ]] || die "Todos os campos são obrigatórios."
      done
      INSTALL_URL="https://$PUBLIC_HOST/install.sh"
      ;;
  esac

  ask "  Usuário admin-dashboard [admin]: " ADM_USER "admin"
  REG_USER="license"
  PANEL_VERSION="10.0.3"
  ACCESS_MODE="$MODE"

  ok ".env configurado (modo: $MODE)."
else
  ok "Configuração já encontrada no .env (modo: $MODE). Pulando coleta."
fi

# ── Gera segredos (idempotente) ───────────────────────────────────────────────
step "Gerando segredos..."

rand_hex()    { openssl rand -hex "$1"; }
rand_b64url() { openssl rand -base64 "$1" | tr '+/' '-_' | tr -d '=\n'; }

gen_ed25519() {
  python3 - <<'PYEOF'
import subprocess, base64, sys
r = subprocess.run(['openssl','genpkey','-algorithm','ed25519','-outform','DER'],
                   capture_output=True)
priv_der = r.stdout               # 48-byte PKCS8
seed = priv_der[16:48]            # 32-byte seed
r2 = subprocess.run(['openssl','pkey','-inform','DER','-pubout','-outform','DER'],
                    input=priv_der, capture_output=True)
pub_der = r2.stdout               # 44-byte SubjectPublicKeyInfo
pub = pub_der[12:44]              # 32-byte raw public key
go_priv = seed + pub              # 64-byte Go ed25519.PrivateKey
print(base64.b64encode(go_priv).decode())
print(base64.b64encode(pub).decode())
PYEOF
}

ED25519_KEYS=$(gen_ed25519)
NEW_ED25519_PRIV=$(echo "$ED25519_KEYS" | sed -n '1p')
NEW_ED25519_PUB=$(echo  "$ED25519_KEYS" | sed -n '2p')

# Carrega valores existentes ou gera novos
ED25519_PRIVATE_KEY_B64="${ED25519_PRIVATE_KEY_B64:-$NEW_ED25519_PRIV}"
ED25519_PUBLIC_KEY_B64="${ED25519_PUBLIC_KEY_B64:-$NEW_ED25519_PUB}"
HMAC_PUBLIC_SECRET="${HMAC_PUBLIC_SECRET:-$(rand_hex 32)}"
JWT_SECRET="${JWT_SECRET:-$(rand_hex 32)}"
ADMIN_TOKEN="${ADMIN_TOKEN:-$(rand_b64url 32)}"
RELEASE_MASTER_KEY="${RELEASE_MASTER_KEY:-$(rand_hex 32)}"
DB_PASS="${DB_PASS:-$(rand_hex 16)}"
REG_PASS="${REG_PASS:-$(rand_hex 16)}"

SHOW_PASS=false
if [[ -z "${ADMIN_DASH_PASS:-}" ]]; then
  ADMIN_DASH_PASS=$(rand_hex 12)
  SHOW_PASS=true
fi

# ── Escreve .env ──────────────────────────────────────────────────────────────
cat > "$WORK/.env" <<ENV
# XSP Licensing — gerado pelo instalador — NÃO COMMITAR
ACCESS_MODE=${ACCESS_MODE}
PUBLIC_HOST=${PUBLIC_HOST}
API_HOST=${API_HOST}
ADM_HOST=${ADM_HOST}
PORTAL_HOST=${PORTAL_HOST}
REG_HOST=${REG_HOST}
ACME_EMAIL=${ACME_EMAIL}
ADM_USER=${ADM_USER}
REG_USER=${REG_USER}
PANEL_VERSION=${PANEL_VERSION:-10.0.3}
INSTALL_URL=${INSTALL_URL}

HMAC_PUBLIC_SECRET=${HMAC_PUBLIC_SECRET}
JWT_SECRET=${JWT_SECRET}
ADMIN_TOKEN=${ADMIN_TOKEN}
RELEASE_MASTER_KEY=${RELEASE_MASTER_KEY}
ED25519_PRIVATE_KEY_B64=${ED25519_PRIVATE_KEY_B64}
ED25519_PUBLIC_KEY_B64=${ED25519_PUBLIC_KEY_B64}
DB_PASS=${DB_PASS}
REG_PASS=${REG_PASS}
ADMIN_DASH_PASS=${ADMIN_DASH_PASS}
MP_RENEW_LINK=
ENV
chmod 600 "$WORK/.env"
ok ".env salvo."

if [[ "$SHOW_PASS" == true ]]; then
  echo
  echo "  ${GRN}▶ SENHA DO ADMIN-DASHBOARD: ${ADMIN_DASH_PASS}${NC}"
  echo "    (anote agora — não será mostrada de novo)"
  echo
fi

# ── htpasswd do registry ──────────────────────────────────────────────────────
if [[ ! -f "$WORK/api-license/auth/htpasswd" ]]; then
  step "Gerando htpasswd do registry..."
  mkdir -p "$WORK/api-license/auth"
  docker run --rm httpd:2-alpine htpasswd -Bbn "$REG_USER" "$REG_PASS" \
    > "$WORK/api-license/auth/htpasswd"
  ok "htpasswd gerado."
fi

# ── Caddyfile por modo ────────────────────────────────────────────────────────
case "$MODE" in
  U)
    step "Gerando Caddyfile (domínio único + paths)..."
    printf '%s\n' \
      '{ email {$ACME_EMAIL} }' \
      '{$PUBLIC_HOST} {' \
      '  encode gzip zstd' \
      '  handle_path /api/* {' \
      '    reverse_proxy api:8443' \
      '  }' \
      '  handle_path /admin/* {' \
      '    reverse_proxy admin:80' \
      '  }' \
      '  handle_path /portal/* {' \
      '    reverse_proxy portal:80' \
      '  }' \
      '  handle {' \
      '    root * /srv' \
      '    @inst path /install.sh' \
      '    header @inst Content-Type "text/x-shellscript; charset=utf-8"' \
      '    file_server' \
      '  }' \
      '  log { output stdout; format console }' \
      '}' \
      '{$PUBLIC_HOST}:5000 {' \
      '  reverse_proxy registry:5000' \
      '}' > "$WORK/Caddyfile"
    printf '%s\n' \
      'services:' \
      '  caddy:' \
      '    ports: ["5000:5000"]' > "$WORK/docker-compose.override.yml"
    ;;
  I)
    step "Gerando Caddyfile (IP / HTTP)..."
    printf '%s\n' \
      '{' \
      '    auto_https off' \
      '}' \
      ':80 {' \
      '    root * /srv' \
      '    @inst path /install.sh' \
      '    header @inst Content-Type "text/x-shellscript; charset=utf-8"' \
      '    file_server' \
      '}' \
      ':8080 {' \
      '    reverse_proxy api:8443' \
      '}' \
      ':8081 {' \
      '    reverse_proxy admin:80' \
      '}' \
      ':8082 {' \
      '    reverse_proxy portal:80' \
      '}' \
      ':5000 {' \
      '    reverse_proxy registry:5000' \
      '}' > "$WORK/Caddyfile"
    printf '%s\n' \
      'services:' \
      '  caddy:' \
      '    ports: ["8080:8080","8081:8081","8082:8082","5000:5000"]' > "$WORK/docker-compose.override.yml"
    ;;
  S)
    printf '%s\n' \
      '{ email {$ACME_EMAIL} }' \
      '{$API_HOST} {' \
      '  reverse_proxy api:8443' \
      '}' \
      '{$ADM_HOST} {' \
      '  reverse_proxy admin:80' \
      '}' \
      '{$PORTAL_HOST} {' \
      '  reverse_proxy portal:80' \
      '}' \
      '{$REG_HOST} {' \
      '  reverse_proxy registry:5000' \
      '}' \
      '{$PUBLIC_HOST} {' \
      '  root * /srv' \
      '  @inst path /install.sh' \
      '  header @inst Content-Type "text/x-shellscript; charset=utf-8"' \
      '  file_server' \
      '}' > "$WORK/Caddyfile"
    rm -f "$WORK/docker-compose.override.yml"
    ;;
esac
ok "Caddyfile pronto."

# ── Personaliza install.sh público ───────────────────────────────────────────
step "Personalizando install.sh..."
mkdir -p "$WORK/www-public"
[[ -f "$APP/landing/index.html" ]] && cp "$APP/landing/index.html" "$WORK/www-public/"

PROTO="https"; [[ "$MODE" == "I" ]] && PROTO="http"
sed \
  -e "s|__HMAC_PUBLIC_SECRET_64_HEX_CHARS__|${HMAC_PUBLIC_SECRET}|g" \
  -e "s|https://license.seudominio.com|${PROTO}://${API_HOST}|g" \
  -e "s|registry.seudominio.com|${REG_HOST}|g" \
  "$WORK/install-painel.sh" > "$WORK/www-public/install.sh"
chmod 755 "$WORK/www-public/install.sh"
ok "www-public/install.sh pronto."

# ── Configura insecure-registry no host (para make release e cliente HTTP) ───
REGISTRY_HOST_ONLY=$(echo "$REG_HOST" | cut -d'/' -f1)
step "Configurando insecure-registry ($REGISTRY_HOST_ONLY) no host..."
DAEMON_JSON=/etc/docker/daemon.json
if [[ -f "$DAEMON_JSON" ]]; then
  if ! python3 -c "import json,sys; d=json.load(open('$DAEMON_JSON')); sys.exit(0 if '$REGISTRY_HOST_ONLY' in d.get('insecure-registries',[]) else 1)" 2>/dev/null; then
    python3 -c "
import json
with open('$DAEMON_JSON') as f: d=json.load(f)
d.setdefault('insecure-registries',[]).append('$REGISTRY_HOST_ONLY')
with open('$DAEMON_JSON','w') as f: json.dump(d,f)
"
    docker kill -s HUP \$(docker ps -q) 2>/dev/null || true
  fi
else
  printf '{\"insecure-registries\": [\"%s\"]}\n' "$REGISTRY_HOST_ONLY" > "$DAEMON_JSON"
fi
ok "insecure-registry configurado."

# ── Sobe stack ────────────────────────────────────────────────────────────────
step "Subindo stack Docker (pode levar 2-3 min na 1ª vez)..."
cd "$WORK"
docker compose up -d --build

# ── Aguarda API ───────────────────────────────────────────────────────────────
step "Aguardando API..."
for i in $(seq 1 40); do
  docker compose exec -T api wget -qO- http://localhost:8443/healthz &>/dev/null && break
  [[ $i -eq 40 ]] && die "API não respondeu. Veja: docker compose logs api"
  sleep 3
done
ok "API respondendo."

# ── Resumo ────────────────────────────────────────────────────────────────────
echo
echo "${GRN}══════════════════════════════════════════════════════════════════${NC}"
echo "${GRN}  XSP LICENSING instalado com sucesso!${NC}"
echo "${GRN}══════════════════════════════════════════════════════════════════${NC}"
echo
case "$MODE" in
  I) echo "  ${CYN}Admin:${NC}    http://$ADM_HOST"
     echo "  ${CYN}API:${NC}      http://$API_HOST/healthz" ;;
  U) echo "  ${CYN}Admin:${NC}    https://$PUBLIC_HOST/admin/"
     echo "  ${CYN}API:${NC}      https://$PUBLIC_HOST/api/healthz" ;;
  S) echo "  ${CYN}Admin:${NC}    https://$ADM_HOST"
     echo "  ${CYN}API:${NC}      https://$API_HOST/healthz" ;;
esac
echo "  ${CYN}Usuário:${NC}  $ADM_USER"
echo
echo "  ${YEL}Comandos úteis (rode no diretório /root):${NC}"
echo "    docker compose ps          — estado dos containers"
echo "    docker compose logs -f     — logs em tempo real"
echo "    docker compose restart     — reinicia tudo"
echo
echo "  ${YEL}Próximos passos:${NC}"
echo "    1. Acesse o admin → crie uma KEY"
echo "    2. Envie o comando de instalação ao cliente"
echo "    3. Para publicar o painel: make release"
echo
