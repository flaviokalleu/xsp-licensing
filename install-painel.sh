#!/usr/bin/env bash
###############################################################################
#  XSP — Instalador AUTOMÁTICO do PAINEL (lado cliente)
#
#  Uso:
#    curl -sSL http://SEU_IP/install.sh | sudo bash -s -- XSP-KEY dominio email
#    sudo bash install.sh --update          # atualiza painel existente
#    sudo bash install.sh --status          # mostra status da instalação
#
#  ANTES de hospedar, substitua os 4 placeholders abaixo.
###############################################################################
set -euo pipefail

# ╔════════════════════════════════════════════════════════════════════════════╗
# ║                EDITE ESTES VALORES ANTES DE HOSPEDAR                       ║
# ╚════════════════════════════════════════════════════════════════════════════╝
API_BASE="https://license.seudominio.com"
HMAC_PUBLIC_SECRET="__HMAC_PUBLIC_SECRET_64_HEX_CHARS__"
REGISTRY_HOST="registry.seudominio.com"
REGISTRY_USER="license"

PANEL_VERSION="10.0.3"
INSTALL_PATH="/opt/xsp"
LOGFILE="/var/log/xsp-install.log"

# ─── args ────────────────────────────────────────────────────────────────────
ARG_KEY="${1:-}"
ARG_DOMAIN="${2:-}"
ARG_EMAIL="${3:-}"

# ─── cores ───────────────────────────────────────────────────────────────────
RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; CYN=$'\033[1;36m'; NC=$'\033[0m'
step() { echo "${CYN}→${NC} $*"; }
ok()   { echo "${GRN}✓${NC} $*"; }
warn() { echo "${YEL}⚠${NC} $*"; }
die()  { echo "${RED}✗ ERRO:${NC} $*" >&2; exit 1; }

clear
cat <<'BANNER'
 ╔═══════════════════════════════════════════════════════════════╗
 ║   PAINEL OFFICE XTREAM — Instalador Automático v10            ║
 ║   Configura Docker, baixa o painel e ativa sua licença.       ║
 ╚═══════════════════════════════════════════════════════════════╝
BANNER
echo

# ─── logging ────────────────────────────────────────────────────────────────
mkdir -p /var/log
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== XSP Install: $(date) | modo: ${ARG_KEY:-normal} ==="

# ─── pré-checagens ───────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Rode como root: curl -sSL ... | sudo bash"
[[ -f /etc/os-release ]] || die "Sistema sem /etc/os-release."
. /etc/os-release
[[ "$ID" =~ ^(ubuntu|debian|centos|rhel|almalinux|rocky|fedora)$ ]] \
  || die "SO não suportado: $ID. Suporte: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky."

[[ "${HMAC_PUBLIC_SECRET:0:2}" == "__" ]] \
  && die "Instalador não configurado. Contate o fornecedor."

# ─── gerenciador de pacotes ──────────────────────────────────────────────────
if [[ "$ID" =~ ^(ubuntu|debian)$ ]]; then
  export DEBIAN_FRONTEND=noninteractive
  pkg_install() { apt-get install -y -qq "$@" >/dev/null 2>&1; }
  pkg_update()  { apt-get update -qq >/dev/null; }
else
  pkg_install() { (dnf install -y -q "$@" 2>/dev/null || yum install -y -q "$@" 2>/dev/null); }
  pkg_update()  { (dnf makecache -q 2>/dev/null || yum makecache -q 2>/dev/null || true); }
fi

