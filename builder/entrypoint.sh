#!/usr/bin/env bash
# Entrypoint do container builder.
#
# Comandos:
#   build           — empacota release do painel (default)
#   build-loader    — compila apenas a extensão xsp_loader.so
#   sh              — shell interativo
set -euo pipefail

case "${1:-build}" in
  build)
    : "${PANEL_SRC:?defina PANEL_SRC}"
    : "${VERSION:?defina VERSION}"
    : "${REGISTRY:?defina REGISTRY}"
    : "${API_BASE:?defina API_BASE}"
    : "${INTERNAL_TOKEN:?defina INTERNAL_TOKEN}"

    # Garante xsp_loader compilado
    if [[ ! -f /xsp-loader/build/xsp_loader.so ]]; then
      echo "→ Compilando xsp_loader..."
      cd /xsp-loader
      bash build.sh
    fi

    # Login no registry
    if [[ -n "${REGISTRY_USER:-}" && -n "${REGISTRY_PASS:-}" ]]; then
      echo "$REGISTRY_PASS" | docker login "${REGISTRY%%/*}" -u "$REGISTRY_USER" --password-stdin
    fi

    # Roda o pipeline
    cd /painel-image
    exec bash build/package.sh
    ;;

  build-loader)
    cd /xsp-loader
    exec bash build.sh
    ;;

  sh|bash|shell)
    exec /bin/bash
    ;;

  *)
    exec "$@"
    ;;
esac
