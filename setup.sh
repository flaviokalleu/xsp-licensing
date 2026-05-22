#!/usr/bin/env bash
###############################################################################
#  XSP LICENSING — Bootstrap do Servidor Central
#
#  Um único comando na VPS:
#    curl -sSL https://raw.githubusercontent.com/flaviokalleu/xsp-licensing/master/setup.sh | sudo bash
#
#  O que faz:
#    1. Instala git e docker (se faltar)
#    2. Clona o repositório em /opt/xsp-licensing
#    3. Executa INSTALL.sh server (interativo)
###############################################################################
set -euo pipefail

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; CYN=$'\033[1;36m'; NC=$'\033[0m'
step() { echo "${CYN}→${NC} $*"; }
ok()   { echo "${GRN}✓${NC} $*"; }
die()  { echo "${RED}✗ ERRO:${NC} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Rode como root: curl -sSL ... | sudo bash"
[[ -f /etc/os-release ]] || die "Sistema sem /etc/os-release."
. /etc/os-release
[[ "$ID" =~ ^(ubuntu|debian)$ ]] || die "SO não suportado: $ID"

REPO_URL="https://github.com/flaviokalleu/xsp-licensing"
INSTALL_DIR="/opt/xsp-licensing"

clear
cat <<'BANNER'
 ╔══════════════════════════════════════════════════════════════════╗
 ║   XSP LICENSING — Bootstrap do Servidor Central                  ║
 ╚══════════════════════════════════════════════════════════════════╝
BANNER
echo

export DEBIAN_FRONTEND=noninteractive

# ─── git ─────────────────────────────────────────────────────────────────────
if ! command -v git >/dev/null 2>&1; then
  step "Instalando git..."
  apt-get update -qq && apt-get install -y -qq git >/dev/null
  ok "git instalado."
else
  ok "git já presente."
fi

# ─── docker ──────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  step "Instalando Docker..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable --now docker
  ok "Docker instalado."
else
  ok "Docker já presente."
fi

# ─── clona repositório ───────────────────────────────────────────────────────
if [[ -d "$INSTALL_DIR/.git" ]]; then
  step "Atualizando repositório em $INSTALL_DIR ..."
  git -C "$INSTALL_DIR" pull --ff-only 2>&1 | tail -2
else
  step "Clonando $REPO_URL → $INSTALL_DIR ..."
  git clone "$REPO_URL" "$INSTALL_DIR" 2>&1 | tail -2
fi
ok "Repositório pronto."

# ─── instala servidor ────────────────────────────────────────────────────────
cd "$INSTALL_DIR"
exec bash INSTALL.sh server