# ─── verificação de espaço em disco ──────────────────────────────────────────
step "Verificando espaço em disco..."
AVAIL_GB=$(df -BG "${INSTALL_PATH%/*}" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G' || echo 0)
if [[ "${AVAIL_GB:-0}" -lt 5 ]]; then
  die "Espaço insuficiente: ${AVAIL_GB}GB disponível em ${INSTALL_PATH%/*} (mínimo 5GB)."
fi
ok "Espaço disponível: ${AVAIL_GB}GB."

# ─── modo --status ───────────────────────────────────────────────────────────
if [[ "$ARG_KEY" == "--status" ]]; then
  [[ -f "$INSTALL_PATH/.env" ]] || die "Nenhuma instalação encontrada em $INSTALL_PATH."
  source "$INSTALL_PATH/.env"
  echo
  echo "  ${CYN}KEY:${NC}            $XSP_LICENSE_KEY"
  echo "  ${CYN}Instalação:${NC}     $XSP_INSTALLATION_ID"
  echo "  ${CYN}Versão:${NC}         $XSP_VERSION"
  echo "  ${CYN}API:${NC}            $XSP_API_BASE"
  echo
  echo "  ${CYN}Containers:${NC}"
  docker compose -f "$INSTALL_PATH/docker-compose.yml" ps 2>/dev/null || echo "  Stack não encontrada."
  echo
  # Consulta status na API
  RESP=$(curl -s --max-time 5 -X POST "$XSP_API_BASE/portal/status" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"$XSP_LICENSE_KEY\"}" 2>/dev/null || echo "{}")
  STATUS=$(echo "$RESP" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "?")
  DAYS=$(echo "$RESP"   | grep -o '"days_left":[0-9]*' | cut -d: -f2 || echo "?")
  echo "  ${CYN}Licença:${NC}        $STATUS  |  $DAYS dias restantes"
  echo
  exit 0
fi

# ─── modo --update ───────────────────────────────────────────────────────────
if [[ "$ARG_KEY" == "--update" ]]; then
  [[ -f "$INSTALL_PATH/.env" ]] || die "Nenhuma instalação encontrada em $INSTALL_PATH. Instale primeiro."
  source "$INSTALL_PATH/.env"
  step "Modo atualização — verificando licença..."

  # Heartbeat para validar licença antes de atualizar
  TS=$(date +%s); NONCE=$(openssl rand -hex 16)
  BODY="{\"hwid\":\"$(cat /etc/machine-id 2>/dev/null)\",\"panel_version\":\"$XSP_VERSION\"}"
  SIG=$({ printf '%s' "POST/v1/heartbeat"; printf '%s' "$BODY"; printf '%s' "${TS}${NONCE}"; } \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${XSP_PUBLIC_SECRET}" -hex | awk '{print $NF}')
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -X POST "$XSP_API_BASE/v1/heartbeat" \
    -H "Content-Type: application/json" \
    -H "X-Installation-ID: $XSP_INSTALLATION_ID" \
    -H "X-Timestamp: $TS" -H "X-Nonce: $NONCE" -H "X-Signature: $SIG" \
    -d "$BODY" 2>/dev/null || echo "000")
  case "$HTTP_CODE" in
    200|201) ok "Licença válida." ;;
    402) die "Licença expirada. Renove antes de atualizar." ;;
    410) die "Licença revogada." ;;
    403) die "Acesso bloqueado." ;;
    *)   warn "API retornou $HTTP_CODE — continuando mesmo assim..." ;;
  esac

  step "Atualizando imagem do painel..."
  echo "$REGISTRY_STORED_TOKEN" \
    | docker login "$REGISTRY_STORED_HOST" -u "$REGISTRY_STORED_USER" --password-stdin >/dev/null 2>&1 \
    || die "Falha ao autenticar no registry. Registry token pode ter expirado — reinstale."

  cd "$INSTALL_PATH"
  docker compose pull 2>&1 | grep -E "Pull|pull|Pulling|pulled|up to date" || true
  docker compose up -d 2>&1 | tail -5
  ok "Painel atualizado."
  echo
  echo "  ${CYN}Logs:${NC}  docker compose -f $INSTALL_PATH/docker-compose.yml logs -f"
  echo "  ${CYN}Para desinstalar:${NC}  sudo bash $INSTALL_PATH/uninstall.sh"
  echo
  exit 0
fi

# ─── instala dependências ────────────────────────────────────────────────────
step "Instalando dependências..."
pkg_update
pkg_install curl openssl jq util-linux ca-certificates python3

# ─── instala Docker ──────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  step "Instalando Docker..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable --now docker
  ok "Docker instalado."
else
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) presente."
fi
if ! docker compose version >/dev/null 2>&1; then
  pkg_install docker-compose-plugin || die "docker compose não pôde ser instalado."
