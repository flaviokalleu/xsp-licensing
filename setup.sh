#!/usr/bin/env bash
###############################################################################
# XSP LICENSING - Bootstrap do servidor central
#
# Uso:
#   curl -sSL https://raw.githubusercontent.com/flaviokalleu/xsp-licensing/master/setup.sh | sudo bash
#   curl -sSL https://raw.githubusercontent.com/flaviokalleu/xsp-licensing/master/setup.sh | sudo bash -s -- DOMINIO_OU_IP email@dominio.com
#
# O bootstrap nao depende de imagem GHCR. Ele baixa o projeto direto do GitHub,
# instala Docker se necessario e executa o instalador local.
###############################################################################
set -euo pipefail

REPO="flaviokalleu/xsp-licensing"
REF="${XSP_REF:-master}"
TARGET_DIR="${XSP_TARGET_DIR:-/opt/xsp-licensing}"
RELEASE_URL="https://github.com/${REPO}/releases/latest/download/xsp-licensing-SERVER.zip"
ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${REF}.zip"
LOGFILE="/var/log/xsp-setup.log"
SERVER_HOST="${XSP_SERVER_HOST:-${1:-}}"
SERVER_EMAIL="${XSP_SERVER_EMAIL:-${2:-}}"

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; CYN=$'\033[1;36m'; NC=$'\033[0m'
step() { echo "${CYN}->${NC} $*"; }
ok()   { echo "${GRN}OK${NC} $*"; }
warn() { echo "${YEL}WARN${NC} $*"; }
die()  { echo "${RED}ERRO:${NC} $*" >&2; exit 1; }

mkdir -p /var/log
exec > >(tee -a "$LOGFILE") 2>&1

clear || true
cat <<'BANNER'
===============================================================
  XSP LICENSING - Servidor Central
  Bootstrap direto do GitHub, sem depender de GHCR.
===============================================================
BANNER
echo

[[ $EUID -eq 0 ]] || die "Rode como root: curl -sSL ... | sudo bash"
[[ -f /etc/os-release ]] || die "Sistema sem /etc/os-release."
. /etc/os-release
[[ "$ID" =~ ^(ubuntu|debian)$ ]] || die "SO nao suportado: $ID (precisa Ubuntu/Debian)."

export DEBIAN_FRONTEND=noninteractive

curl_retry() {
  curl -fsSL --connect-timeout 10 --retry 3 --retry-delay 3 "$@"
}

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

detect_public_host() {
  curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
    || hostname -I 2>/dev/null | awk '{print $1}' \
    || echo ""
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

read_tty_or_default() {
  local prompt="$1"
  local default="$2"
  local value=""
  local timeout="${XSP_PROMPT_TIMEOUT:-30}"
  if [[ -r /dev/tty ]]; then
    printf '%s' "$prompt" >/dev/tty
    IFS= read -r -t "$timeout" value </dev/tty || {
      printf '\n' >/dev/tty
      true
    }
  fi
  printf '%s' "${value:-$default}"
}

collect_server_config() {
  if [[ -f "$TARGET_DIR/.env" ]] && grep -q "^API_HOST=" "$TARGET_DIR/.env" 2>/dev/null; then
    ok "Config .env existente detectada; reutilizando configuracao atual."
    return
  fi

  step "Coletando dominio/IP e e-mail do servidor..."
  SERVER_HOST="$(normalize_host "$SERVER_HOST")"
  if [[ -z "$SERVER_HOST" ]]; then
    local detected_host
    detected_host="$(detect_public_host)"
    SERVER_HOST="$(read_tty_or_default "  Dominio ou IP publico [${detected_host}]: " "$detected_host")"
    SERVER_HOST="$(normalize_host "$SERVER_HOST")"
  fi
  [[ -n "$SERVER_HOST" ]] || die "Dominio/IP obrigatorio."

  if [[ -z "$SERVER_EMAIL" ]]; then
    local default_email
    default_email="$(default_email_for_host "$SERVER_HOST")"
    SERVER_EMAIL="$(read_tty_or_default "  E-mail do administrador/Let's Encrypt [${default_email}]: " "$default_email")"
  fi
  [[ "$SERVER_EMAIL" =~ @ ]] || die "E-mail invalido: $SERVER_EMAIL"

  export XSP_SERVER_HOST="$SERVER_HOST"
  export XSP_SERVER_EMAIL="$SERVER_EMAIL"
  export XSP_ADMIN_USER="${XSP_ADMIN_USER:-admin}"
  ok "Configuracao inicial: host=${SERVER_HOST}, email=${SERVER_EMAIL}."
}

step "Instalando dependencias basicas..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl unzip openssl python3 >/dev/null
ok "Dependencias basicas instaladas."

if ! command -v docker >/dev/null 2>&1; then
  step "Instalando Docker..."
  curl_retry https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable --now docker >/dev/null 2>&1
  ok "Docker instalado."
else
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) ja presente."
fi

if ! docker compose version >/dev/null 2>&1; then
  step "Instalando Docker Compose plugin..."
  apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 \
    || die "docker compose nao pode ser instalado."
  ok "Docker Compose instalado."
else
  ok "docker compose $(docker compose version --short 2>/dev/null || echo ok)."
fi

TMP_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

step "Baixando pacote do servidor pelo GitHub Release..."
if ! curl_retry --max-time 300 "$RELEASE_URL" -o "$TMP_DIR/source.zip"; then
  warn "Release ainda nao disponivel; usando codigo da branch ${REF}."
  curl_retry --max-time 300 "$ARCHIVE_URL" -o "$TMP_DIR/source.zip"
fi
unzip -q "$TMP_DIR/source.zip" -d "$TMP_DIR"
SRC_DIR=$(find "$TMP_DIR" -mindepth 1 -maxdepth 1 -type d \( -name 'xsp-server' -o -name 'xsp-licensing-*' \) | head -1 || true)
[[ -n "$SRC_DIR" && -d "$SRC_DIR" ]] || die "Arquivo baixado nao contem o projeto esperado."
ok "Projeto baixado."

step "Atualizando arquivos em $TARGET_DIR ..."
mkdir -p "$TARGET_DIR"
cp -a "$SRC_DIR/." "$TARGET_DIR/"
chmod +x "$TARGET_DIR/INSTALL.sh" "$TARGET_DIR/install-server.sh" "$TARGET_DIR/install-painel.sh" 2>/dev/null || true
ok "Arquivos prontos em $TARGET_DIR."

collect_server_config

cd "$TARGET_DIR"
step "Executando instalador do servidor central em Docker..."
if [[ -n "${XSP_SERVER_HOST:-}" ]]; then
  exec bash INSTALL.sh server "$XSP_SERVER_HOST" "$XSP_SERVER_EMAIL"
fi
exec bash INSTALL.sh server
