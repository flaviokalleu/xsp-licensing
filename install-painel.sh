#!/usr/bin/env bash
###############################################################################
#  XSP — Instalador AUTOMÁTICO do PAINEL (lado cliente)
#
#  Hospede este arquivo em: https://seudominio.com/install.sh
#
#  Cliente pode rodar de várias formas:
#     curl -sSL https://seudominio.com/install.sh | sudo bash
#     curl -sSL https://seudominio.com/install.sh | sudo bash -s -- XSP-AAAA-BBBB-CCCC-DDDD
#     curl -sSL https://seudominio.com/install.sh | sudo bash -s -- XSP-... painel.cliente.com email@x.com
#
#  Faz tudo automaticamente:
#    - Aceita KEY, domínio, e-mail como argumentos (ou pergunta interativamente)
#    - Coleta HWID (machine-id + board UUID + disk UUID + MAC)
#    - Ativa licença na API central via HMAC-SHA256
#    - Instala Docker, faz pull da imagem, sobe stack
#
#  ANTES de hospedar, EDITE os 4 placeholders abaixo (linhas marcadas com <<<).
###############################################################################
set -euo pipefail

# ╔════════════════════════════════════════════════════════════════════════════╗
# ║                EDITE ESTES 4 VALORES ANTES DE HOSPEDAR                     ║
# ╚════════════════════════════════════════════════════════════════════════════╝
API_BASE="https://license.seudominio.com"                # <<< sua API
HMAC_PUBLIC_SECRET="__HMAC_PUBLIC_SECRET_64_HEX_CHARS__" # <<< mesmo do .env da API
REGISTRY_HOST="registry.seudominio.com"                  # <<< seu registry
REGISTRY_USER="license"                                  # <<< usuário do registry

# Versão do painel (mude quando publicar release nova)
PANEL_VERSION="10.0.3"
INSTALL_PATH="/opt/xsp"

# ─── argumentos posicionais opcionais ────────────────────────────────────────
# Permitem rodar 100% sem interação: sudo bash install.sh KEY DOMÍNIO EMAIL
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

# ─── pré-checagens ───────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Rode como root: curl -sSL ... | sudo bash"
[[ -f /etc/os-release ]] || die "Sistema sem /etc/os-release."
. /etc/os-release
[[ "$ID" =~ ^(ubuntu|debian)$ ]] || die "SO não suportado: $ID (precisa Ubuntu/Debian)."

# Substitui pkg essenciais (curl, openssl, jq) silenciosamente
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq curl openssl jq util-linux ca-certificates \
    >/dev/null 2>&1 || die "apt-get install falhou."

[[ "${HMAC_PUBLIC_SECRET:0:2}" == "__" ]] \
  && die "Este instalador não foi configurado. Contate o fornecedor."

# ─── pede KEY, domínio, e-mail ───────────────────────────────────────────────
# Garante leitura interativa mesmo quando rodando via `curl | bash`
if [[ ! -t 0 && -z "${ARG_KEY:-}${ARG_DOMAIN:-}${ARG_EMAIL:-}" ]]; then
  exec </dev/tty 2>/dev/null || true
fi

