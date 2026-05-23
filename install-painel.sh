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
INSTALL_URL="__INSTALL_URL__"

PANEL_VERSION="10.0.3"
INSTALL_PATH="/opt/xsp"
LOGFILE="/var/log/xsp-install.log"

[[ "$INSTALL_URL" == "__INSTALL""_URL__" ]] && INSTALL_URL="${API_BASE%/api*}/install.sh"

# ─── args ────────────────────────────────────────────────────────────────────
ARG_KEY="${1:-}"
ARG_DOMAIN="${2:-}"
ARG_EMAIL="${3:-}"

# ─── cores ───────────────────────────────────────────────────────────────────
RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; CYN=$'\033[1;36m'; NC=$'\033[0m'
step() { echo "${CYN}→${NC} $*"; }
ok()   { echo "${GRN}✓${NC} $*"; }
warn() { echo "${YEL}⚠${NC}  $*"; }
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
echo "=== XSP Install: $(date) | args: ${*:-nenhum} ==="

# ─── pré-checagens ───────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Rode como root: curl -sSL ... | sudo bash"
[[ -f /etc/os-release ]] || die "Sistema sem /etc/os-release."
. /etc/os-release
[[ "$ID" =~ ^(ubuntu|debian|centos|rhel|almalinux|rocky|fedora)$ ]] \
  || die "SO não suportado: $ID. Suporte: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky, Fedora."

[[ "${HMAC_PUBLIC_SECRET:0:2}" == "__" ]] \
  && die "Instalador não configurado. Contate o fornecedor."

# ─── gerenciador de pacotes ──────────────────────────────────────────────────
if [[ "$ID" =~ ^(ubuntu|debian)$ ]]; then
  export DEBIAN_FRONTEND=noninteractive
  pkg_install() { apt-get install -y -qq "$@" >/dev/null 2>&1; }
  pkg_update()  { apt-get update -qq 2>/dev/null; }
else
  # Instala EPEL em sistemas RHEL (necessário para jq)
  if [[ "$ID" =~ ^(centos|rhel|almalinux|rocky)$ ]]; then
    (dnf install -y epel-release 2>/dev/null || yum install -y epel-release 2>/dev/null || true)
  fi
  pkg_install() { (dnf install -y -q "$@" 2>/dev/null || yum install -y -q "$@" 2>/dev/null); }
  pkg_update()  { (dnf makecache -q 2>/dev/null || yum makecache -q 2>/dev/null || true); }
fi

