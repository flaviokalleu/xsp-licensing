#!/usr/bin/env bash
# Compila a extensão xsp_loader dentro de um container PHP.
# Saída: ./build/xsp_loader.so
set -euo pipefail

PHP_TAG="${PHP_TAG:-8.2-cli-bookworm}"
OUT="$(pwd)/build"
mkdir -p "$OUT"

docker run --rm -v "$(pwd)":/src -w /src "php:${PHP_TAG}" bash -c '
  set -e
  apt-get update -qq
  apt-get install -y -qq libssl-dev pkg-config build-essential >/dev/null
  phpize
  ./configure --enable-xsp_loader
  make -j"$(nproc)"
  cp modules/xsp_loader.so build/
  echo "✓ build/xsp_loader.so"
'
ls -la "$OUT/xsp_loader.so"
