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

# ─── coleta de entradas ──────────────────────────────────────────────────────
if [[ ! -f .env ]] || ! grep -q "^API_HOST=.*\." .env 2>/dev/null; then
  echo "Configure os domínios (DEVEM já apontar para esta VPS):"
  read -rp "  API           (ex: license.seudominio.com): " API_HOST
  read -rp "  Admin         (ex: admin.seudominio.com):   " ADM_HOST
  read -rp "  Registry      (ex: registry.seudominio.com):" REG_HOST
  read -rp "  Landing/inst. (ex: seudominio.com):          " PUBLIC_HOST
  read -rp "  E-mail Let's Encrypt: " ACME_EMAIL
  read -rp "  Usuário admin-dashboard [admin]: " ADM_USER
  ADM_USER=${ADM_USER:-admin}

  for v in API_HOST ADM_HOST REG_HOST PUBLIC_HOST ACME_EMAIL; do
    [[ -n "${!v}" ]] || die "Campo $v obrigatório."
  done

  # Escreve .env
  cp .env.example .env 2>/dev/null || true
  for k in API_HOST ADM_HOST REG_HOST PUBLIC_HOST ACME_EMAIL ADM_USER; do
    if grep -q "^${k}=" .env; then
      sed -i "s|^${k}=.*|${k}=${!k}|" .env
    else
      echo "${k}=${!k}" >> .env
    fi
  done
  chmod 600 .env
  ok ".env inicializado com seus domínios."
fi

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
  ufw allow OpenSSH >/dev/null
  ufw allow 80/tcp  >/dev/null
  ufw allow 443/tcp >/dev/null
  ufw --force enable >/dev/null
  ok "UFW ativo (22, 80, 443)."
fi

# ─── gera segredos ───────────────────────────────────────────────────────────
step "Gerando segredos (via container Go)..."
bash bootstrap-secrets.sh .env

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
  API_HOST=$(grep ^API_HOST .env | cut -d= -f2)
  REG_HOST=$(grep ^REG_HOST .env | cut -d= -f2)

  sed \
    -e "s|__HMAC_PUBLIC_SECRET_64_HEX_CHARS__|${HMAC}|" \
    -e "s|https://license.seudominio.com|https://${API_HOST}|g" \
    -e "s|registry.seudominio.com|${REG_HOST}|g" \
    install-painel.sh > www-public/install.sh
  chmod 755 www-public/install.sh
  ok "install.sh personalizado em www-public/"
fi

# ─── sobe o stack ────────────────────────────────────────────────────────────
step "Subindo stack Docker (pode levar 2-3 min na 1ª vez)..."
docker compose up -d --build 2>&1 | tail -8

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

step "Aguardando Caddy emitir certificados (~30-60s)..."
sleep 8

# ─── resumo ──────────────────────────────────────────────────────────────────
. .env

echo
echo "${GRN}══════════════════════════════════════════════════════════════════${NC}"
echo "${GRN}  XSP LICENSING — instalação concluída.${NC}"
echo "${GRN}══════════════════════════════════════════════════════════════════${NC}"
echo
echo "  ${CYN}Admin Dashboard:${NC}     https://${ADM_HOST}"
echo "    usuário: ${ADM_USER}"
echo "    senha:   (mostrada acima pelo bootstrap-secrets)"
echo
echo "  ${CYN}API de Licença:${NC}      https://${API_HOST}/healthz"
echo "  ${CYN}Docker Registry:${NC}     https://${REG_HOST}"
echo "  ${CYN}Landing pública:${NC}     https://${PUBLIC_HOST}"
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
echo "    1) Acesse https://${ADM_HOST} → crie sua 1ª KEY"
echo "    2) Empacote o painel: make release"
echo "    3) Mande o cliente abrir: https://${PUBLIC_HOST}/?key=XSP-..."
echo
