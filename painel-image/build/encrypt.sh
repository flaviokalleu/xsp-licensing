#!/usr/bin/env bash
# Cifra recursivamente todos os .php do diretório SRC com AES-256-GCM.
# Resultado: cada arquivo vira "arquivo.php.enc" em DEST, mesma estrutura.
# Os demais arquivos (img, css, js, sql, etc.) são copiados como estão.
#
# Layout do .enc: [4B "XSP1"] [12B IV] [N B ciphertext] [16B tag]
#
# Uso:
#   MASTER_KEY=<64-hex> ./encrypt.sh <SRC> <DEST>
set -euo pipefail

SRC="${1:?uso: encrypt.sh SRC DEST}"
DEST="${2:?uso: encrypt.sh SRC DEST}"
: "${MASTER_KEY:?defina MASTER_KEY (64 chars hex)}"
if [[ ${#MASTER_KEY} -ne 64 ]]; then
  echo "MASTER_KEY deve ter 64 chars hex (32 bytes)" >&2; exit 1
fi

mkdir -p "$DEST"

echo "→ Cifrando .php em $SRC → $DEST"
count=0
while IFS= read -r -d '' f; do
  rel="${f#$SRC/}"
  out="$DEST/${rel}.enc"
  mkdir -p "$(dirname "$out")"

  iv_hex=$(openssl rand -hex 12)
  iv_bin=$(printf '%s' "$iv_hex" | xxd -r -p)

  # OpenSSL CLI não suporta AES-GCM direto antes da 3.x — usar Python para portabilidade.
  python3 - "$f" "$out" "$MASTER_KEY" "$iv_hex" <<'PYEOF'
import sys, os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

src, dst, key_hex, iv_hex = sys.argv[1:5]
key = bytes.fromhex(key_hex)
iv  = bytes.fromhex(iv_hex)
with open(src, 'rb') as f:
    plain = f.read()
ct = AESGCM(key).encrypt(iv, plain, None)
# ct já contém tag nos últimos 16 bytes.
body, tag = ct[:-16], ct[-16:]
with open(dst, 'wb') as o:
    o.write(b'XSP1')
    o.write(iv)
    o.write(body)
    o.write(tag)
PYEOF
  count=$((count+1))
done < <(find "$SRC" -type f -name '*.php' -print0)

echo "→ Copiando assets não-PHP..."
# Copia tudo que NÃO é .php (img/css/js/sql/json/etc), mantendo árvore.
rsync -a \
  --exclude='*.php' \
  --exclude='*.log' \
  --exclude='error_log*' \
  --exclude='.git/' \
  "$SRC/" "$DEST/"

echo "✓ Cifrados $count arquivos PHP."
