#!/usr/bin/env bash
set -euo pipefail

# Verificações mínimas no boot
if [[ -z "${XSP_LICENSE_KEY:-}" ]]; then
  echo "✗ XSP_LICENSE_KEY ausente. Reinstale via /opt/xsp/installer." >&2
  exit 1
fi
if [[ -z "${XSP_API_BASE:-}" ]]; then
  echo "✗ XSP_API_BASE ausente." >&2
  exit 1
fi
if [[ -z "${XSP_PUBLIC_SECRET:-}" ]]; then
  echo "✗ XSP_PUBLIC_SECRET ausente." >&2
  exit 1
fi

# Healthcheck endpoint estático
mkdir -p /var/www/html
cat > /var/www/html/healthz <<'EOF'
ok
EOF

# Permissões
chown -R www-data:www-data /var/lib/xsp /var/www/html/uploads 2>/dev/null || true

exec "$@"