# ─── funções auxiliares ──────────────────────────────────────────────────────
compute_hwid() {
  local mid buuid duuid mac=""
  mid=$(cat /etc/machine-id 2>/dev/null | tr -d '\r\n ' || echo "")
  buuid=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr -d '\r\n ' || echo "")
  # Tenta detectar UUID do disco raiz (falha graciosamente em containers)
  local dev
  dev=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
  duuid=$(blkid -s UUID -o value "$dev" 2>/dev/null | tr -d '\r\n ' || echo "")
  for addr in /sys/class/net/*/address; do
    local iface m
    iface=$(basename "$(dirname "$addr")")
    [[ "$iface" == "lo" ]] && continue
    m=$(cat "$addr" 2>/dev/null | tr -d '\r\n ')
    [[ "$m" == "00:00:00:00:00:00" || -z "$m" ]] && continue
    mac="$m"; break
  done
  printf '%s\x1f%s\x1f%s\x1f%s' "$mid" "$buuid" "$duuid" "$mac" | sha256sum | awk '{print $1}'
}

sign_hmac() {
  # sign_hmac METHOD PATH BODY TS NONCE
  local method="$1" path="$2" body="$3" ts="$4" nonce="$5"
  { printf '%s' "${method}${path}"; printf '%s' "$body"; printf '%s' "${ts}${nonce}"; } \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${HMAC_PUBLIC_SECRET}" -hex 2>/dev/null \
    | awk '{print $NF}'
}

port_in_use() {
  # Verifica se porta está em uso (ss ou netstat fallback)
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${1}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${1}$"
  else
    # Tenta conectar — porta livre retorna recusa (conexão negada = porta livre)
    ! (echo "" | timeout 1 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/${1}" 2>/dev/null)
  fi
}

daemon_json_add_registry() {
  local host="$1" daemon_json="/etc/docker/daemon.json"
  mkdir -p /etc/docker
  if [[ -f "$daemon_json" ]] && command -v jq >/dev/null 2>&1; then
    if ! jq -e ".\"insecure-registries\" | index(\"$host\")" "$daemon_json" >/dev/null 2>&1; then
      local tmp
      tmp=$(jq ".\"insecure-registries\" += [\"$host\"]" "$daemon_json") \
        && echo "$tmp" > "$daemon_json" \
        || warn "Não foi possível atualizar $daemon_json via jq"
      return 0  # indica que precisa restart
    fi
    return 1  # já existia, sem restart
  elif [[ -f "$daemon_json" ]]; then
    # jq não disponível ainda — verifica manualmente
    grep -q "\"$host\"" "$daemon_json" 2>/dev/null && return 1
    # Adiciona manualmente (assumindo JSON simples)
    local tmp
    tmp=$(cat "$daemon_json")
    if echo "$tmp" | grep -q '"insecure-registries"'; then
      # Injeta no array existente
      echo "$tmp" | sed "s|\"insecure-registries\": \[|\"insecure-registries\": [\"$host\", |" \
        > "$daemon_json"
    else
      # Adiciona campo ao objeto
      echo "$tmp" | sed "s|^{|{\"insecure-registries\": [\"$host\"],|" > "$daemon_json"
    fi
    return 0
  else
    printf '{"insecure-registries": ["%s"]}\n' "$host" > "$daemon_json"
    return 0
  fi
}

# ─── modo --status ───────────────────────────────────────────────────────────
do_status() {
  [[ -f "$INSTALL_PATH/.env" ]] || die "Nenhuma instalação encontrada em $INSTALL_PATH."
  # shellcheck disable=SC1090
  set -a; source "$INSTALL_PATH/.env"; set +a
  echo
  echo "  ${CYN}KEY:${NC}            ${XSP_LICENSE_KEY:-?}"
  echo "  ${CYN}Instalação:${NC}     ${XSP_INSTALLATION_ID:-?}"
  echo "  ${CYN}Versão:${NC}         ${XSP_VERSION:-?}"
  echo "  ${CYN}API:${NC}            ${XSP_API_BASE:-?}"
  echo
  echo "  ${CYN}Containers:${NC}"
  docker compose -f "$INSTALL_PATH/docker-compose.yml" ps 2>/dev/null \
    || echo "    Stack não encontrada."
  echo
  # Consulta status na API
  local resp status days
  resp=$(curl -s --max-time 8 -X POST "${XSP_API_BASE:-}/portal/status" \
    -H "Content-Type: application/json" \
    -d "{\"key\":\"${XSP_LICENSE_KEY:-}\"}" 2>/dev/null || echo "{}")
  if command -v jq >/dev/null 2>&1; then
    status=$(echo "$resp" | jq -r '.status // "?"' 2>/dev/null || echo "?")
    days=$(echo "$resp"   | jq -r '.days_left // "?"' 2>/dev/null || echo "?")
  else
    status=$(echo "$resp" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || echo "?")
    days=$(echo "$resp"   | grep -o '"days_left":[0-9]*' | cut -d: -f2 || echo "?")
  fi
  echo "  ${CYN}Licença:${NC}        $status  |  $days dias restantes"
  echo
}

# ─── modo --update ───────────────────────────────────────────────────────────
do_update() {
  [[ -f "$INSTALL_PATH/.env" ]] || die "Nenhuma instalação encontrada em $INSTALL_PATH. Instale primeiro."
  # shellcheck disable=SC1090
  set -a; source "$INSTALL_PATH/.env"; set +a
  step "Modo atualização — verificando licença..."

  # Heartbeat para validar licença antes de atualizar
  local ts nonce body sig http_code
  ts=$(date +%s); nonce=$(openssl rand -hex 16 2>/dev/null || echo "00000000")
  body=$(jq -cn \
    --arg installation_id "${XSP_INSTALLATION_ID:-}" \
    --arg hwid "${XSP_HWID:-}" \
    --arg panel_version "${XSP_VERSION:-}" \
    '{installation_id: $installation_id, hwid: $hwid, panel_version: $panel_version}')
  sig=$(sign_hmac "POST" "/v1/heartbeat" "$body" "$ts" "$nonce")
  http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -X POST "${XSP_API_BASE:-}/v1/heartbeat" \
    -H "Content-Type: application/json" \
    -H "X-Installation-ID: ${XSP_INSTALLATION_ID:-}" \
    -H "X-Timestamp: $ts" -H "X-Nonce: $nonce" -H "X-Signature: $sig" \
    -d "$body" 2>/dev/null || echo "000")
  case "$http_code" in
    200|201) ok "Licença válida." ;;
    402) die "Licença expirada. Renove antes de atualizar." ;;
    410) die "Licença revogada." ;;
    403) die "Acesso bloqueado." ;;
    *)   warn "API retornou $http_code — continuando mesmo assim..." ;;
  esac

  step "Atualizando imagem do painel..."
  echo "${REGISTRY_STORED_TOKEN:-}" \
    | docker login "${REGISTRY_STORED_HOST:-}" -u "${REGISTRY_STORED_USER:-}" --password-stdin >/dev/null 2>&1 \
    || die "Falha ao autenticar no registry. Registry token pode ter expirado — reinstale."

  cd "$INSTALL_PATH"
  docker compose pull 2>&1 | grep -E "Pull|pull|Pulling|pulled|up.to.date" || true
  docker compose up -d --remove-orphans
  ok "Painel atualizado com sucesso."
  echo
  echo "  ${CYN}Logs:${NC}        docker compose -f $INSTALL_PATH/docker-compose.yml logs -f"
  echo "  ${CYN}Desinstalar:${NC} sudo bash $INSTALL_PATH/uninstall.sh"
  echo
}

# ─── verificação de espaço em disco ──────────────────────────────────────────
step "Verificando espaço em disco..."
# Verifica no ponto de montagem de /, mais confiável que checar /opt que pode não existir
AVAIL_GB=$(df -BG / 2>/dev/null | tail -1 | awk '{gsub(/G/,""); print $4}' || echo "0")
AVAIL_GB="${AVAIL_GB//[^0-9]/}"
AVAIL_GB="${AVAIL_GB:-0}"
if [[ "$AVAIL_GB" -lt 5 ]]; then
  die "Espaço insuficiente: ${AVAIL_GB}GB disponível (mínimo 5GB)."
fi
ok "Espaço disponível: ${AVAIL_GB}GB."

# ─── despacha modos especiais ─────────────────────────────────────────────────
if [[ "$ARG_KEY" == "--status" ]]; then
  do_status
  exit 0
fi

if [[ "$ARG_KEY" == "--update" ]]; then
  do_update
  exit 0
fi

# ─── instala dependências ────────────────────────────────────────────────────
step "Atualizando repositórios..."
pkg_update

step "Instalando dependências (curl, openssl, jq, iproute2...)..."
if [[ "$ID" =~ ^(ubuntu|debian)$ ]]; then
  pkg_install curl openssl jq iproute2 util-linux ca-certificates
else
  pkg_install curl openssl jq iproute util-linux ca-certificates
fi
ok "Dependências instaladas."

# ─── instala Docker ──────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  step "Instalando Docker (via get.docker.com)..."
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable --now docker >/dev/null 2>&1
  ok "Docker instalado."
else
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) já presente."
fi

# Garante docker compose (plugin)
if ! docker compose version >/dev/null 2>&1; then
  step "Instalando docker-compose-plugin..."
  if [[ "$ID" =~ ^(ubuntu|debian)$ ]]; then
    pkg_install docker-compose-plugin
  else
    pkg_install docker-compose-plugin || pkg_install docker-compose
  fi
  docker compose version >/dev/null 2>&1 \
    || die "docker compose não pôde ser instalado. Verifique sua distro."
fi
ok "docker compose $(docker compose version --short 2>/dev/null || echo 'ok')."

# ─── configura insecure-registry (para registries HTTP) ─────────────────────
REGISTRY_HOST_ONLY=$(echo "$REGISTRY_HOST" | cut -d'/' -f1)
# Só configura insecure-registry se o host não usar HTTPS (sem ponto implica IP ou porta)
if echo "$REGISTRY_HOST_ONLY" | grep -qE ':[0-9]+$|^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
  step "Configurando insecure-registry ($REGISTRY_HOST_ONLY)..."
  if daemon_json_add_registry "$REGISTRY_HOST_ONLY"; then
    systemctl restart docker >/dev/null 2>&1 || true
    sleep 2
    ok "Docker reiniciado com insecure-registry."
  else
    ok "insecure-registry já configurado."
  fi
fi

# ─── detecção de instalação existente ────────────────────────────────────────
if [[ -f "$INSTALL_PATH/.env" ]]; then
  warn "Instalação existente detectada em $INSTALL_PATH."
  echo
  echo "  Opções:"
  echo "    [1] Reinstalar (mantém banco de dados)"
  echo "    [2] Atualizar imagem (mais rápido, sem reinstalar)"
  echo "    [3] Cancelar"
  echo

  if [[ -t 0 ]]; then
    read -rp "  Escolha [1/2/3]: " CHOICE
  else
    CHOICE="1"
    warn "Modo não-interativo: reinstalando automaticamente."
  fi

  case "${CHOICE:-1}" in
    2) do_update; exit 0 ;;   # chama função, não exec bash $0
    3) echo "Cancelado."; exit 0 ;;
    *) warn "Reinstalando — banco de dados será preservado." ;;
  esac
fi

# ─── coleta interativa ───────────────────────────────────────────────────────
# Detecta se stdin é um terminal (interativo) ou pipe (não-interativo, ex: curl|bash)
_INTERACTIVE=false
if [[ -t 0 ]]; then
  _INTERACTIVE=true
elif exec </dev/tty 2>/dev/null; then
  _INTERACTIVE=true
fi

LICENSE_KEY=$(echo "${ARG_KEY:-}" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
if [[ -z "$LICENSE_KEY" ]]; then
  if [[ "$_INTERACTIVE" == "true" ]]; then
    read -rp "KEY (formato XSP-XXXX-XXXX-XXXX-XXXX): " LICENSE_KEY
    LICENSE_KEY=$(echo "$LICENSE_KEY" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
  fi
fi
[[ "$LICENSE_KEY" =~ ^XSP-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$ ]] \
  || die "KEY inválida: '$LICENSE_KEY'. Formato esperado: XSP-XXXX-XXXX-XXXX-XXXX"

PANEL_DOMAIN="${ARG_DOMAIN:-}"
if [[ -z "$PANEL_DOMAIN" && "$_INTERACTIVE" == "true" ]]; then
  read -rp "Domínio ou IP público do painel (ex: painel.cliente.com ou 1.2.3.4): " PANEL_DOMAIN
fi
# Fallback automático: usa IP público da máquina
if [[ -z "$PANEL_DOMAIN" ]]; then
  PANEL_DOMAIN=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
fi
[[ -n "$PANEL_DOMAIN" ]] || die "Não foi possível detectar o IP da máquina."

ADMIN_EMAIL="${ARG_EMAIL:-}"
if [[ -z "$ADMIN_EMAIL" && "$_INTERACTIVE" == "true" ]]; then
  read -rp "E-mail do administrador: " ADMIN_EMAIL
fi
# Fallback: e-mail genérico
[[ -n "$ADMIN_EMAIL" ]] || ADMIN_EMAIL="admin@${PANEL_DOMAIN}"
[[ "$ADMIN_EMAIL" =~ @ ]] || die "E-mail inválido: '$ADMIN_EMAIL'"
echo

# ─── checa portas ────────────────────────────────────────────────────────────
step "Verificando portas 80/443..."
for p in 80 443; do
  if port_in_use "$p"; then
    die "Porta $p já está em uso. Identifique o processo e pare-o antes de continuar.
  Dica: lsof -i :$p  ou  ss -tlnp | grep :$p"
  fi
done
ok "Portas 80 e 443 livres."

# ─── HWID ────────────────────────────────────────────────────────────────────
step "Coletando fingerprint da máquina..."
MID=$(cat /etc/machine-id 2>/dev/null | tr -d '\r\n ')
BUUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr -d '\r\n ' || echo "")
DEV_ROOT=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
DUUID=$(blkid -s UUID -o value "$DEV_ROOT" 2>/dev/null | tr -d '\r\n ' || echo "")
MAC=""
for addr in /sys/class/net/*/address; do
  iface=$(basename "$(dirname "$addr")")
  [[ "$iface" == "lo" ]] && continue
  m=$(cat "$addr" 2>/dev/null | tr -d '\r\n ')
  [[ "$m" == "00:00:00:00:00:00" || -z "$m" ]] && continue
  MAC="$m"; break
