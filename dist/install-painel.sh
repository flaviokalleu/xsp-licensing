#!/usr/bin/env bash
###############################################################################
# XSP - Instalador automatico do painel cliente
#
# Fluxo atual:
#   - valida a licenca na API central
#   - baixa o painel direto do GitHub
#   - gera uma imagem Docker local na VPS do cliente
#   - sobe panel + MariaDB via docker compose
#
# Uso:
#   curl -sSL http://SEU_IP/install.sh | sudo bash -s -- XSP-KEY dominio email
#   curl -sSL http://SEU_IP/install.sh | sudo bash -s -- --status
#   curl -sSL http://SEU_IP/install.sh | sudo bash -s -- --update
###############################################################################
set -euo pipefail

API_BASE="https://license.seudominio.com"
HMAC_PUBLIC_SECRET="__HMAC_PUBLIC_SECRET_64_HEX_CHARS__"
INSTALL_URL="__INSTALL_URL__"

PANEL_VERSION="10.0.3"
PANEL_REPO="flaviokalleu/xsp-painel"
PANEL_REF="main"
PANEL_RELEASE_URL="https://github.com/${PANEL_REPO}/releases/latest/download/xsp-painel-source.zip"
PANEL_SOURCE_URL="https://github.com/${PANEL_REPO}/archive/refs/heads/${PANEL_REF}.zip"

INSTALL_PATH="/opt/xsp"
LOGFILE="/var/log/xsp-install.log"
LOCAL_IMAGE="xsp/panel-local:${PANEL_VERSION}"

[[ "$INSTALL_URL" == "__INSTALL""_URL__" ]] && INSTALL_URL="${API_BASE%/api*}/install.sh"

ARG_KEY="${1:-}"
ARG_DOMAIN="${2:-}"
ARG_EMAIL="${3:-}"

RED=$'\033[1;31m'; GRN=$'\033[1;32m'; YEL=$'\033[1;33m'; CYN=$'\033[1;36m'; NC=$'\033[0m'
step() { echo "${CYN}->${NC} $*"; }
ok()   { echo "${GRN}OK${NC} $*"; }
warn() { echo "${YEL}WARN${NC} $*"; }
die()  { echo "${RED}ERRO:${NC} $*" >&2; exit 1; }

clear || true
cat <<'BANNER'
===============================================================
  PAINEL OFFICE XTREAM - Instalador Automatico v10
  Valida licenca e instala o painel direto do GitHub.
===============================================================
BANNER
echo

mkdir -p /var/log
exec > >(tee -a "$LOGFILE") 2>&1
echo "=== XSP Install: $(date) | args: ${*:-nenhum} ==="

[[ $EUID -eq 0 ]] || die "Rode como root: curl -sSL ... | sudo bash"
[[ -f /etc/os-release ]] || die "Sistema sem /etc/os-release."
. /etc/os-release
[[ "$ID" =~ ^(ubuntu|debian|centos|rhel|almalinux|rocky|fedora)$ ]] \
  || die "SO nao suportado: $ID. Suporte: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky, Fedora."

[[ "${HMAC_PUBLIC_SECRET:0:2}" == "__" ]] \
  && die "Instalador nao configurado. Configure HMAC_PUBLIC_SECRET antes de publicar."

if [[ "$ID" =~ ^(ubuntu|debian)$ ]]; then
  export DEBIAN_FRONTEND=noninteractive
  pkg_install() { apt-get install -y -qq "$@" >/dev/null 2>&1; }
  pkg_update()  { apt-get update -qq 2>/dev/null; }
else
  if [[ "$ID" =~ ^(centos|rhel|almalinux|rocky)$ ]]; then
    (dnf install -y epel-release 2>/dev/null || yum install -y epel-release 2>/dev/null || true)
  fi
  pkg_install() { (dnf install -y -q "$@" 2>/dev/null || yum install -y -q "$@" 2>/dev/null); }
  pkg_update()  { (dnf makecache -q 2>/dev/null || yum makecache -q 2>/dev/null || true); }
fi