fi

# ─── configura insecure-registry ─────────────────────────────────────────────
REGISTRY_HOST_ONLY=$(echo "$REGISTRY_HOST" | cut -d'/' -f1)
step "Configurando registry ($REGISTRY_HOST_ONLY)..."
mkdir -p /etc/docker
DAEMON_JSON=/etc/docker/daemon.json
NEEDS_RESTART=0
if [[ -f "$DAEMON_JSON" ]]; then
  if ! python3 -c "import json,sys; d=json.load(open('$DAEMON_JSON')); sys.exit(0 if '$REGISTRY_HOST_ONLY' in d.get('insecure-registries',[]) else 1)" 2>/dev/null; then
    python3 -c "
import json
with open('$DAEMON_JSON') as f: d=json.load(f)
d.setdefault('insecure-registries',[]).append('$REGISTRY_HOST_ONLY')
with open('$DAEMON_JSON','w') as f: json.dump(d,f)
"
    NEEDS_RESTART=1
  fi
else
  printf '{"insecure-registries": ["%s"]}\n' "$REGISTRY_HOST_ONLY" > "$DAEMON_JSON"
  NEEDS_RESTART=1
fi
if [[ $NEEDS_RESTART -eq 1 ]]; then
  systemctl restart docker >/dev/null 2>&1 || true; sleep 2
fi
ok "Docker pronto."

# ─── detecção de instalação existente ────────────────────────────────────────
if [[ -f "$INSTALL_PATH/.env" ]]; then
  warn "Instalação existente detectada em $INSTALL_PATH."
  echo
  echo "  Opções:"
  echo "    [1] Reinstalar (mantém banco de dados)"
  echo "    [2] Atualizar imagem (mais rápido)"
  echo "    [3] Cancelar"
  echo

  if [[ -t 0 ]]; then
    read -rp "  Escolha [1/2/3]: " CHOICE
  else
    CHOICE="1"
    warn "Modo não-interativo: reinstalando automaticamente."
  fi

  case "${CHOICE:-1}" in
    2) exec bash "$0" --update ;;
    3) echo "Cancelado."; exit 0 ;;
    *) warn "Reinstalando — banco de dados preservado." ;;
  esac
fi

# ─── coleta interativa ───────────────────────────────────────────────────────
if [[ ! -t 0 && -z "${ARG_KEY}${ARG_DOMAIN}${ARG_EMAIL}" ]]; then
  exec </dev/tty 2>/dev/null || true
fi

