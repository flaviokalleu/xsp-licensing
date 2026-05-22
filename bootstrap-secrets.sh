#!/usr/bin/env bash
###############################################################################
#  Gera todos os segredos do .env de forma idempotente.
#  Roda Go via container — não precisa de Go instalado no host.
###############################################################################
set -euo pipefail

ENV_FILE="${1:-.env}"

[[ -f "$ENV_FILE" ]] || cp .env.example "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Função para inserir/atualizar uma chave no .env sem duplicar
set_env() {
  local k="$1" v="$2"
  if grep -q "^${k}=" "$ENV_FILE"; then
    sed -i.bak "s|^${k}=.*|${k}=${v}|" "$ENV_FILE" && rm -f "${ENV_FILE}.bak"
  else
    echo "${k}=${v}" >> "$ENV_FILE"
  fi
}

# Só gera se ainda não existir (idempotente)
need() {
  local k="$1"
  local cur=$(grep "^${k}=" "$ENV_FILE" | cut -d= -f2-)
  [[ -z "$cur" ]]
}

echo "→ Gerando segredos via container Go..."

# Roda o admin-cli num container — output capturado
SECRETS=$(docker run --rm --pull=missing \
  -v "$(pwd)/api-license":/src:ro \
  -w /src \
  golang:1.22-alpine sh -c '
    apk add --no-cache git >/dev/null
    go mod tidy >/dev/null 2>&1
    go run ./cmd/admin-cli gen-secrets
' 2>/dev/null | grep -E '^[A-Z_]+=')

[[ -n "$SECRETS" ]] || { echo "✗ Falha ao gerar segredos via Go" >&2; exit 1; }

# Aplica cada par K=V só se ainda não estiver setado
while IFS='=' read -r key val; do
  if need "$key"; then
    set_env "$key" "$val"
    echo "  + $key"
  else
    echo "  · $key (já existia)"
  fi
done <<< "$SECRETS"

# DB_PASS, REG_PASS, ADM_PASS — segredos simples
for k in DB_PASS REG_PASS; do
  if need "$k"; then
    set_env "$k" "$(openssl rand -hex 16)"
    echo "  + $k"
  fi
done

if need ADM_PASS; then
  PASS=$(openssl rand -hex 12)
  # Salva o hash bcrypt no .env, mostra a senha em claro só agora
  set_env ADM_PASS "$(openssl passwd -6 "$PASS")"
  echo "  + ADM_PASS (bcrypt salvo)"
  echo
  echo "  ▶ SENHA DO ADMIN-DASHBOARD: $PASS"
  echo "    (anote agora — não será mostrada de novo)"
fi

# Garante htpasswd do registry (lazy gen)
if [[ ! -f api-license/auth/htpasswd ]]; then
  mkdir -p api-license/auth
  REG_USER=$(grep ^REG_USER "$ENV_FILE" | cut -d= -f2)
  REG_PASS=$(grep ^REG_PASS "$ENV_FILE" | cut -d= -f2)
  docker run --rm httpd:2-alpine htpasswd -Bbn "$REG_USER" "$REG_PASS" \
    > api-license/auth/htpasswd
  chmod 640 api-license/auth/htpasswd
  echo "  + api-license/auth/htpasswd (registry)"
fi

echo "✓ Segredos prontos em $ENV_FILE"