curl_retry() {
  curl -fsSL --connect-timeout 10 --retry 3 --retry-delay 3 "$@"
}

run_timeout() {
  local limit="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$limit" "$@"
  else
    "$@"
  fi
}

json_get() {
  jq -r "$1 // empty" 2>/dev/null
}

compute_hwid() {
  local mid buuid duuid mac="" dev
  mid=$(cat /etc/machine-id 2>/dev/null | tr -d '\r\n ' || echo "")
  buuid=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr -d '\r\n ' || echo "")
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
  local method="$1" path="$2" body="$3" ts="$4" nonce="$5"
  { printf '%s' "${method}${path}"; printf '%s' "$body"; printf '%s' "${ts}${nonce}"; } \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:${HMAC_PUBLIC_SECRET}" -hex 2>/dev/null \
    | awk '{print $NF}'
}

port_in_use() {
  if command -v ss >/dev/null 2>&1; then
    ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${1}$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -qE ":${1}$"
  else
    ! (echo "" | timeout 1 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/${1}" 2>/dev/null)
  fi
}

ensure_dependencies() {
  step "Atualizando repositorios..."
  pkg_update

  step "Instalando dependencias..."
  if [[ "$ID" =~ ^(ubuntu|debian)$ ]]; then
    pkg_install curl openssl jq iproute2 util-linux ca-certificates unzip tar
  else
    pkg_install curl openssl jq iproute util-linux ca-certificates unzip tar
  fi
  ok "Dependencias instaladas."
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    step "Instalando Docker..."
    curl_retry https://get.docker.com | sh >/dev/null 2>&1
    systemctl enable --now docker >/dev/null 2>&1 || true
    ok "Docker instalado."
  else
    ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) ja presente."
  fi

  if ! docker compose version >/dev/null 2>&1; then
    step "Instalando docker compose..."
    if [[ "$ID" =~ ^(ubuntu|debian)$ ]]; then
      pkg_install docker-compose-plugin
    else
      pkg_install docker-compose-plugin || pkg_install docker-compose
    fi
  fi
  docker compose version >/dev/null 2>&1 \
    || die "docker compose nao pode ser instalado."
  ok "docker compose $(docker compose version --short 2>/dev/null || echo ok)."
}

validate_license_key() {
  LICENSE_KEY=$(echo "${ARG_KEY:-}" | tr '[:lower:]' '[:upper:]' | tr -d ' ')
  [[ "$LICENSE_KEY" =~ ^XSP-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$ ]] \
    || die "KEY invalida ou ausente. Use: bash install.sh XSP-XXXX-XXXX-XXXX-XXXX dominio email"
}

detect_domain_email() {
  PANEL_DOMAIN="${ARG_DOMAIN:-}"
  if [[ -z "$PANEL_DOMAIN" ]]; then
    PANEL_DOMAIN=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
      || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
      || hostname -I 2>/dev/null | awk '{print $1}' || echo "")
    warn "Dominio/IP nao informado; usando detectado: ${PANEL_DOMAIN:-?}"
  fi
  [[ -n "$PANEL_DOMAIN" ]] || die "Nao foi possivel detectar o IP publico. Informe dominio/IP como segundo argumento."

  ADMIN_EMAIL="${ARG_EMAIL:-}"
  [[ -n "$ADMIN_EMAIL" ]] || ADMIN_EMAIL="admin@${PANEL_DOMAIN}"
  [[ "$ADMIN_EMAIL" =~ @ ]] || die "E-mail invalido: $ADMIN_EMAIL"
}