LICENSE_KEY=$(echo "${ARG_KEY:-}" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
if [[ -z "$LICENSE_KEY" ]]; then
  read -rp "KEY (formato XSP-XXXX-XXXX-XXXX-XXXX): " LICENSE_KEY
  LICENSE_KEY=$(echo "$LICENSE_KEY" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
fi
[[ "$LICENSE_KEY" =~ ^XSP-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$ ]] \
  || die "KEY inválida: $LICENSE_KEY"

PANEL_DOMAIN="${ARG_DOMAIN:-}"
if [[ -z "$PANEL_DOMAIN" ]]; then
  read -rp "Domínio público (ex: painel.cliente.com): " PANEL_DOMAIN
fi
[[ -n "$PANEL_DOMAIN" ]] || die "Domínio obrigatório."

ADMIN_EMAIL="${ARG_EMAIL:-}"
if [[ -z "$ADMIN_EMAIL" ]]; then
  read -rp "E-mail do administrador: " ADMIN_EMAIL
fi
[[ "$ADMIN_EMAIL" =~ @ ]] || die "E-mail inválido."
echo

# ─── checa portas ────────────────────────────────────────────────────────────
step "Verificando portas 80/443..."
for p in 80 443; do
  ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${p}$" \
    && die "Porta $p em uso. Pare o serviço antes de continuar."
done
ok "Portas livres."

# ─── HWID ────────────────────────────────────────────────────────────────────
step "Coletando fingerprint da máquina..."
MID=$(cat /etc/machine-id 2>/dev/null | tr -d '\r\n ')
BUUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr -d '\r\n ' || echo "")
DUUID=$(blkid -s UUID -o value "$(findmnt -n -o SOURCE / 2>/dev/null)" 2>/dev/null | tr -d '\r\n ' || echo "")
MAC=""
for addr in /sys/class/net/*/address; do
  iface=$(basename "$(dirname "$addr")")
  [[ "$iface" == "lo" ]] && continue
  m=$(cat "$addr" 2>/dev/null | tr -d '\r\n ')
  [[ "$m" == "00:00:00:00:00:00" || -z "$m" ]] && continue
  MAC="$m"; break
done
HWID=$(printf '%s\x1f%s\x1f%s\x1f%s' "$MID" "$BUUID" "$DUUID" "$MAC" | sha256sum | awk '{print $1}')
ok "HWID: ${HWID:0:16}…"

HOSTNAME_VAL=$(hostname)
PUBLIC_IP=$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || echo "")

# ─── ativa licença ───────────────────────────────────────────────────────────
step "Ativando licença em $API_BASE ..."
BODY=$(printf '{"key":"%s","hwid":"%s","hostname":"%s","public_ip":"%s","domain":"%s","email":"%s","os":"%s","os_version":"%s","panel_version":"%s","installer_version":"%s","fingerprint":{"machine_id":"%s","board_uuid":"%s","disk_uuid":"%s","mac":"%s"}}' \
  "$LICENSE_KEY" "$HWID" "$HOSTNAME_VAL" "$PUBLIC_IP" "$PANEL_DOMAIN" "$ADMIN_EMAIL" \
  "$ID" "$VERSION_ID" "$PANEL_VERSION" "$PANEL_VERSION" \
  "$MID" "$BUUID" "$DUUID" "$MAC")

TS=$(date +%s); NONCE=$(openssl rand -hex 16)
SIG=$({ printf '%s' "POST/v1/activate"; printf '%s' "$BODY"; printf '%s' "${TS}${NONCE}"; } \
  | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${HMAC_PUBLIC_SECRET}" -hex | awk '{print $NF}')

HTTP_RESP=$(curl -sS --max-time 15 -w "\n%{http_code}" \
  -H "Content-Type: application/json" \
  -H "X-Timestamp: $TS" -H "X-Nonce: $NONCE" -H "X-Signature: $SIG" \
  -H "User-Agent: xsp-installer-bash/1.0" \
  -d "$BODY" "${API_BASE}/v1/activate")
HTTP_CODE=$(echo "$HTTP_RESP" | tail -1)
HTTP_BODY=$(echo "$HTTP_RESP" | sed '$d')

case "$HTTP_CODE" in
  200|201) ok "Licença ativa." ;;
  402) die "Licença EXPIRADA. Renove pela área do cliente." ;;
  403) die "Acesso bloqueado (blacklist)." ;;
  404) die "KEY não encontrada." ;;
  409) die "Limite de instalações atingido para esta KEY." ;;
  410) die "Licença REVOGADA." ;;
  429) die "Muitas tentativas. Aguarde 1 minuto." ;;
  401) die "Falha HMAC. Verifique data/hora do servidor: $(date -u)" ;;
  *)   die "API retornou HTTP $HTTP_CODE: $HTTP_BODY" ;;
esac

INSTALLATION_ID=$(echo "$HTTP_BODY" | jq -r '.installation_id // empty')
REGISTRY_TOKEN=$(echo "$HTTP_BODY"  | jq -r '.registry_token  // empty')
EXPIRES_AT=$(echo "$HTTP_BODY"      | jq -r '.expires_at       // empty')
PANEL_IMAGE=$(echo "$HTTP_BODY"     | jq -r '.manifest.images[0].ref // empty')
[[ -n "$INSTALLATION_ID" ]] || die "Resposta sem installation_id"
[[ -n "$REGISTRY_TOKEN"  ]] || die "Resposta sem registry_token"
[[ -n "$PANEL_IMAGE"     ]] || PANEL_IMAGE="${REGISTRY_HOST}/xsp/panel:${PANEL_VERSION}"
ok "Instalação: ${INSTALLATION_ID:0:8}…  Expira: ${EXPIRES_AT:0:10}"

# ─── login + pull ─────────────────────────────────────────────────────────────
step "Autenticando no registry..."
echo "$REGISTRY_TOKEN" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USER" --password-stdin >/dev/null 2>&1 \
  || die "Falha ao logar no registry $REGISTRY_HOST."
ok "Logado em $REGISTRY_HOST."

step "Baixando imagem ($PANEL_IMAGE)..."
docker pull "$PANEL_IMAGE" 2>&1 | grep -E "Pull|Pulling|pull|Downloaded|up to date" || true
ok "Imagem pronta."

# ─── escreve configuração ────────────────────────────────────────────────────
step "Gerando configuração em $INSTALL_PATH ..."
mkdir -p "$INSTALL_PATH" "$INSTALL_PATH/certs" "$INSTALL_PATH/initdb"
chmod 750 "$INSTALL_PATH"

# Extrai SQL inicial da imagem
docker run --rm --entrypoint sh "$PANEL_IMAGE" \
  -c 'cat /var/www/html/docker-entrypoint-initdb.d/01-schema.sql 2>/dev/null || true' \
  > "$INSTALL_PATH/initdb/01-schema.sql"
[[ -s "$INSTALL_PATH/initdb/01-schema.sql" ]] \
  && ok "SQL inicial extraído." \
  || rm -f "$INSTALL_PATH/initdb/01-schema.sql"

# Preserva DB_PASS se reinstalando
if [[ -f "$INSTALL_PATH/.env" ]]; then
  OLD_DB_PASS=$(grep "^DB_PASS=" "$INSTALL_PATH/.env" | cut -d= -f2 || echo "")
  OLD_DB_ROOT=$(grep "^DB_ROOT_PASS=" "$INSTALL_PATH/.env" | cut -d= -f2 || echo "")
fi
DB_PASS="${OLD_DB_PASS:-$(openssl rand -hex 16)}"
DB_ROOT_PASS="${OLD_DB_ROOT:-$(openssl rand -hex 16)}"

cat > "$INSTALL_PATH/.env" <<ENV
# Gerado pelo instalador XSP
XSP_LICENSE_KEY=${LICENSE_KEY}
XSP_INSTALLATION_ID=${INSTALLATION_ID}
XSP_PUBLIC_SECRET=${HMAC_PUBLIC_SECRET}
XSP_API_BASE=${API_BASE}
XSP_VERSION=${PANEL_VERSION}

PANEL_IMAGE=${PANEL_IMAGE}
PANEL_DOMAIN=${PANEL_DOMAIN}
PANEL_EMAIL=${ADMIN_EMAIL}

DB_NAME=xsp_panel
DB_USER=xsp
DB_PASS=${DB_PASS}
DB_ROOT_PASS=${DB_ROOT_PASS}

REGISTRY_STORED_HOST=${REGISTRY_HOST}
REGISTRY_STORED_USER=${REGISTRY_USER}
REGISTRY_STORED_TOKEN=${REGISTRY_TOKEN}
ENV
chmod 600 "$INSTALL_PATH/.env"

cat > "$INSTALL_PATH/docker-compose.yml" <<'COMPOSE'
services:
  panel:
    image: ${PANEL_IMAGE}
    restart: unless-stopped
    env_file: .env
    environment:
      XSP_LICENSE_KEY: ${XSP_LICENSE_KEY}
      XSP_INSTALLATION_ID: ${XSP_INSTALLATION_ID}
      XSP_PUBLIC_SECRET: ${XSP_PUBLIC_SECRET}
      XSP_API_BASE: ${XSP_API_BASE}
      XSP_VERSION: ${XSP_VERSION}
      DB_HOST: db
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASS: ${DB_PASS}
    volumes:
      - /etc/machine-id:/etc/machine-id:ro
      - /sys/class/dmi/id/product_uuid:/sys/class/dmi/id/product_uuid:ro
      - xsp_state:/var/lib/xsp
      - xsp_uploads:/var/www/html/uploads
    depends_on:
      db:
        condition: service_healthy
    security_opt: ["no-new-privileges:true"]
    cap_drop: ["ALL"]
    cap_add: ["NET_BIND_SERVICE", "CHOWN", "SETUID", "SETGID", "DAC_OVERRIDE"]
    ports: ["80:80"]
    networks: [wan, db_net]

  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${DB_ROOT_PASS}
      MARIADB_DATABASE: ${DB_NAME}
      MARIADB_USER: ${DB_USER}
      MARIADB_PASSWORD: ${DB_PASS}
    volumes:
      - dbdata:/var/lib/mysql
      - /opt/xsp/initdb:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      retries: 20
    networks: [db_net]

volumes:
  xsp_state:
  xsp_uploads:
  dbdata:

networks:
  wan:
    driver: bridge
  db_net:
    driver: bridge
    internal: true
COMPOSE

# ─── gera uninstall.sh ───────────────────────────────────────────────────────
cat > "$INSTALL_PATH/uninstall.sh" <<UNINSTALL
#!/usr/bin/env bash
###############################################################################
#  XSP — Desinstalador do Painel
#  Uso: sudo bash /opt/xsp/uninstall.sh
###############################################################################
set -euo pipefail
RED=\$'\033[1;31m'; GRN=\$'\033[1;32m'; YEL=\$'\033[1;33m'; CYN=\$'\033[1;36m'; NC=\$'\033[0m'
[[ \$EUID -eq 0 ]] || { echo "\${RED}Rode como root\${NC}"; exit 1; }

INSTALL_PATH="$INSTALL_PATH"
LOGFILE="$LOGFILE"

echo "\${YEL}╔══════════════════════════════════════════╗\${NC}"
echo "\${YEL}║  XSP — Desinstalador                     ║\${NC}"
echo "\${YEL}╚══════════════════════════════════════════╝\${NC}"
echo
echo "\${RED}⚠ ATENÇÃO: Isso vai remover o painel e todos os dados!\${NC}"
echo
read -rp "Digite 'sim' para confirmar: " CONFIRM
[[ "\$CONFIRM" == "sim" ]] || { echo "Cancelado."; exit 0; }

exec >> "\$LOGFILE" 2>&1
echo "=== XSP Uninstall: \$(date) ==="

# Desativa licença na API
if [[ -f "\$INSTALL_PATH/.env" ]]; then
  source "\$INSTALL_PATH/.env"
  echo "\${CYN}→\${NC} Desativando licença na API..."
  TS=\$(date +%s); NONCE=\$(openssl rand -hex 16 2>/dev/null || echo "0")
  BODY="{}"
  SIG=\$({ printf '%s' "POST/v1/deactivate"; printf '%s' "\$BODY"; printf '%s' "\${TS}\${NONCE}"; } \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:\${XSP_PUBLIC_SECRET}" -hex 2>/dev/null \
    | awk '{print \$NF}' || echo "")
  curl -s --max-time 5 -X POST "\$XSP_API_BASE/v1/deactivate" \
    -H "Content-Type: application/json" \
    -H "X-Installation-ID: \$XSP_INSTALLATION_ID" \
    -H "X-Timestamp: \$TS" -H "X-Nonce: \$NONCE" -H "X-Signature: \$SIG" \
    -d "\$BODY" >/dev/null 2>&1 && echo "\${GRN}✓\${NC} Licença desativada." \
    || echo "\${YEL}⚠\${NC} Não foi possível contatar a API — prosseguindo."
fi

# Para e remove containers + volumes
echo "\${CYN}→\${NC} Parando containers..."
docker compose -f "\$INSTALL_PATH/docker-compose.yml" down -v 2>/dev/null || true
echo "\${GRN}✓\${NC} Containers removidos."

# Remove diretório
echo "\${CYN}→\${NC} Removendo \$INSTALL_PATH ..."
rm -rf "\$INSTALL_PATH"
echo "\${GRN}✓\${NC} Arquivos removidos."

# Remove credenciais do registry
docker logout "${REGISTRY_HOST}" >/dev/null 2>&1 || true

echo
echo "\${GRN}✓ Desinstalação concluída.\${NC}"
echo "  Log disponível em: \$LOGFILE"
echo "  KEY \${XSP_LICENSE_KEY:-?} pode ser reutilizada em outra máquina."
echo
UNINSTALL
chmod 750 "$INSTALL_PATH/uninstall.sh"
ok "Configuração escrita."

# ─── sobe stack ──────────────────────────────────────────────────────────────
step "Subindo containers..."
cd "$INSTALL_PATH"
docker compose up -d 2>&1 | tail -5

# ─── firewall ────────────────────────────────────────────────────────────────
step "Aplicando firewall anti-pirataria..."
API_HOST_ONLY=$(echo "$API_BASE" | sed 's|^https\?://||' | cut -d'/' -f1 | cut -d':' -f1)
API_IP=$(getent hosts "$API_HOST_ONLY" 2>/dev/null | awk '{print $1}' | head -1 || echo "")
PANEL_ID=$(docker compose ps -q panel 2>/dev/null | head -1 || echo "")
WAN_NET=""
if [[ -n "$PANEL_ID" ]]; then
  WAN_NET=$(docker inspect "$PANEL_ID" --format \
    '{{range $k,$v := .NetworkSettings.Networks}}{{if eq $k "xsp_wan"}}{{$v.NetworkID}}{{end}}{{end}}' 2>/dev/null || echo "")
fi
WAN_IFACE=""
if [[ -n "$WAN_NET" ]]; then
  WAN_IFACE=$(docker network inspect "$WAN_NET" \
    --format '{{.Options.com.docker.network.bridge.name}}' 2>/dev/null || echo "")
fi
[[ -z "$WAN_IFACE" ]] && WAN_IFACE=$(ip link 2>/dev/null | grep -oP 'br-[a-f0-9]+' | head -1 || echo "")

if [[ -n "$API_IP" && -n "$WAN_IFACE" ]]; then
  iptables -I FORWARD -i "$WAN_IFACE" -d "$API_IP" -j ACCEPT 2>/dev/null || true
  iptables -I FORWARD -i "$WAN_IFACE" ! -d "$API_IP" -j DROP  2>/dev/null || true
  # Persiste regras
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  ok "Firewall: saída restrita a $API_HOST_ONLY ($API_IP)."
else
  warn "Firewall não aplicado — IP da API ou interface não detectados."
fi

# ─── health check ────────────────────────────────────────────────────────────
step "Aguardando painel responder (até 120s)..."
HEALTHY=0
for i in {1..60}; do
  curl -fsS --max-time 3 http://127.0.0.1/healthz >/dev/null 2>&1 && HEALTHY=1 && break
  sleep 2
done
if [[ $HEALTHY -ne 1 ]]; then
  warn "Painel não respondeu ainda. Verifique os logs:"
  docker compose logs --tail=20 panel 2>/dev/null || true
fi

# ─── resumo ──────────────────────────────────────────────────────────────────
echo
echo "${GRN}══════════════════════════════════════════════════════════════${NC}"
echo "${GRN}  INSTALAÇÃO CONCLUÍDA${NC}"
echo "${GRN}══════════════════════════════════════════════════════════════${NC}"
echo
echo "  ${CYN}Painel:${NC}       http://${PANEL_DOMAIN}/"
echo "  ${CYN}Local:${NC}        http://$(hostname -I 2>/dev/null | awk '{print $1}')/"
echo
echo "  ${YEL}Licença:${NC}"
echo "    KEY:        $LICENSE_KEY"
echo "    Expira em:  ${EXPIRES_AT:0:10}"
echo "    ID:         $INSTALLATION_ID"
echo
echo "  ${YEL}Comandos úteis:${NC}"
echo "    Status:      sudo bash $INSTALL_PATH/uninstall.sh --status  2>/dev/null || bash <(curl -sSL $API_BASE/../install.sh) --status"
echo "    Atualizar:   curl -sSL http://${API_BASE#*//}/install.sh | sudo bash -s -- --update"
echo "    Logs:        docker compose -f $INSTALL_PATH/docker-compose.yml logs -f"
echo "    Reiniciar:   docker compose -f $INSTALL_PATH/docker-compose.yml restart"
echo "    Desinstalar: sudo bash $INSTALL_PATH/uninstall.sh"
echo
echo "  ${YEL}Log desta instalação:${NC} $LOGFILE"
echo