done
HWID=$(printf '%s\x1f%s\x1f%s\x1f%s' "$MID" "$BUUID" "$DUUID" "$MAC" | sha256sum | awk '{print $1}')
[[ -n "$MID" ]] || die "Não foi possível ler /etc/machine-id. Máquina inválida."
ok "HWID: ${HWID:0:16}…"

HOSTNAME_VAL=$(hostname -f 2>/dev/null || hostname)
PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
          || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
          || hostname -I 2>/dev/null | awk '{print $1}' || echo "")

# ─── verifica conectividade com a API ────────────────────────────────────────
step "Verificando conectividade com $API_BASE ..."
if ! curl -fsSL --max-time 8 "${API_BASE}/healthz" >/dev/null 2>&1; then
  warn "Não foi possível acessar ${API_BASE}/healthz"
  warn "Verifique se o servidor de licenças está online e acessível nesta VPS."
  warn "Tentando prosseguir mesmo assim..."
fi

# ─── ativa licença ───────────────────────────────────────────────────────────
step "Ativando licença $LICENSE_KEY em $API_BASE ..."

# Usa jq para construir o JSON (evita problemas com caracteres especiais)
BODY=$(jq -cn \
  --arg key     "$LICENSE_KEY" \
  --arg hwid    "$HWID" \
  --arg host    "$HOSTNAME_VAL" \
  --arg ip      "$PUBLIC_IP" \
  --arg domain  "$PANEL_DOMAIN" \
  --arg email   "$ADMIN_EMAIL" \
  --arg os      "$ID" \
  --arg osver   "${VERSION_ID:-}" \
  --arg pver    "$PANEL_VERSION" \
  --arg iver    "$PANEL_VERSION" \
  --arg mid     "$MID" \
  --arg buuid   "$BUUID" \
  --arg duuid   "$DUUID" \
  --arg mac     "$MAC" \
  '{
    key: $key, hwid: $hwid, hostname: $host,
    public_ip: $ip, domain: $domain, email: $email,
    os: $os, os_version: $osver,
    panel_version: $pver, installer_version: $iver,
    fingerprint: {machine_id: $mid, board_uuid: $buuid, disk_uuid: $duuid, mac: $mac}
  }')