activate_license() {
  step "Coletando fingerprint da maquina..."
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
  [[ -n "$MID" ]] || die "Nao foi possivel ler /etc/machine-id."
  ok "HWID: ${HWID:0:16}..."

  HOSTNAME_VAL=$(hostname -f 2>/dev/null || hostname)
  PUBLIC_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null \
            || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null \
            || hostname -I 2>/dev/null | awk '{print $1}' || echo "")

  step "Verificando conectividade com $API_BASE ..."
  if ! curl -fsSL --max-time 8 "${API_BASE}/healthz" >/dev/null 2>&1; then
    warn "Nao foi possivel acessar ${API_BASE}/healthz; tentando ativar mesmo assim."
  fi

  step "Ativando licenca $LICENSE_KEY ..."
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

  TS=$(date +%s)
  NONCE=$(openssl rand -hex 16)
  SIG=$(sign_hmac "POST" "/v1/activate" "$BODY" "$TS" "$NONCE")

  HTTP_RESP=$(curl -sS --connect-timeout 10 --max-time 25 -w "\n%{http_code}" \
    -H "Content-Type: application/json" \
    -H "X-Timestamp: $TS" -H "X-Nonce: $NONCE" -H "X-Signature: $SIG" \
    -H "User-Agent: xsp-installer-github/1.0" \
    -d "$BODY" "${API_BASE}/v1/activate" 2>/dev/null || printf "\n000")
  HTTP_CODE=$(echo "$HTTP_RESP" | tail -1)
  HTTP_BODY=$(echo "$HTTP_RESP" | sed '$d')

  case "$HTTP_CODE" in
    200|201) ok "Licenca ativada." ;;
    400) die "Requisicao invalida (400): $HTTP_BODY" ;;
    401) die "Falha na assinatura HMAC (401). Verifique data/hora e secret." ;;
    402) die "Licenca expirada (402)." ;;
    403) die "Acesso bloqueado ou HWID divergente (403): $HTTP_BODY" ;;
    404) die "KEY nao encontrada (404): $LICENSE_KEY" ;;
    409) die "Limite de instalacoes atingido (409)." ;;
    410) die "Licenca revogada (410)." ;;
    429) die "Muitas tentativas (429). Aguarde alguns minutos." ;;
    000) die "Sem resposta da API $API_BASE." ;;
    *)   die "Erro inesperado da API HTTP $HTTP_CODE: $HTTP_BODY" ;;
  esac

  INSTALLATION_ID=$(echo "$HTTP_BODY" | json_get '.installation_id')
  EXPIRES_AT=$(echo "$HTTP_BODY" | json_get '.expires_at')
  [[ -n "$INSTALLATION_ID" ]] || die "Resposta da API sem installation_id. Body: $HTTP_BODY"
  ok "Instalacao: ${INSTALLATION_ID:0:8}... Expira: ${EXPIRES_AT:0:10}"
}

write_license_gate() {
  local target="$1"
  cat > "$target" <<'PHP'
<?php
declare(strict_types=1);

if (PHP_SAPI === 'cli') {
    return;
}

$uri = $_SERVER['REQUEST_URI'] ?? '';
if ($uri === '/healthz' || str_starts_with($uri, '/healthz')) {
    return;
}

function xsp_env_value(string $key, string $default = ''): string {
    $value = getenv($key);
    return ($value === false || $value === '') ? $default : $value;
}

function xsp_fail(string $message): void {
    http_response_code(402);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode([
        'error' => 'license_required',
        'message' => $message,
    ], JSON_UNESCAPED_UNICODE);
    exit;
}

function xsp_hmac_key(string $secret): string {
    if ($secret !== '' && strlen($secret) % 2 === 0 && ctype_xdigit($secret)) {
        $raw = hex2bin($secret);
        if ($raw !== false) {
            return $raw;
        }
    }
    return $secret;
}

function xsp_compute_hwid_fallback(): string {
    $machineId = @trim((string)file_get_contents('/etc/machine-id'));
    $boardUuid = @trim((string)file_get_contents('/sys/class/dmi/id/product_uuid'));
    $diskUuid = @trim((string)shell_exec("blkid -s UUID -o value \$(findmnt -n -o SOURCE /) 2>/dev/null"));
    $mac = '';
    foreach (glob('/sys/class/net/*/address') ?: [] as $file) {
        if (basename(dirname($file)) === 'lo') {
            continue;
        }
        $candidate = trim((string)@file_get_contents($file));
        if ($candidate !== '' && $candidate !== '00:00:00:00:00:00') {
            $mac = $candidate;
            break;
        }
    }
    return hash('sha256', $machineId . "\x1f" . $boardUuid . "\x1f" . $diskUuid . "\x1f" . $mac);
}

function xsp_call_license_api(string $method, string $path, array $payload, string $installId): array {
    $base = rtrim(xsp_env_value('XSP_API_BASE'), '/');
    $secret = xsp_env_value('XSP_PUBLIC_SECRET');
    if ($base === '' || $secret === '') {
        xsp_fail('license api not configured');
    }

    $body = json_encode($payload, JSON_UNESCAPED_UNICODE);
    if ($body === false) {
        xsp_fail('license payload failed');
    }
    $ts = (string)time();
    $nonce = bin2hex(random_bytes(16));
    $signature = hash_hmac('sha256', $method . $path . $body . $ts . $nonce, xsp_hmac_key($secret));

    $ch = curl_init($base . $path);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_POSTFIELDS => $body,
        CURLOPT_HTTPHEADER => [
            'Content-Type: application/json',
            'X-Installation-ID: ' . $installId,
            'X-Timestamp: ' . $ts,
            'X-Nonce: ' . $nonce,
            'X-Signature: ' . $signature,
            'User-Agent: xsp-panel-github/' . xsp_env_value('XSP_VERSION', 'unknown'),
        ],
        CURLOPT_CONNECTTIMEOUT => 5,
        CURLOPT_TIMEOUT => 10,
        CURLOPT_SSL_VERIFYPEER => true,
    ]);

    $response = curl_exec($ch);
    $code = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $error = curl_error($ch);
    curl_close($ch);

    if ($response === false || $code >= 400) {
        xsp_fail('license validation failed: ' . ($error ?: ('http ' . $code)));
    }

    $data = json_decode((string)$response, true);
    if (!is_array($data)) {
        xsp_fail('invalid license response');
    }
    return $data;
}

