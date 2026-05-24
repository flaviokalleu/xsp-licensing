#!/usr/bin/env bash
###############################################################################
# XSP LICENSING - Bootstrap do servidor central
#
# Uso:
#   curl -sSL https://raw.githubusercontent.com/flaviokalleu/xsp-licensing/master/setup.sh | sudo bash
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

step "Instalando dependencias basicas..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl unzip >/dev/null
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

cd "$TARGET_DIR"

if [[ -e /dev/tty ]]; then
  exec </dev/tty
else
  warn "Sem /dev/tty; o instalador seguira sem entrada interativa."
fi

step "Executando instalador do servidor central..."
exec bash INSTALL.sh server
