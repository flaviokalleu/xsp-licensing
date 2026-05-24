#!/usr/bin/env bash
###############################################################################
#  XSP — Instalador AUTOMÁTICO do Servidor Central (TUDO EM DOCKER)
#
#  O que faz:
#    1. Instala Docker (se ainda não tiver)
#    2. Configura firewall (80, 443, SSH)
#    3. Gera todos os segredos
#    4. Sobe o stack inteiro via docker compose:
#         caddy + api + admin + db + redis + registry
#    5. Hospeda a landing page + install.sh personalizado
#
#  NADA é instalado no host além do Docker. Tudo roda em containers.
#
#  Uso: cd licensing/ && sudo bash install-server.sh
###############################################################################
set -euo pipefail

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; CYN=$'\033[1;36m'; NC=$'\033[0m'
step() { echo "${CYN}→${NC} $*"; }
ok()   { echo "${GRN}✓${NC} $*"; }
warn() { echo "${YEL}⚠${NC} $*"; }
die()  { echo "${RED}✗ ERRO:${NC} $*" >&2; exit 1; }

clear
cat <<'BANNER'
 ╔══════════════════════════════════════════════════════════════════╗
 ║   XSP LICENSING — Servidor Central (100% Docker)                 ║
 ║   Sobe API + Admin + DB + Redis + Registry + Caddy (TLS auto)    ║
 ╚══════════════════════════════════════════════════════════════════╝
BANNER
echo

[[ $EUID -eq 0 ]] || die "Rode como root: sudo bash $0"
[[ -f /etc/os-release ]] || die "Sistema sem /etc/os-release."
. /etc/os-release
[[ "$ID" =~ ^(ubuntu|debian)$ ]] || die "SO não suportado: $ID."

[[ -f docker-compose.yml && -d api-license ]] \
  || die "Rode este script dentro do diretório 'licensing/'."

step "Instalando dependencias do instalador..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl openssl python3 >/dev/null
ok "Dependencias do instalador prontas."

# Carrega .env existente → permite re-execução e instalação não-interativa
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1090
  source <(grep -vE '^\s*#|^\s*$' .env 2>/dev/null) 2>/dev/null || true
  set +a
fi

SERVER_HOST_INPUT="${XSP_SERVER_HOST:-${1:-}}"
SERVER_EMAIL_INPUT="${XSP_SERVER_EMAIL:-${2:-}}"
ADMIN_USER_INPUT="${XSP_ADMIN_USER:-}"

normalize_host() {
  local host="$1"
  host="${host#http://}"
  host="${host#https://}"
  host="${host%%/*}"
  printf '%s' "$host"
}

is_ip_host() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$1" == *:* ]]
}

random_suffix() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 4
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    tr -d '-' </proc/sys/kernel/random/uuid | head -c 8
    echo
  else
    printf '%08x\n' "$((RANDOM * RANDOM))"
  fi
}

default_email_for_host() {
  local host="$1"
  local domain="$host"
  is_ip_host "$domain" && domain="xsp.local"
  printf 'admin-%s@%s' "$(random_suffix)" "$domain"
}

configure_from_host() {
  SERVER_HOST_INPUT="$(normalize_host "$SERVER_HOST_INPUT")"
  [[ -n "$SERVER_HOST_INPUT" ]] || return 1

  if is_ip_host "$SERVER_HOST_INPUT"; then
    warn "Modo IP: sem TLS. Nao use em producao com dados reais."
    ACCESS_MODE="I"
    PUBLIC_HOST="${SERVER_HOST_INPUT}"
    API_HOST="${SERVER_HOST_INPUT}:8080"
    ADM_HOST="${SERVER_HOST_INPUT}:8081"
    PORTAL_HOST="${SERVER_HOST_INPUT}:8082"
    REG_HOST="${SERVER_HOST_INPUT}:5000"
    ACME_EMAIL="${SERVER_EMAIL_INPUT:-$(default_email_for_host "$SERVER_HOST_INPUT")}"
  else
    ACCESS_MODE="U"
    PUBLIC_HOST="${SERVER_HOST_INPUT}"
    API_HOST="${SERVER_HOST_INPUT}/api"
    ADM_HOST="${SERVER_HOST_INPUT}"
    PORTAL_HOST="${SERVER_HOST_INPUT}"
    REG_HOST="${SERVER_HOST_INPUT}:5000"
    ACME_EMAIL="${SERVER_EMAIL_INPUT:-$(default_email_for_host "$SERVER_HOST_INPUT")}"
  fi

  [[ "$ACME_EMAIL" =~ @ ]] || die "E-mail invalido: $ACME_EMAIL"
  ADM_USER="${ADMIN_USER_INPUT:-admin}"
  ok "Configuracao automatica: host=${PUBLIC_HOST}, modo=${ACCESS_MODE}."
  return 0
}