$stateDir = '/var/lib/xsp';
$cacheFile = $stateDir . '/license-cache.json';
$now = time();

if (is_file($cacheFile)) {
    $cache = json_decode((string)@file_get_contents($cacheFile), true);
    if (is_array($cache) && (int)($cache['valid_until'] ?? 0) > $now) {
        return;
    }
}

$installId = xsp_env_value('XSP_INSTALLATION_ID');
$hwid = xsp_env_value('XSP_HWID');
if ($hwid === '') {
    $hwid = xsp_compute_hwid_fallback();
}
if ($installId === '' || $hwid === '') {
    xsp_fail('panel not activated');
}

$data = xsp_call_license_api('POST', '/v1/heartbeat', [
    'hwid' => $hwid,
    'panel_version' => xsp_env_value('XSP_VERSION', 'unknown'),
], $installId);

@mkdir($stateDir, 0700, true);
@file_put_contents($cacheFile, json_encode([
    'status' => $data['status'] ?? 'ok',
    'expires_at' => $data['expires_at'] ?? null,
    'valid_until' => $now + 300,
], JSON_UNESCAPED_UNICODE), LOCK_EX);
@chmod($cacheFile, 0600);
PHP
}

write_dockerfile() {
  local target="$1"
  cat > "$target" <<'DOCKERFILE'
FROM php:8.2-apache-bookworm

ARG VERSION=10.0.3
ENV XSP_VERSION=${VERSION}

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl unzip \
      libcurl4-openssl-dev libonig-dev libzip-dev libicu-dev \
      libpng-dev libjpeg62-turbo-dev libfreetype6-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install pdo_mysql mysqli opcache curl mbstring zip intl gd \
    && a2enmod rewrite headers \
    && rm -rf /var/lib/apt/lists/*

COPY --chown=www-data:www-data app/ /var/www/html/
COPY xsp-license-gate.php /var/www/html/xsp-license-gate.php
COPY apache.conf /etc/apache2/sites-enabled/000-default.conf
COPY php-xsp.ini /usr/local/etc/php/conf.d/99-xsp.ini

RUN mkdir -p /var/lib/xsp /var/www/html/uploads \
    && chown -R www-data:www-data /var/lib/xsp /var/www/html \
    && find /var/www/html -type d -exec chmod 755 {} \; \
    && find /var/www/html -type f -exec chmod 644 {} \; \
    && chmod -R 775 /var/www/html/uploads

EXPOSE 80
DOCKERFILE
}

write_apache_conf() {
  local target="$1"
  cat > "$target" <<'APACHE'
<VirtualHost *:80>
    DocumentRoot /var/www/html
    DirectoryIndex index.php

    <Directory /var/www/html>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <FilesMatch "(^xsp-license-gate\.php$|\.env$|\.sql$|\.zip$|composer\.(json|lock)$)">
        Require all denied
    </FilesMatch>

    <Location /healthz>
        SetHandler default-handler
        Require all granted
    </Location>

    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"

    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
APACHE
}

write_php_ini() {
  local target="$1"
  cat > "$target" <<'INI'
expose_php=0
upload_max_filesize=256M
post_max_size=256M
memory_limit=512M
max_execution_time=120
date.timezone=America/Sao_Paulo
auto_prepend_file=/var/www/html/xsp-license-gate.php
opcache.enable=1
opcache.validate_timestamps=1
INI
}

download_panel_source() {
  local cache_dir="$INSTALL_PATH/source"
  local zip_file="$cache_dir/panel.zip"
  local extract_dir="$cache_dir/extract"

  step "Baixando painel pelo GitHub Release..."
  rm -rf "$cache_dir"
  mkdir -p "$extract_dir"
  if ! curl_retry --max-time 300 "$PANEL_RELEASE_URL" -o "$zip_file"; then
    warn "Release do painel ainda nao disponivel; usando branch ${PANEL_REF}."
    curl_retry --max-time 300 "$PANEL_SOURCE_URL" -o "$zip_file"
  fi
  unzip -q "$zip_file" -d "$extract_dir"

  PANEL_SRC_DIR=$(find "$extract_dir" -mindepth 1 -maxdepth 3 -type d -name script | head -1 || true)
  [[ -n "$PANEL_SRC_DIR" && -d "$PANEL_SRC_DIR" ]] \
    || die "Repositorio baixado nao contem a pasta script/."
  ok "Codigo do painel baixado."
}

build_panel_image() {
  download_panel_source

  step "Preparando build local do painel..."
  BUILD_DIR="$INSTALL_PATH/build"
  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR/app"

  tar -C "$PANEL_SRC_DIR" \
    --exclude='./*.zip' \
    --exclude='./error_log*' \
    --exclude='./debug_log.txt' \
    -cf - . | tar -C "$BUILD_DIR/app" -xf -

  write_license_gate "$BUILD_DIR/xsp-license-gate.php"
  write_dockerfile "$BUILD_DIR/Dockerfile"
  write_apache_conf "$BUILD_DIR/apache.conf"
  write_php_ini "$BUILD_DIR/php-xsp.ini"

  step "Buildando imagem Docker local ($LOCAL_IMAGE)..."
  run_timeout 45m docker build \
    --build-arg VERSION="$PANEL_VERSION" \
    -t "$LOCAL_IMAGE" \
    "$BUILD_DIR"
  ok "Imagem local pronta: $LOCAL_IMAGE"

  mkdir -p "$INSTALL_PATH/initdb"
  SQL_SRC="$PANEL_SRC_DIR/Banco de dados/sql.sql"
  if [[ -f "$SQL_SRC" ]]; then
    cp "$SQL_SRC" "$INSTALL_PATH/initdb/01-schema.sql"
    ok "SQL inicial copiado."
  else
    warn "SQL inicial nao encontrado; banco sera criado vazio."
  fi
}

write_env_and_compose() {
  mkdir -p "$INSTALL_PATH" "$INSTALL_PATH/initdb" "$INSTALL_PATH/state" "$INSTALL_PATH/uploads"
  chmod 750 "$INSTALL_PATH"

  OLD_DB_PASS=""
  OLD_DB_ROOT=""
  if [[ -f "$INSTALL_PATH/.env" ]]; then
    OLD_DB_PASS=$(grep -E "^DB_PASS=" "$INSTALL_PATH/.env" | cut -d= -f2- || echo "")
    OLD_DB_ROOT=$(grep -E "^DB_ROOT_PASS=" "$INSTALL_PATH/.env" | cut -d= -f2- || echo "")
  fi
  DB_PASS="${OLD_DB_PASS:-$(openssl rand -hex 16)}"
  DB_ROOT_PASS="${OLD_DB_ROOT:-$(openssl rand -hex 16)}"

  step "Escrevendo configuracao..."
  cat > "$INSTALL_PATH/.env" <<ENV
XSP_LICENSE_KEY=${LICENSE_KEY}
XSP_INSTALLATION_ID=${INSTALLATION_ID}
XSP_HWID=${HWID}
XSP_PUBLIC_SECRET=${HMAC_PUBLIC_SECRET}
XSP_API_BASE=${API_BASE}
XSP_VERSION=${PANEL_VERSION}

PANEL_IMAGE=${LOCAL_IMAGE}
PANEL_DOMAIN=${PANEL_DOMAIN}
PANEL_EMAIL=${ADMIN_EMAIL}
PANEL_RELEASE_URL=${PANEL_RELEASE_URL}
PANEL_SOURCE_URL=${PANEL_SOURCE_URL}

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
      XSP_HWID: ${XSP_HWID}
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
      - ./state:/var/lib/xsp
      - ./uploads:/var/www/html/uploads
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "80:80"
    networks:
      - wan
      - db_net

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
      retries: 30
    networks:
      - db_net

volumes:
  dbdata:

networks:
  wan:
    driver: bridge
  db_net:
    driver: bridge
    internal: true
COMPOSE

  cat > "$INSTALL_PATH/uninstall.sh" <<UNINSTALL
#!/usr/bin/env bash
set -euo pipefail
INSTALL_PATH="${INSTALL_PATH}"
[[ \$EUID -eq 0 ]] || { echo "Rode como root" >&2; exit 1; }
echo "Isso remove containers, volumes e arquivos do painel."
read -rp "Digite 'sim' para confirmar: " CONFIRM
[[ "\$CONFIRM" == "sim" ]] || { echo "Cancelado."; exit 0; }
if [[ -f "\$INSTALL_PATH/.env" ]]; then
  set -a; source "\$INSTALL_PATH/.env"; set +a
  TS=\$(date +%s); NONCE=\$(openssl rand -hex 16 2>/dev/null || echo "0")
  BODY="{}"
  SIG=\$({ printf '%s' "POST/v1/deactivate"; printf '%s' "\$BODY"; printf '%s' "\${TS}\${NONCE}"; } \
    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:\${XSP_PUBLIC_SECRET:-}" -hex 2>/dev/null \
    | awk '{print \$NF}' || echo "")
  curl -s --max-time 8 -X POST "\${XSP_API_BASE:-}/v1/deactivate" \
    -H "Content-Type: application/json" \
    -H "X-Installation-ID: \${XSP_INSTALLATION_ID:-}" \
    -H "X-Timestamp: \$TS" -H "X-Nonce: \$NONCE" -H "X-Signature: \$SIG" \
    -d "\$BODY" >/dev/null 2>&1 || true
fi
docker compose -f "\$INSTALL_PATH/docker-compose.yml" down -v 2>/dev/null || true
rm -rf "\$INSTALL_PATH"
echo "Desinstalacao concluida."
UNINSTALL
  chmod 750 "$INSTALL_PATH/uninstall.sh"
  ok "Configuracao gerada."
}

start_stack() {
  step "Verificando portas 80/443..."
  for p in 80; do
    if port_in_use "$p"; then
      if ! docker compose -f "$INSTALL_PATH/docker-compose.yml" ps --services --filter status=running 2>/dev/null | grep -q '^panel$'; then
        die "Porta $p ja esta em uso. Libere antes de continuar."
      fi
    fi
  done
  ok "Porta 80 disponivel para o painel."

  step "Subindo containers..."
  cd "$INSTALL_PATH"
  docker compose up -d --remove-orphans
  ok "Containers iniciados."
}

wait_health() {
  step "Aguardando painel responder (ate 120s)..."
  HEALTHY=0
  for _ in $(seq 1 60); do
    if curl -fsS --max-time 3 -o /dev/null http://127.0.0.1/healthz 2>/dev/null \
    || curl -fsS --max-time 3 -o /dev/null http://127.0.0.1/ 2>/dev/null; then
      HEALTHY=1
      break
    fi
    sleep 2
  done

  if [[ "$HEALTHY" -eq 1 ]]; then
    ok "Painel respondendo."
  else
    warn "Painel ainda nao respondeu. Ultimos logs:"
    docker compose -f "$INSTALL_PATH/docker-compose.yml" logs --tail=40 2>/dev/null || true
  fi
}

do_status() {
  [[ -f "$INSTALL_PATH/.env" ]] || die "Nenhuma instalacao encontrada em $INSTALL_PATH."
  set -a; source "$INSTALL_PATH/.env"; set +a
  echo
  echo "KEY:        ${XSP_LICENSE_KEY:-?}"
  echo "Instalacao: ${XSP_INSTALLATION_ID:-?}"
  echo "Versao:     ${XSP_VERSION:-?}"
  echo "API:        ${XSP_API_BASE:-?}"
  echo
  docker compose -f "$INSTALL_PATH/docker-compose.yml" ps 2>/dev/null || true
}

do_update() {
  [[ -f "$INSTALL_PATH/.env" ]] || die "Nenhuma instalacao encontrada em $INSTALL_PATH. Instale primeiro."
  set -a; source "$INSTALL_PATH/.env"; set +a
  LICENSE_KEY="${XSP_LICENSE_KEY:-}"
  PANEL_DOMAIN="${PANEL_DOMAIN:-}"
  ADMIN_EMAIL="${PANEL_EMAIL:-admin@${PANEL_DOMAIN:-localhost}}"
  HWID="${XSP_HWID:-$(compute_hwid)}"
  INSTALLATION_ID="${XSP_INSTALLATION_ID:-}"
  [[ -n "$LICENSE_KEY" && -n "$INSTALLATION_ID" ]] || die ".env incompleto em $INSTALL_PATH."

  ensure_dependencies
  ensure_docker
  build_panel_image
  docker compose -f "$INSTALL_PATH/docker-compose.yml" up -d --remove-orphans
  wait_health
  ok "Atualizacao concluida."
}

step "Verificando espaco em disco..."
AVAIL_GB=$(df -BG / 2>/dev/null | tail -1 | awk '{gsub(/G/,""); print $4}' || echo "0")
AVAIL_GB="${AVAIL_GB//[^0-9]/}"
AVAIL_GB="${AVAIL_GB:-0}"
[[ "$AVAIL_GB" -ge 5 ]] || die "Espaco insuficiente: ${AVAIL_GB}GB disponivel (minimo 5GB)."
ok "Espaco disponivel: ${AVAIL_GB}GB."

case "$ARG_KEY" in
  --status)
    do_status
    exit 0
    ;;
  --update)
    do_update
    exit 0
    ;;
esac

validate_license_key
detect_domain_email
ensure_dependencies
ensure_docker
activate_license
build_panel_image
write_env_and_compose
start_stack
wait_health

LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "?")
echo
echo "============================================================="
echo "  INSTALACAO CONCLUIDA"
echo "============================================================="
echo "Painel:      http://${PANEL_DOMAIN}/"
echo "Local:       http://${LOCAL_IP}/"
echo "Licenca:     $LICENSE_KEY"
echo "Expira:      ${EXPIRES_AT:0:10}"
echo "Instalacao:  $INSTALLATION_ID"
echo
echo "Comandos:"
echo "  Logs:       docker compose -f $INSTALL_PATH/docker-compose.yml logs -f"
echo "  Status:     curl -sSL ${INSTALL_URL} | sudo bash -s -- --status"
echo "  Atualizar:  curl -sSL ${INSTALL_URL} | sudo bash -s -- --update"
echo "  Remover:    sudo bash $INSTALL_PATH/uninstall.sh"
echo
echo "Log: $LOGFILE"
