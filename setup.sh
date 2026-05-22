#!/usr/bin/env bash
###############################################################################
#  XSP LICENSING — Instalador do Servidor Central (100% Docker)
#
#  Um único comando na VPS:
#    curl -sSL https://raw.githubusercontent.com/flaviokalleu/xsp-licensing/master/setup.sh | sudo bash
#
#  Instala Docker se necessário e executa o instalador via container.
###############################################################################
set -euo pipefail

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; CYN=$'\033[1;36m'; NC=$'\033[0m'
step() { echo "${CYN}→${NC} $*"; }
ok()   { echo "${GRN}✓${NC} $*"; }
die()  { echo "${RED}✗ ERRO:${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Rode como root: curl -sSL ... | sudo bash"
[[ -f /etc/os-release ]] || die "Sistema sem /etc/os-release."
. /etc/os-release
[[ "$ID" =~ ^(ubuntu|debian)$ ]] || die "SO não suportado: $ID (precisa Ubuntu/Debian)."

clear
cat <<'BANNER'
 ╔══════════════════════════════════════════════════════════════════╗
 ║   XSP LICENSING — Servidor Central (100% Docker)                 ║
 ╚══════════════════════════════════════════════════════════════════╝
BANNER
echo

export DEBIAN_FRONTEND=noninteractive

# ─── Instala Docker se necessário ────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  step "Instalando Docker..."
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl >/dev/null
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable --now docker
  ok "Docker instalado."
else
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) já presente."
fi

# ─── Executa o instalador via container ──────────────────────────────────────
step "Baixando e executando o instalador XSP..."
echo

mkdir -p /etc/docker
exec docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /root:/root \
  -v /etc/docker:/etc/docker \
  -w /root \
  ghcr.io/flaviokalleu/xsp-licensing:latest
