#!/usr/bin/env bash
###############################################################################
#  XSP LICENSING — Instalador Master
#
#  Roteador entre as duas instalações possíveis:
#
#   [1] SERVIDOR CENTRAL (gerador de licença)
#       → Roda 1 vez na SUA VPS, configura toda a infra (API, admin, registry).
#
#   [2] PAINEL DO CLIENTE
#       → Roda na VPS do cliente, instala o painel via Docker.
#
#  Uso:  sudo bash INSTALL.sh             (modo interativo)
#        sudo bash INSTALL.sh server      (força modo servidor)
#        sudo bash INSTALL.sh painel      (força modo painel)
###############################################################################
set -euo pipefail

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; CYN=$'\033[1;36m'; NC=$'\033[0m'

clear
cat <<'BANNER'
 ╔══════════════════════════════════════════════════════════════════╗
 ║                  XSP LICENSING — Instalador                      ║
 ║          Sistema Anti-Pirataria para Painéis IPTV                ║
 ╚══════════════════════════════════════════════════════════════════╝
BANNER
echo

[[ $EUID -eq 0 ]] || { echo "${RED}✗ Rode como root: sudo bash $0${NC}"; exit 1; }

cd "$(dirname "$(readlink -f "$0")")"

MODE="${1:-}"
if [[ -z "$MODE" ]]; then
  echo "O que deseja instalar?"
  echo
  echo "  ${CYN}[1]${NC} SERVIDOR CENTRAL (gerador de licença)"
  echo "      Para SUA VPS — sobe API + Postgres + Registry + Admin Dashboard"
  echo
  echo "  ${CYN}[2]${NC} PAINEL DO CLIENTE"
  echo "      Para a VPS do CLIENTE — instala o painel ativando uma KEY"
  echo
  read -rp "Escolha [1/2]: " ESCOLHA
  case "$ESCOLHA" in
    1) MODE="server" ;;
    2) MODE="painel" ;;
    *) echo "${RED}Opção inválida.${NC}"; exit 1 ;;
  esac
fi

case "$MODE" in
  server|servidor|s)
    [[ -f install-server.sh ]] || { echo "${RED}✗ install-server.sh não encontrado.${NC}"; exit 1; }
    [[ -d api-license     ]] || { echo "${RED}✗ Pasta api-license/ faltando — bundle incompleto.${NC}"; exit 1; }
    exec bash install-server.sh
    ;;
  painel|cliente|c|p)
    [[ -f install-painel.sh ]] || { echo "${RED}✗ install-painel.sh não encontrado.${NC}"; exit 1; }
    exec bash install-painel.sh
    ;;
  *)
    echo "${RED}✗ Modo desconhecido: $MODE${NC}"
    echo "Use: sudo bash INSTALL.sh [server|painel]"
    exit 1
    ;;
esac