TS=$(date +%s); NONCE=$(openssl rand -hex 16)
SIG=$(sign_hmac "POST" "/v1/activate" "$BODY" "$TS" "$NONCE")

HTTP_RESP=$(curl -sS --max-time 20 -w "\n%{http_code}" \
  -H "Content-Type: application/json" \
  -H "X-Timestamp: $TS" -H "X-Nonce: $NONCE" -H "X-Signature: $SIG" \
  -H "User-Agent: xsp-installer-bash/2.0" \
  -d "$BODY" "${API_BASE}/v1/activate")
HTTP_CODE=$(echo "$HTTP_RESP" | tail -1)
HTTP_BODY=$(echo "$HTTP_RESP" | head -n -1)

case "$HTTP_CODE" in
  200|201) ok "Licença ativada." ;;
  400) die "Requisição inválida (400). Verifique a KEY: $HTTP_BODY" ;;
  401) die "Falha na assinatura HMAC (401). Verifique data/hora: $(date -u). Body: $HTTP_BODY" ;;
  402) die "Licença EXPIRADA (402). Renove pela área do cliente." ;;
  403) die "Acesso bloqueado — blacklist (403): $HTTP_BODY" ;;
  404) die "KEY não encontrada (404). Verifique se a KEY está correta: $LICENSE_KEY" ;;
  409) die "Limite de instalações atingido (409). Libere uma instalação existente antes de continuar." ;;
  410) die "Licença REVOGADA (410). Entre em contato com o suporte." ;;
  429) die "Muitas tentativas (429). Aguarde alguns minutos e tente novamente." ;;
  000) die "Sem resposta da API. Verifique a conectividade com $API_BASE" ;;
  *)   die "Erro inesperado da API — HTTP $HTTP_CODE: $HTTP_BODY" ;;