env_value() {
  grep "^${1}=" .env 2>/dev/null | cut -d= -f2- || true
}

validate_required_env() {
  local missing=0
  local required=(
    ACCESS_MODE PUBLIC_HOST API_HOST ADM_HOST PORTAL_HOST REG_HOST ACME_EMAIL ADM_USER
    DB_PASS REG_PASS ADMIN_DASH_PASS HMAC_PUBLIC_SECRET JWT_SECRET ADMIN_TOKEN
    RELEASE_MASTER_KEY ED25519_PRIVATE_KEY_B64 ED25519_PUBLIC_KEY_B64
  )
  for k in "${required[@]}"; do
    if [[ -z "$(env_value "$k")" ]]; then
      echo "  - $k vazio ou ausente" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || die ".env incompleto. Corrija os campos acima e rode novamente."
}

show_compose_debug() {
  warn "Diagnostico Docker:"
  docker compose ps || true
  echo
  warn "Logs do banco:"
  docker compose logs --tail=160 db || true
}

recover_failed_db_volume() {
  [[ ! -f .xsp-install-complete ]] || return 1
  local cid state health
  cid=$(docker compose ps -aq db 2>/dev/null || true)
  [[ -n "$cid" ]] || return 1
  state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || true)
  health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" 2>/dev/null || true)
  [[ "$state" =~ ^(exited|dead)$ || "$health" == "unhealthy" ]] || return 1

  warn "Banco de uma instalacao incompleta ficou quebrado (${state}/${health}); recriando volume pgdata."
  docker logs --tail=80 "$cid" || true
  docker compose rm -fs db >/dev/null 2>&1 || true
  docker volume rm xsp-licensing_pgdata >/dev/null 2>&1 || true
  return 0
}

compose_up_or_die() {
  recover_failed_db_volume || true
  if COMPOSE_PROGRESS=plain docker compose up -d --build; then
    return
  fi

  show_compose_debug
  if recover_failed_db_volume; then
    step "Tentando subir o stack novamente com banco limpo..."
    if COMPOSE_PROGRESS=plain docker compose up -d --build; then
      return
    fi
    show_compose_debug
  fi
  die "docker compose falhou. Veja os logs acima."
}

