#!/usr/bin/env bash
# Ofusca o código PHP com yakpro-po (https://github.com/pk-fr/yakpro-po) ANTES de cifrar.
# Camada extra: mesmo que alguém decifre, o código fica difícil de ler.
#
# Uso: ./obfuscate.sh <SRC> <DEST>
set -euo pipefail

SRC="${1:?uso: obfuscate.sh SRC DEST}"
DEST="${2:?uso: obfuscate.sh SRC DEST}"

# Usa container com yakpro-po pronto.
docker run --rm \
  -v "$SRC:/in:ro" \
  -v "$DEST:/out" \
  ghcr.io/yakpro/yakpro-po:latest \
  --src=/in --dst=/out \
  --t_loop_stmt_obfuscation_statement=true \
  --t_if_stmt_obfuscation_statement=true \
  --t_string_obfuscation=true \
  --t_constant_string_obfuscation=true \
  --silent

echo "✓ Obfuscado em $DEST"