esac

INSTALLATION_ID=$(echo "$HTTP_BODY" | jq -r '.installation_id // empty')
REGISTRY_TOKEN=$(echo "$HTTP_BODY"  | jq -r '.registry_token  // empty')
EXPIRES_AT=$(echo "$HTTP_BODY"      | jq -r '.expires_at       // empty')
PANEL_IMAGE=$(echo "$HTTP_BODY"     | jq -r '.manifest.images[0].ref // empty')

[[ -n "$INSTALLATION_ID" ]] || die "Resposta da API inválida: campo installation_id ausente. Body: $HTTP_BODY"
[[ -n "$REGISTRY_TOKEN"  ]] || die "Resposta da API inválida: campo registry_token ausente. Body: $HTTP_BODY"
[[ -n "$PANEL_IMAGE"     ]] && ok "Imagem: $PANEL_IMAGE" \
  || PANEL_IMAGE="${REGISTRY_HOST}/xsp/panel:${PANEL_VERSION}"
ok "Instalação: ${INSTALLATION_ID:0:8}…  Expira: ${EXPIRES_AT:0:10}"

# ─── login + pull ─────────────────────────────────────────────────────────────
step "Autenticando no registry $REGISTRY_HOST ..."
echo "$REGISTRY_TOKEN" | docker login "$REGISTRY_HOST" -u "$REGISTRY_USER" --password-stdin \
  || die "Falha ao autenticar no registry. Verifique conectividade com $REGISTRY_HOST"
