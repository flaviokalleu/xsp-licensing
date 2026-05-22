#!/usr/bin/env bash
# Bootstrap do instalador XSP
# Uso: curl -sSL https://seudominio.com/install.sh | sudo bash
set -euo pipefail

API="${XSP_API:-https://license.seudominio.com}"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "Arquitetura não suportada: $ARCH"; exit 1 ;;
esac

if [[ $EUID -ne 0 ]]; then
  echo "Este script deve ser executado como root."
  echo "Uso: curl -sSL ... | sudo bash"
  exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "→ Baixando instalador (linux-$ARCH)..."
curl -fsSL "$API/dl/installer/linux-$ARCH"     -o "$TMPDIR/installer"
curl -fsSL "$API/dl/installer/linux-$ARCH.sig" -o "$TMPDIR/installer.sig"
curl -fsSL "$API/dl/installer/pub.pem"          -o "$TMPDIR/pub.pem"

if ! command -v openssl >/dev/null 2>&1; then
  apt-get update -y && apt-get install -y openssl
fi

echo "→ Verificando assinatura Ed25519..."
if ! openssl pkeyutl -verify -pubin -inkey "$TMPDIR/pub.pem" \
        -rawin -in "$TMPDIR/installer" \
        -sigfile "$TMPDIR/installer.sig" >/dev/null 2>&1; then
  echo "✗ ASSINATURA INVÁLIDA — abortando." >&2
  exit 1
fi
echo "✓ Assinatura OK"

chmod +x "$TMPDIR/installer"
exec "$TMPDIR/installer" "$@"