# ─── coleta de entradas ──────────────────────────────────────────────────────
if [[ ! -f .env ]] || ! grep -q "^API_HOST=" .env 2>/dev/null; then

  AUTO_CONFIG=0
  if configure_from_host; then
    AUTO_CONFIG=1
  fi

  if [[ "$AUTO_CONFIG" -eq 0 ]]; then
  echo "Como este servidor vai ser acessado?"
  echo "  [S] Subdomínios separados com TLS  — recomendado para produção"
  echo "  [U] Um único domínio (paths /api, /admin...) + registry na porta 5000"
  echo "  [I] Somente IP, sem TLS (HTTP)     — para testes locais"
  echo
  read -rp "  Escolha [S/U/I]: " ACCESS_MODE
  ACCESS_MODE=${ACCESS_MODE^^}
  [[ "$ACCESS_MODE" =~ ^[SUI]$ ]] || die "Opção inválida. Digite S, U ou I."

  if [[ "$ACCESS_MODE" == "I" ]]; then
    # ── Modo IP ───────────────────────────────────────────────────────────────
    warn "Modo IP: sem TLS. Não use em produção com dados reais."
    echo
    SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null \
      || hostname -I | awk '{print $1}')
    read -rp "  IP público da VPS [${SERVER_IP}]: " INPUT_IP
    SERVER_IP=${INPUT_IP:-$SERVER_IP}
    [[ -n "$SERVER_IP" ]] || die "IP obrigatório."

    PUBLIC_HOST="${SERVER_IP}"
    API_HOST="${SERVER_IP}:8080"
    ADM_HOST="${SERVER_IP}:8081"
    PORTAL_HOST="${SERVER_IP}:8082"
    REG_HOST="${SERVER_IP}:5000"
    ACME_EMAIL="noreply@localhost"

  elif [[ "$ACCESS_MODE" == "U" ]]; then
    # ── Modo domínio único ────────────────────────────────────────────────────
    echo "Informe o domínio único que aponta para esta VPS:"
    read -rp "  Domínio (ex: painel.seudominio.com): " PUBLIC_HOST
    read -rp "  E-mail Let's Encrypt: " ACME_EMAIL
    [[ -n "$PUBLIC_HOST" ]] || die "Domínio obrigatório."
    [[ -n "$ACME_EMAIL"  ]] || die "E-mail obrigatório."

    # API_HOST inclui o path para o builder (API_BASE = https://PUBLIC_HOST/api)
    API_HOST="${PUBLIC_HOST}/api"
    ADM_HOST="${PUBLIC_HOST}"
    PORTAL_HOST="${PUBLIC_HOST}"
    REG_HOST="${PUBLIC_HOST}:5000"

  else
    # ── Modo subdomínios ──────────────────────────────────────────────────────
    echo "Configure os domínios (DEVEM já apontar para esta VPS):"
    read -rp "  API           (ex: license.seudominio.com): " API_HOST
    read -rp "  Admin         (ex: admin.seudominio.com):   " ADM_HOST
    read -rp "  Portal        (ex: minha.seudominio.com):   " PORTAL_HOST
    read -rp "  Registry      (ex: registry.seudominio.com):" REG_HOST
    read -rp "  Landing/inst. (ex: seudominio.com):         " PUBLIC_HOST
    read -rp "  E-mail Let's Encrypt: " ACME_EMAIL

    for v in API_HOST ADM_HOST PORTAL_HOST REG_HOST PUBLIC_HOST ACME_EMAIL; do
      [[ -n "${!v}" ]] || die "Campo $v obrigatório."
    done
  fi

  read -rp "  Usuário admin-dashboard [admin]: " ADM_USER
  ADM_USER=${ADM_USER:-admin}
  fi

  # Escreve .env
  cp .env.example .env 2>/dev/null || true
  for k in ACCESS_MODE PUBLIC_HOST API_HOST ADM_HOST PORTAL_HOST REG_HOST ACME_EMAIL ADM_USER; do
    if grep -q "^${k}=" .env; then
      sed -i "s|^${k}=.*|${k}=${!k}|" .env
    else
      echo "${k}=${!k}" >> .env
    fi
  done
  chmod 600 .env
  ok ".env inicializado (modo: ${ACCESS_MODE})."
fi

# Carrega .env para os passos seguintes
set -a; source .env 2>/dev/null || true; set +a
ACCESS_MODE=${ACCESS_MODE:-S}

# ─── instala Docker se faltar ────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  step "Instalando Docker..."
  curl -fsSL https://get.docker.com | sh >/dev/null
  systemctl enable --now docker
  ok "Docker instalado."
else
  ok "Docker já presente."
fi
docker compose version >/dev/null 2>&1 || {
  apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1
}

# ─── firewall ────────────────────────────────────────────────────────────────
if command -v ufw >/dev/null 2>&1; then
  step "Configurando firewall..."
  ufw --force reset >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  ufw allow 22/tcp >/dev/null
  ufw allow 80/tcp  >/dev/null
  ufw allow 443/tcp >/dev/null
  if [[ "$ACCESS_MODE" == "U" ]]; then
    ufw allow 5000/tcp >/dev/null          # registry
    ok "UFW ativo (22, 80, 443, 5000)."
  elif [[ "$ACCESS_MODE" == "I" ]]; then
    ufw allow 8080/tcp >/dev/null          # api
    ufw allow 8081/tcp >/dev/null          # admin
    ufw allow 8082/tcp >/dev/null          # portal
    ufw allow 5000/tcp >/dev/null          # registry
    ok "UFW ativo (22, 80, 8080, 8081, 8082, 5000)."
  else
    ok "UFW ativo (22, 80, 443)."
  fi
  ufw --force enable >/dev/null
fi

# ─── gera segredos ───────────────────────────────────────────────────────────
step "Gerando segredos (via container Go)..."
bash bootstrap-secrets.sh .env
validate_required_env