ok "Logado em $REGISTRY_HOST."

step "Baixando imagem ($PANEL_IMAGE)..."
docker pull "$PANEL_IMAGE" 2>&1 | grep -E "Pull|Pulling|pull|Downloaded|up.to.date|latest" || true
ok "Imagem pronta."

# ─── escreve configuração ────────────────────────────────────────────────────
step "Criando diretórios em $INSTALL_PATH ..."
mkdir -p "$INSTALL_PATH" "$INSTALL_PATH/certs" "$INSTALL_PATH/initdb"
chmod 750 "$INSTALL_PATH"

# Extrai SQL inicial da imagem (falha graciosamente — imagens sem SQL são válidas)
if docker run --rm --entrypoint sh "$PANEL_IMAGE" \
    -c 'test -f /var/www/html/docker-entrypoint-initdb.d/01-schema.sql' >/dev/null 2>&1; then
  docker run --rm --entrypoint sh "$PANEL_IMAGE" \
    -c 'cat /var/www/html/docker-entrypoint-initdb.d/01-schema.sql' \
    > "$INSTALL_PATH/initdb/01-schema.sql" 2>/dev/null || true
  [[ -s "$INSTALL_PATH/initdb/01-schema.sql" ]] && ok "SQL inicial extraído." || rm -f "$INSTALL_PATH/initdb/01-schema.sql"
fi

# Preserva senhas do banco se estiver reinstalando
OLD_DB_PASS=""; OLD_DB_ROOT=""
if [[ -f "$INSTALL_PATH/.env" ]]; then
  OLD_DB_PASS=$(grep -E "^DB_PASS="     "$INSTALL_PATH/.env" | cut -d= -f2- || echo "")
  OLD_DB_ROOT=$(grep -E "^DB_ROOT_PASS=" "$INSTALL_PATH/.env" | cut -d= -f2- || echo "")
