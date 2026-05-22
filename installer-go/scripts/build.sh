#!/usr/bin/env bash
# Build do installer-go com ofuscação (garble) e assinatura Ed25519.
# Variáveis necessárias (export antes ou em .env.build):
#   XSP_API_BASE      ex: https://license.seudominio.com
#   XSP_HMAC_SECRET   hex 64 chars
#   XSP_REGISTRY_URL  ex: registry.seudominio.com
#   XSP_PUBKEY_B64    chave pública Ed25519 base64
#   XSP_SIGN_KEY      caminho para chave privada PEM Ed25519 (usada p/ assinar o binário)
set -euo pipefail

VERSION="${VERSION:-10.0.3}"
OUT="${OUT:-dist}"
mkdir -p "$OUT"

: "${XSP_API_BASE:?defina XSP_API_BASE}"
: "${XSP_HMAC_SECRET:?defina XSP_HMAC_SECRET}"
: "${XSP_REGISTRY_URL:?defina XSP_REGISTRY_URL}"
: "${XSP_PUBKEY_B64:?defina XSP_PUBKEY_B64}"
: "${XSP_SIGN_KEY:?defina XSP_SIGN_KEY (caminho .pem)}"

PKG="github.com/xsp/installer/internal/config"
LDFLAGS=(
  "-s" "-w"
  "-X" "${PKG}.Version=${VERSION}"
  "-X" "${PKG}.APIBaseURL=${XSP_API_BASE}"
  "-X" "${PKG}.HMACPublicSecret=${XSP_HMAC_SECRET}"
  "-X" "${PKG}.RegistryURL=${XSP_REGISTRY_URL}"
  "-X" "${PKG}.Ed25519PublicKeyB64=${XSP_PUBKEY_B64}"
)

# Garble opcional — se ausente, usa go build normal
BUILDER=(go build)
if command -v garble >/dev/null 2>&1; then
  BUILDER=(garble -literals -tiny build)
  echo "→ Build com garble (obfuscado)"
else
  echo "⚠ garble não encontrado — build sem ofuscação. Instale com: go install mvdan.cc/garble@latest"
fi

for arch in amd64 arm64; do
  echo "→ Compilando linux-$arch..."
  CGO_ENABLED=0 GOOS=linux GOARCH=$arch \
    "${BUILDER[@]}" -trimpath -ldflags="${LDFLAGS[*]}" \
    -o "$OUT/installer-linux-$arch" ./cmd/installer

  # UPX opcional
  if command -v upx >/dev/null 2>&1; then
    upx --lzma --best "$OUT/installer-linux-$arch" >/dev/null 2>&1 || true
  fi

  # Checksum + assinatura Ed25519
  sha256sum "$OUT/installer-linux-$arch" | awk '{print $1}' > "$OUT/installer-linux-$arch.sha256"
  openssl pkeyutl -sign -inkey "$XSP_SIGN_KEY" -rawin \
    -in "$OUT/installer-linux-$arch" \
    -out "$OUT/installer-linux-$arch.sig"
done

# Exporta chave pública para o servidor de downloads
openssl pkey -in "$XSP_SIGN_KEY" -pubout -out "$OUT/pub.pem"

echo "✓ Pronto. Artefatos em: $OUT/"
ls -la "$OUT"