# ─── Caddyfile e docker-compose override por modo de acesso ──────────────────
if [[ "$ACCESS_MODE" == "U" ]]; then
  step "Gerando Caddyfile para domínio único (paths + registry :5000)..."
  cp Caddyfile Caddyfile.multi-domain.bak 2>/dev/null || true
  cat > Caddyfile <<'CADDYEOF'
###############################################################################
#  XSP — Caddyfile modo domínio único (gerado por install-server.sh)
###############################################################################
{
    email {$ACME_EMAIL}
}

{$PUBLIC_HOST} {
    encode gzip zstd

    # API de licença — strip /api antes de repassar ao backend Go
    handle_path /api/* {
        reverse_proxy api:8443 {
            health_uri /healthz
            health_interval 15s
        }
    }

    # Admin dashboard
    handle_path /admin/* {
        reverse_proxy admin:80
    }

    # Portal do cliente
    handle_path /portal/* {
        reverse_proxy portal:80
    }

    # Landing page (raiz)
    handle {
        root * /srv
        @install path /install.sh
        header @install Content-Type "text/x-shellscript; charset=utf-8"
        file_server
        try_files {path} {path}.html /index.html
    }

    log {
        output stdout
        format console
    }
}

# Registry na mesma TLS cert, porta 5000
{$PUBLIC_HOST}:5000 {
    reverse_proxy registry:5000 {
        header_up X-Forwarded-Proto {scheme}
    }
}
CADDYEOF

  # Expõe porta 5000 do caddy no host
  cat > docker-compose.override.yml <<'COMPOSEEOF'
services:
  caddy:
    ports:
      - "5000:5000"
COMPOSEEOF
  ok "Caddyfile e override prontos (modo domínio único)."

elif [[ "$ACCESS_MODE" == "I" ]]; then
  step "Gerando Caddyfile para modo IP (HTTP, sem TLS)..."
  cp Caddyfile Caddyfile.multi-domain.bak 2>/dev/null || true
  cat > Caddyfile <<'CADDYEOF'
###############################################################################
#  XSP — Caddyfile modo IP (gerado por install-server.sh)
###############################################################################
{
    auto_https off
}

# Landing page
:80 {
    encode gzip
    root * /srv
    @install path /install.sh
    header @install Content-Type "text/x-shellscript; charset=utf-8"
    file_server
    try_files {path} {path}.html /index.html
}

# API de licença
:8080 {
    encode gzip zstd
    reverse_proxy api:8443 {
        health_uri /healthz
        health_interval 15s
    }
}

# Admin dashboard
:8081 {
    encode gzip zstd
    reverse_proxy admin:80
}

# Portal do cliente
:8082 {
    encode gzip zstd
    reverse_proxy portal:80
}

# Registry
:5000 {
    reverse_proxy registry:5000 {
        header_up X-Forwarded-Proto {scheme}
    }
}
CADDYEOF

  # Expõe as portas extras do caddy no host
  cat > docker-compose.override.yml <<'COMPOSEEOF'
services:
  caddy:
    ports:
      - "8080:8080"
      - "8081:8081"
      - "8082:8082"
      - "5000:5000"
COMPOSEEOF
  ok "Caddyfile e override prontos (modo IP)."

else
  # Modo subdomínios: Caddyfile original já está correto, remove override se existir
  rm -f docker-compose.override.yml
fi

# ─── prepara www-public (landing + install.sh personalizado) ─────────────────
step "Preparando landing pública..."
mkdir -p www-public

# Copia landing
if [[ -f landing/index.html ]]; then
  cp landing/index.html www-public/
fi

# Gera install.sh personalizado com os secrets reais substituídos
if [[ -f install-painel.sh ]]; then
  HMAC=$(grep ^HMAC_PUBLIC_SECRET .env | cut -d= -f2)
  _API_HOST=$(grep ^API_HOST .env | cut -d= -f2)
  _REG_HOST=$(grep ^REG_HOST .env | cut -d= -f2)
  _PUBLIC_HOST=$(grep ^PUBLIC_HOST .env | cut -d= -f2)

  # Protocolo e URL base da API variam por modo
  if [[ "$ACCESS_MODE" == "I" ]]; then
    _PROTO="http"
  else
    _PROTO="https"
  fi
  if grep -q "^API_SCHEME=" .env; then
    sed -i "s|^API_SCHEME=.*|API_SCHEME=${_PROTO}|" .env
  else
    echo "API_SCHEME=${_PROTO}" >> .env
  fi

  sed \
    -e "s|__HMAC_PUBLIC_SECRET_64_HEX_CHARS__|${HMAC}|" \
    -e "s|https://license.seudominio.com|${_PROTO}://${_API_HOST}|g" \
    -e "s|registry.seudominio.com|${_REG_HOST}|g" \
    -e "s|__INSTALL_URL__|${_PROTO}://${_PUBLIC_HOST}/install.sh|g" \
    install-painel.sh > www-public/install.sh
  chmod 755 www-public/install.sh
  ok "install.sh personalizado em www-public/"
fi

# ─── sobe o stack ────────────────────────────────────────────────────────────
step "Subindo stack Docker (pode levar 2-3 min na primeira vez)..."
compose_up_or_die

# ─── espera serviços ────────────────────────────────────────────────────────
step "Aguardando API ficar pronta..."
for i in {1..40}; do
  if docker compose exec -T api wget -qO- http://localhost:8443/healthz >/dev/null 2>&1; then
    ok "API responde."
    break
  fi
  sleep 3
  [[ $i -eq 40 ]] && die "API não subiu. Veja: docker compose logs api"
done

if [[ "$ACCESS_MODE" != "I" ]]; then
  step "Aguardando Caddy emitir certificados (~30-60s)..."
  sleep 8
fi

# ─── resumo ──────────────────────────────────────────────────────────────────
touch .xsp-install-complete
set -a; source .env 2>/dev/null || true; set +a
ACCESS_MODE=${ACCESS_MODE:-S}

if [[ "$ACCESS_MODE" == "I" ]]; then
  _PROTO="http"
  _ADMIN_URL="http://${ADM_HOST}"
  _API_URL="http://${API_HOST}/healthz"
  _REG_URL="http://${REG_HOST}"
  _LAND_URL="http://${PUBLIC_HOST}"
  _INSTALL_URL="http://${PUBLIC_HOST}/install.sh"
elif [[ "$ACCESS_MODE" == "U" ]]; then
  _PROTO="https"
  _ADMIN_URL="https://${PUBLIC_HOST}/admin/"
  _API_URL="https://${PUBLIC_HOST}/api/healthz"
  _REG_URL="https://${REG_HOST}"
  _LAND_URL="https://${PUBLIC_HOST}"
  _INSTALL_URL="https://${PUBLIC_HOST}/install.sh"
else
  _PROTO="https"
  _ADMIN_URL="https://${ADM_HOST}"
  _API_URL="https://${API_HOST}/healthz"
  _REG_URL="https://${REG_HOST}"
  _LAND_URL="https://${PUBLIC_HOST}"
  _INSTALL_URL="https://${PUBLIC_HOST}/install.sh"
fi

echo
echo "${GRN}══════════════════════════════════════════════════════════════════${NC}"
echo "${GRN}  XSP LICENSING — instalação concluída.${NC}"
echo "${GRN}══════════════════════════════════════════════════════════════════${NC}"
echo
echo "  ${CYN}Admin Dashboard:${NC}     ${_ADMIN_URL}"
echo "    usuário: ${ADM_USER}"
echo "    senha:   (mostrada acima pelo bootstrap-secrets)"
echo
echo "  ${CYN}API de Licença:${NC}      ${_API_URL}"
echo "  ${CYN}Docker Registry:${NC}     ${_REG_URL}"
echo "  ${CYN}Landing pública:${NC}     ${_LAND_URL}"
echo "                          (cliente acessa aqui para instalar)"
echo
echo "  ${YEL}Comandos úteis:${NC}"
echo "    make status            — estado dos containers"
echo "    make logs              — logs em tempo real"
echo "    make logs S=api        — logs de um serviço"
echo "    make release           — empacota nova release do painel"
echo "    make down              — para tudo"
echo
echo "  ${YEL}Próximo passo:${NC}"
echo "    1) Acesse ${_ADMIN_URL} → crie sua 1ª KEY"
echo "    2) Empacote o painel: make release"
echo "    3) Mande o cliente abrir: ${_INSTALL_URL}?key=XSP-..."
echo