fi
DB_PASS="${OLD_DB_PASS:-$(openssl rand -hex 16)}"
DB_ROOT_PASS="${OLD_DB_ROOT:-$(openssl rand -hex 16)}"

step "Escrevendo configuração..."
cat > "$INSTALL_PATH/.env" <<ENV
# Gerado pelo instalador XSP — não edite manualmente
XSP_LICENSE_KEY=${LICENSE_KEY}
XSP_INSTALLATION_ID=${INSTALLATION_ID}
XSP_HWID=${HWID}
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

# docker-compose.yml com heredoc sem expansão (variáveis resolvidas pelo compose via .env)
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
      - ./initdb:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
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
[[ \$EUID -eq 0 ]] || { echo "\${RED}Rode como root\${NC}" >&2; exit 1; }

INSTALL_PATH="${INSTALL_PATH}"
LOGFILE="${LOGFILE}"
REGISTRY_HOST="${REGISTRY_HOST}"

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
  set -a; source "\$INSTALL_PATH/.env"; set +a
  echo "\${CYN}→\${NC} Desativando licença na API..."
  TS=\$(date +%s); NONCE=\$(openssl rand -hex 16 2>/dev/null || echo "0")
  BODY="{}"
  SIG=\$({ printf '%s' "POST/v1/deactivate"; printf '%s' "\$BODY"; printf '%s' "\${TS}\${NONCE}"; } \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:\${XSP_PUBLIC_SECRET:-}" -hex 2>/dev/null \
    | awk '{print \$NF}' || echo "")
  curl -s --max-time 8 -X POST "\${XSP_API_BASE:-}/v1/deactivate" \
    -H "Content-Type: application/json" \
    -H "X-Installation-ID: \${XSP_INSTALLATION_ID:-}" \
    -H "X-Timestamp: \$TS" -H "X-Nonce: \$NONCE" -H "X-Signature: \$SIG" \
    -d "\$BODY" >/dev/null 2>&1 \
    && echo "\${GRN}✓\${NC} Licença desativada — KEY pode ser reutilizada." \
    || echo "\${YEL}⚠\${NC} Não foi possível contatar a API — prosseguindo."
fi

# Para e remove containers + volumes
echo "\${CYN}→\${NC} Parando containers e removendo volumes..."
docker compose -f "\$INSTALL_PATH/docker-compose.yml" down -v 2>/dev/null || true
echo "\${GRN}✓\${NC} Containers e volumes removidos."

# Limpa regras de firewall relacionadas (melhor esforço)
iptables -D FORWARD -i \$(ip link 2>/dev/null | grep -oP 'br-[a-f0-9]+' | head -1) \
  -j DROP 2>/dev/null || true

# Remove diretório
echo "\${CYN}→\${NC} Removendo \$INSTALL_PATH ..."
rm -rf "\$INSTALL_PATH"
echo "\${GRN}✓\${NC} Arquivos removidos."

docker logout "\$REGISTRY_HOST" >/dev/null 2>&1 || true

echo
echo "\${GRN}✓ Desinstalação concluída!\${NC}"
echo "  KEY \${XSP_LICENSE_KEY:-?} pode ser reutilizada em outra VPS."
echo
UNINSTALL
chmod 750 "$INSTALL_PATH/uninstall.sh"
ok "Configuração e uninstall.sh gerados."

# ─── sobe stack ──────────────────────────────────────────────────────────────
step "Subindo containers (MariaDB pode demorar até 60s na 1ª vez)..."
cd "$INSTALL_PATH"
if ! docker compose up -d --remove-orphans 2>&1; then
  die "Falha ao subir os containers. Verifique: docker compose -f $INSTALL_PATH/docker-compose.yml logs"
fi
ok "Containers iniciados."

# ─── firewall anti-pirataria ──────────────────────────────────────────────────
step "Aplicando regras de firewall..."
API_HOST_ONLY=$(echo "$API_BASE" | sed 's|^https\?://||' | cut -d'/' -f1 | cut -d':' -f1)
API_IP=$(getent hosts "$API_HOST_ONLY" 2>/dev/null | awk '{print $1}' | head -1 \
       || dig +short "$API_HOST_ONLY" 2>/dev/null | grep -oE '^[0-9.]+' | head -1 || echo "")
PANEL_ID=$(docker compose ps -q panel 2>/dev/null | head -1 || echo "")
WAN_IFACE=""
if [[ -n "$PANEL_ID" ]]; then
  WAN_NET=$(docker inspect "$PANEL_ID" \
    --format '{{range $k,$v := .NetworkSettings.Networks}}{{if eq $k "xsp_wan"}}{{$v.NetworkID}}{{end}}{{end}}' \
    2>/dev/null || echo "")
  [[ -n "$WAN_NET" ]] && WAN_IFACE=$(docker network inspect "$WAN_NET" \
    --format '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null || echo "")
fi
[[ -z "$WAN_IFACE" ]] && WAN_IFACE=$(ip link 2>/dev/null | grep -oP 'br-[a-f0-9]+' | head -1 || echo "")

if [[ -n "$API_IP" && -n "$WAN_IFACE" ]]; then
  iptables -I FORWARD -i "$WAN_IFACE" -d "$API_IP" -j ACCEPT 2>/dev/null || true
  iptables -I FORWARD -i "$WAN_IFACE" ! -d "$API_IP" -j DROP  2>/dev/null || true
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
  ok "Firewall: saída do painel restrita a $API_HOST_ONLY ($API_IP)."
else
  warn "Firewall não aplicado (IP da API: '${API_IP:-?}', interface: '${WAN_IFACE:-?}')."
  warn "O painel funcionará normalmente, mas sem restrição de saída."
fi

# ─── health check ────────────────────────────────────────────────────────────
step "Aguardando painel responder (até 120s)..."
HEALTHY=0
for i in {1..60}; do
  # Tenta vários endpoints comuns
  if curl -fsS --max-time 3 -o /dev/null http://127.0.0.1/ 2>/dev/null \
  || curl -fsS --max-time 3 -o /dev/null http://127.0.0.1/healthz 2>/dev/null \
  || curl -fsS --max-time 3 -o /dev/null http://127.0.0.1/index.php 2>/dev/null; then
    HEALTHY=1; break
  fi
  # Verifica se a porta está escutando (mais confiável que curl em alguns casos)
  if (echo "" | timeout 1 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/80" 2>/dev/null); then
    HEALTHY=1; break
  fi
  sleep 2
done

if [[ $HEALTHY -eq 1 ]]; then
  ok "Painel respondendo na porta 80."
else
  warn "Painel não respondeu ainda (pode estar iniciando o MariaDB)."
  warn "Verifique os logs:"
  docker compose -f "$INSTALL_PATH/docker-compose.yml" logs --tail=20 2>/dev/null || true
fi

# ─── resumo ──────────────────────────────────────────────────────────────────
echo
echo "${GRN}══════════════════════════════════════════════════════════════${NC}"
echo "${GRN}  INSTALAÇÃO CONCLUÍDA!${NC}"
echo "${GRN}══════════════════════════════════════════════════════════════${NC}"
echo
LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "?")
echo "  ${CYN}Painel:${NC}      http://${PANEL_DOMAIN}/"
echo "  ${CYN}Local:${NC}       http://${LOCAL_IP}/"
echo
echo "  ${YEL}Licença:${NC}"
echo "    KEY:       $LICENSE_KEY"
echo "    Expira:    ${EXPIRES_AT:0:10}"
echo "    ID:        $INSTALLATION_ID"
echo
echo "  ${YEL}Comandos úteis:${NC}"
echo "    Logs:       docker compose -f $INSTALL_PATH/docker-compose.yml logs -f"
echo "    Reiniciar:  docker compose -f $INSTALL_PATH/docker-compose.yml restart"
echo "    Status:     curl -sSL ${INSTALL_URL} | sudo bash -s -- --status"
echo "    Atualizar:  curl -sSL ${INSTALL_URL} | sudo bash -s -- --update"
echo "    Desinstalar: sudo bash $INSTALL_PATH/uninstall.sh"
echo
echo "  ${YEL}Log desta instalação:${NC} $LOGFILE"
echo