# ─── KEY: prioriza argumento > input ─────────────────────────────────────────
LICENSE_KEY=$(echo "${ARG_KEY:-}" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
if [[ -z "$LICENSE_KEY" ]]; then
  read -rp "Informe sua KEY (formato XSP-XXXX-XXXX-XXXX-XXXX): " LICENSE_KEY
  LICENSE_KEY=$(echo "$LICENSE_KEY" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
fi
[[ "$LICENSE_KEY" =~ ^XSP-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$ ]] \
  || die "KEY com formato inválido."

# ─── Domínio: prioriza argumento > input ─────────────────────────────────────
PANEL_DOMAIN="${ARG_DOMAIN:-}"
if [[ -z "$PANEL_DOMAIN" ]]; then
  read -rp "Domínio público (ex: painel.cliente.com): " PANEL_DOMAIN
fi
[[ -n "$PANEL_DOMAIN" ]] || die "Domínio obrigatório."

# ─── E-mail: prioriza argumento > input ──────────────────────────────────────
ADMIN_EMAIL="${ARG_EMAIL:-}"
if [[ -z "$ADMIN_EMAIL" ]]; then
  read -rp "E-mail do administrador: " ADMIN_EMAIL
fi
[[ "$ADMIN_EMAIL" =~ @ ]] || die "E-mail inválido."

echo

# ─── checa portas ────────────────────────────────────────────────────────────
step "Verificando portas 80/443..."
for p in 80 443; do
  if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${p}$"; then
    die "Porta $p em uso. Libere antes de continuar."
  fi
done
ok "Portas livres."

# ─── cálculo do HWID (DEVE bater com license_check.php) ──────────────────────
step "Coletando fingerprint da máquina..."
MID=$(cat /etc/machine-id 2>/dev/null | tr -d '\r\n ')
BUUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr -d '\r\n ')
DUUID=$(blkid -s UUID -o value "$(findmnt -n -o SOURCE /)" 2>/dev/null | tr -d '\r\n ')

MAC=""
for addr in /sys/class/net/*/address; do
  iface=$(basename "$(dirname "$addr")")
  [[ "$iface" == "lo" ]] && continue
  state="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || true)"
  m=$(cat "$addr" 2>/dev/null | tr -d '\r\n ')
  [[ "$m" == "00:00:00:00:00:00" || -z "$m" ]] && continue
  MAC="$m"
  break
done

# sha256( machine_id || 0x1f || board_uuid || 0x1f || disk_uuid || 0x1f || mac )
HWID=$(printf '%s\x1f%s\x1f%s\x1f%s' "$MID" "$BUUID" "$DUUID" "$MAC" \
       | sha256sum | awk '{print $1}')
ok "HWID: ${HWID:0:16}…"

HOSTNAME_VAL=$(hostname)
PUBLIC_IP=$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || echo "")

# ─── chama POST /v1/activate com HMAC ────────────────────────────────────────
step "Ativando licença em $API_BASE ..."

BODY=$(cat <<JSON
{"key":"$LICENSE_KEY","hwid":"$HWID","hostname":"$HOSTNAME_VAL","public_ip":"$PUBLIC_IP","domain":"$PANEL_DOMAIN","email":"$ADMIN_EMAIL","os":"$ID","os_version":"$VERSION_ID","panel_version":"$PANEL_VERSION","installer_version":"$PANEL_VERSION","fingerprint":{"machine_id":"$MID","board_uuid":"$BUUID","disk_uuid":"$DUUID","mac":"$MAC"}}
JSON
)
BODY=$(echo -n "$BODY" | tr -d '\n')

TS=$(date +%s)
NONCE=$(openssl rand -hex 16)
METHOD="POST"
PATH_REQ="/v1/activate"

# HMAC-SHA256( method + path + body + ts + nonce )
SIG=$(
  { printf '%s' "${METHOD}${PATH_REQ}"
    printf '%s' "$BODY"
    printf '%s' "${TS}${NONCE}"
  } | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${HMAC_PUBLIC_SECRET}" -hex \
    | awk '{print $NF}'
)

HTTP_RESP=$(curl -sS --max-time 15 -w "\n%{http_code}" \
  -H "Content-Type: application/json" \
  -H "X-Timestamp: $TS" \
  -H "X-Nonce: $NONCE" \
  -H "X-Signature: $SIG" \
  -H "User-Agent: xsp-installer-bash/1.0" \
  -d "$BODY" \
  "${API_BASE}${PATH_REQ}")

HTTP_CODE=$(echo "$HTTP_RESP" | tail -n1)
HTTP_BODY=$(echo "$HTTP_RESP" | sed '$d')

case "$HTTP_CODE" in
  200|201) ok "Licença ativa." ;;
  402) die "Licença EXPIRADA. Renove pela área do cliente." ;;
  403) die "Acesso bloqueado (blacklist)." ;;
  404) die "KEY não encontrada. Confira se digitou corretamente." ;;
  409) die "Limite de instalações atingido para esta KEY." ;;
  410) die "Licença REVOGADA." ;;
  429) die "Muitas tentativas. Aguarde 1 minuto e tente de novo." ;;
  401) die "Falha de assinatura HMAC. Servidor pode estar offline ou hora errada (date: $(date -u)).";;
  *)   die "API retornou HTTP $HTTP_CODE: $HTTP_BODY" ;;
esac

# Parse JSON
INSTALLATION_ID=$(echo "$HTTP_BODY" | jq -r '.installation_id // empty')
REGISTRY_TOKEN=$(echo "$HTTP_BODY"  | jq -r '.registry_token // empty')
EXPIRES_AT=$(echo "$HTTP_BODY"      | jq -r '.expires_at // empty')
PANEL_IMAGE=$(echo "$HTTP_BODY"     | jq -r '.manifest.images[0].ref // empty')

[[ -n "$INSTALLATION_ID" ]] || die "Resposta sem installation_id"
[[ -n "$REGISTRY_TOKEN"  ]] || die "Resposta sem registry_token"
[[ -n "$PANEL_IMAGE"     ]] || PANEL_IMAGE="${REGISTRY_HOST}/xsp/panel:${PANEL_VERSION}"

ok "Instalação: ${INSTALLATION_ID:0:8}…  Expira: ${EXPIRES_AT:0:10}"

# ─── instala Docker ──────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  step "Instalando Docker..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable --now docker
  ok "Docker instalado."
else
  ok "Docker já presente."
fi

if ! docker compose version >/dev/null 2>&1; then
  warn "Docker Compose plugin ausente. Tentando instalar..."
  apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 \
    || die "docker compose não pôde ser instalado."
fi

# ─── configura registry HTTP (insecure) ──────────────────────────────────────
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
  systemctl restart docker 2>/dev/null || true
  sleep 2
fi
ok "Registry configurado."

# ─── login no registry ───────────────────────────────────────────────────────
step "Autenticando no registry privado..."
echo "$REGISTRY_TOKEN" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USER" --password-stdin >/dev/null 2>&1 \
  || die "Falha ao logar no registry $REGISTRY_HOST."
ok "Logado em $REGISTRY_HOST."

# ─── pull da imagem ──────────────────────────────────────────────────────────
step "Baixando imagem do painel ($PANEL_IMAGE)..."
docker pull "$PANEL_IMAGE" >/dev/null 2>&1 \
  || die "Falha ao baixar imagem $PANEL_IMAGE"
ok "Imagem baixada."

# ─── escreve compose + .env ──────────────────────────────────────────────────
step "Gerando configuração em $INSTALL_PATH ..."
mkdir -p "$INSTALL_PATH" "$INSTALL_PATH/certs" "$INSTALL_PATH/initdb"
chmod 750 "$INSTALL_PATH"

# Extrai SQL inicial da imagem do painel para o initdb
docker run --rm --entrypoint sh "$PANEL_IMAGE" \
  -c 'cat /var/www/html/docker-entrypoint-initdb.d/01-schema.sql 2>/dev/null || true' \
  > "$INSTALL_PATH/initdb/01-schema.sql"
if [[ -s "$INSTALL_PATH/initdb/01-schema.sql" ]]; then
  ok "SQL inicial extraído ($(wc -l < "$INSTALL_PATH/initdb/01-schema.sql") linhas)."
else
  rm -f "$INSTALL_PATH/initdb/01-schema.sql"
fi

DB_ROOT_PASS=$(openssl rand -hex 16)
DB_PASS=$(openssl rand -hex 16)

cat > "$INSTALL_PATH/.env" <<ENV
# Gerado pelo instalador XSP — NÃO EDITAR
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
  # Rede de saída: panel → internet (apenas API de licença)
  wan:
    driver: bridge
  # Rede interna: panel ↔ db — sem saída para internet
  db_net:
    driver: bridge
    internal: true
COMPOSE

ok "Configuração escrita."

# ─── sobe stack ──────────────────────────────────────────────────────────────
step "Subindo containers..."
cd "$INSTALL_PATH"
docker compose pull >/dev/null 2>&1 || true
docker compose up -d 2>&1 | tail -5

# ─── firewall: restringe saída do container panel à API de licença ───────────
step "Aplicando firewall anti-pirataria..."
# Resolve o IP da API de licença (apenas para regra iptables; falha silenciosamente)
API_HOST_ONLY=$(echo "$API_BASE" | sed 's|^https\?://||' | cut -d'/' -f1 | cut -d':' -f1)
API_IP=$(getent hosts "$API_HOST_ONLY" 2>/dev/null | awk '{print $1}' | head -1 || true)

# Obtém o nome da interface da rede wan do docker
WAN_IFACE=$(docker network inspect "$(docker compose ps -q panel | head -1 | xargs docker inspect --format '{{range $k,$v := .NetworkSettings.Networks}}{{if eq $k "xsp_wan"}}{{$v.NetworkID}}{{end}}{{end}}' 2>/dev/null)" \
  --format '{{.Options.com.docker.network.bridge.name}}' 2>/dev/null || true)
[[ -z "$WAN_IFACE" ]] && WAN_IFACE=$(ip link | grep -oP 'br-[a-f0-9]+' | head -1 || true)

if [[ -n "$API_IP" && -n "$WAN_IFACE" ]]; then
  # Bloqueia todo tráfego saindo pela bridge wan, exceto para a API de licença
  iptables -I FORWARD -i "$WAN_IFACE" -d "$API_IP" -j ACCEPT 2>/dev/null || true
  iptables -I FORWARD -i "$WAN_IFACE" ! -d "$API_IP" -j DROP 2>/dev/null || true
  ok "Firewall: saída do painel restrita a $API_HOST_ONLY ($API_IP)."
  # Persiste via iptables-save (disponível em Ubuntu)
  if command -v iptables-save >/dev/null 2>&1; then
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  fi
else
  warn "Firewall não aplicado (IP da API ou interface não detectados)."
  warn "Aplique manualmente: iptables -I FORWARD -i <br-wan> ! -d <API_IP> -j DROP"
fi

# ─── health check ────────────────────────────────────────────────────────────
step "Aguardando painel responder (até 120s)..."
HEALTHY=0
for i in {1..60}; do
  if curl -fsS --max-time 3 http://127.0.0.1/healthz >/dev/null 2>&1; then
    HEALTHY=1; break
  fi
  sleep 2
done

if [[ $HEALTHY -ne 1 ]]; then
  warn "Painel ainda não respondeu. Veja os logs:"
  echo "    docker compose -f $INSTALL_PATH/docker-compose.yml logs -f"
  exit 1
fi

# ─── resumo ──────────────────────────────────────────────────────────────────
echo
echo "${GRN}══════════════════════════════════════════════════════════════${NC}"
echo "${GRN}  INSTALAÇÃO CONCLUÍDA${NC}"
echo "${GRN}══════════════════════════════════════════════════════════════${NC}"
echo
echo "  ${CYN}Painel:${NC}        http://${PANEL_DOMAIN}/   (configure HTTPS depois)"
echo "  ${CYN}Local check:${NC}   http://$(hostname -I | awk '{print $1}')/"
echo "  ${CYN}Logs:${NC}          docker compose -f $INSTALL_PATH/docker-compose.yml logs -f"
echo "  ${CYN}Parar:${NC}         docker compose -f $INSTALL_PATH/docker-compose.yml down"
echo "  ${CYN}Reiniciar:${NC}     docker compose -f $INSTALL_PATH/docker-compose.yml restart"
echo
echo "  ${YEL}Licença:${NC}"
echo "    KEY:        $LICENSE_KEY"
echo "    Expira em:  ${EXPIRES_AT:0:10}"
echo "    Instalação: $INSTALLATION_ID"
echo
echo "  ${YEL}Para HTTPS com Let's Encrypt:${NC}"
echo "    apt install -y certbot && certbot certonly --standalone -d $PANEL_DOMAIN --email $ADMIN_EMAIL"
echo "    (depois copie certs para $INSTALL_PATH/certs/ e reinicie nginx no compose)"
echo
