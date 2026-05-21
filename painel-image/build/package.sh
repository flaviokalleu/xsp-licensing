#!/usr/bin/env bash
# Pipeline completo: obfusca + cifra + monta imagem Docker do painel.
#
# Variáveis necessárias:
#   PANEL_SRC          ex: ../../script  (diretório do PHP do painel)
#   VERSION            ex: 10.0.3
#   REGISTRY           ex: registry.seudominio.com/xsp/panel
#   API_BASE           ex: https://license.seudominio.com
#   INTERNAL_TOKEN     token interno para POST /admin/releases (= ADMIN_TOKEN)
#   ED25519_PUB_B64    chave pública da API (mesma do .env)
#
# Saída:
#   - imagem Docker buildada e pushed para REGISTRY:VERSION
#   - MASTER_KEY hex registrada na api-license via POST /admin/releases
set -euo pipefail

: "${PANEL_SRC:?defina PANEL_SRC}"
: "${VERSION:?defina VERSION}"
: "${REGISTRY:?defina REGISTRY}"
: "${API_BASE:?defina API_BASE}"
: "${INTERNAL_TOKEN:?defina INTERNAL_TOKEN}"

WORK=$(mktemp -d -p /tmp xsp-build.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
echo "→ Work dir: $WORK"

# 1) Adapta o painel (substitui credenciais por env vars + saneia)
echo "→ Adaptando painel (credenciais → env vars)..."
python3 "$(dirname "$0")/adapt-panel.py" "$PANEL_SRC" "$WORK/raw" \
  || { echo "✗ adapt-panel falhou. Instale python3: apt install -y python3"; exit 1; }

# 2) Ofuscação (best-effort — se falhar, segue sem)
echo "→ Ofuscando..."
if bash "$(dirname "$0")/obfuscate.sh" "$WORK/raw" "$WORK/obf" 2>/dev/null; then
  STAGE="$WORK/obf"
else
  echo "⚠ obfuscate.sh indisponível — usando fonte adaptada (sem ofuscação)."
  STAGE="$WORK/raw"
fi

# 3) Gera MASTER_KEY (32 bytes / 64 hex)
MASTER_KEY=$(openssl rand -hex 32)
echo "→ MASTER_KEY gerada (não é mostrada por segurança)."

# 4) Cifra
export MASTER_KEY
bash "$(dirname "$0")/encrypt.sh" "$STAGE" "$WORK/enc"

# 4.1) Gera manifest de integridade (.manifest com SHA256 + HMAC de todos .enc)
echo "→ Gerando manifest de integridade..."
MANIFEST_FILE="$WORK/enc/.manifest"
{
  echo "# XSP file integrity manifest — gerado em $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  find "$WORK/enc" -name '*.php.enc' -type f | sort | while read -r f; do
    rel="${f#$WORK/enc/}"
    sha=$(sha256sum "$f" | awk '{print $1}')
    echo "$sha  $rel"
  done
} > "$MANIFEST_FILE.raw"
# HMAC do manifest usando MASTER_KEY (evita que atacante regenere o manifest)
MANIFEST_HMAC=$(openssl dgst -sha256 -mac HMAC -macopt "key:$MASTER_KEY" \
  -hex "$MANIFEST_FILE.raw" | awk '{print $NF}')
cat "$MANIFEST_FILE.raw" > "$MANIFEST_FILE"
echo "# hmac-sha256: $MANIFEST_HMAC" >> "$MANIFEST_FILE"
rm -f "$MANIFEST_FILE.raw"
echo "✓ Manifest com $(grep -c '\.php\.enc' "$MANIFEST_FILE" || true) arquivos."

# 5) Adiciona stubs em claro (bootstrap.php e healthcheck)
cp "$(dirname "$0")/../php-stub/bootstrap.php"     "$WORK/enc/bootstrap.php"
cp "$(dirname "$0")/../php-stub/license_check.php" "$WORK/enc/license_check.php"
cp "$(dirname "$0")/../php-stub/index_router.php"  "$WORK/enc/index_router.php"

# 5.1) Copia o SQL inicial (se existir) para a imagem
SQL_SRC=""
for cand in "$PANEL_SRC/Banco de dados/sql.sql" \
            "$PANEL_SRC/banco_de_dados/sql.sql" \
            "$PANEL_SRC/database/init.sql"; do
  [[ -f "$cand" ]] && SQL_SRC="$cand" && break
done
if [[ -n "$SQL_SRC" ]]; then
  mkdir -p "$WORK/enc/docker-entrypoint-initdb.d"
  cp "$SQL_SRC" "$WORK/enc/docker-entrypoint-initdb.d/01-schema.sql"
  echo "✓ SQL inicial: $SQL_SRC"
else
  echo "⚠ Nenhum sql.sql encontrado — banco vai subir vazio."
fi

# 6) Copia extensão xsp_loader pré-compilada
if [[ -f "../xsp-loader/build/xsp_loader.so" ]]; then
  mkdir -p "$WORK/enc/xsp-ext"
  cp "../xsp-loader/build/xsp_loader.so" "$WORK/enc/xsp-ext/"
else
  echo "✗ xsp_loader.so não encontrado. Rode antes: cd ../xsp-loader && ./build.sh" >&2
  exit 1
fi

# 7) Copia Dockerfile e configs
cp -r "$(dirname "$0")/../docker/." "$WORK/enc/"

# 8) Build & push da imagem
echo "→ Buildando imagem $REGISTRY:$VERSION..."
docker buildx build \
  --build-arg VERSION="$VERSION" \
  -t "$REGISTRY:$VERSION" \
  -t "$REGISTRY:latest" \
  --push \
  "$WORK/enc"

# 9) Captura SHA256 da imagem (digest no registry)
DIGEST=$(docker buildx imagetools inspect "$REGISTRY:$VERSION" 2>/dev/null \
         | awk '/Digest:/{print $2; exit}')

# 10) Monta manifest e registra na API
MANIFEST=$(cat <<JSON
{
  "version": "$VERSION",
  "images": [
    {"ref": "$REGISTRY:$VERSION", "sha256": "$DIGEST"}
  ]
}
JSON
)

echo "→ Registrando release na api-license..."
curl -fsSL -X POST "$API_BASE/admin/releases" \
  -H "Authorization: Bearer $INTERNAL_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"version\":\"$VERSION\",\"master_key\":\"$MASTER_KEY\",\"manifest\":$MANIFEST}" \
  >/dev/null

echo "✓ Release $VERSION publicada."
echo "  Imagem: $REGISTRY:$VERSION  ($DIGEST)"
