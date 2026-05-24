#!/usr/bin/env bash
###############################################################################
#  Gera todos os segredos do .env de forma idempotente.
#  Roda Go via container — não precisa de Go instalado no host.
###############################################################################
set -euo pipefail

ENV_FILE="${1:-.env}"

die() { echo "✗ $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Dependencia ausente: $1"
}

for cmd in docker python3 openssl grep cut; do
  require_cmd "$cmd"
done

[[ -f "$ENV_FILE" ]] || cp .env.example "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Insere/atualiza uma chave no .env sem duplicar
set_env() {
  local k="$1" v="$2"
  if grep -q "^${k}=" "$ENV_FILE" 2>/dev/null; then
    # Usa python3 para substituir com segurança (sem problema com / ou & no sed)
    python3 -c "
import re, sys
k, v = sys.argv[1], sys.argv[2]
content = open('$ENV_FILE').read()
content = re.sub(r'^' + re.escape(k) + r'=.*', k + '=' + v, content, flags=re.MULTILINE)
open('$ENV_FILE', 'w').write(content)
" "$k" "$v"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
}

# Retorna true se a chave não existir ou estiver vazia
need() {
  local cur
  cur=$(grep "^${1}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
  [[ -z "$cur" ]]
}

rand_hex() {
  local bytes="$1"
  local out
  out="$(openssl rand -hex "$bytes")" || die "Falha ao gerar segredo com openssl"
  [[ -n "$out" ]] || die "openssl retornou segredo vazio"
  printf '%s' "$out"
}

echo "→ Gerando segredos via container Go..."

# Roda o admin-cli num container — output capturado
SECRETS=$(docker run --rm --pull=missing \
  -v "$(pwd)/api-license":/src:ro \
  -w /src \
  golang:1.22-alpine sh -c '
    apk add --no-cache git >/dev/null 2>&1
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

# ── Segredos simples: DB, registry ───────────────────────────────────────────
for k in DB_PASS REG_PASS; do
  if need "$k"; then
    set_env "$k" "$(rand_hex 16)"
    echo "  + $k"
  fi
done

# ── Senha do admin dashboard (plaintext no .env) ──────────────────────────────
# Usa ADMIN_DASH_PASS em plaintext — o PHP admin verifica via hash_equals ou bcrypt
if need ADMIN_DASH_PASS; then
  ADMIN_DASH_PASS_VAL=$(rand_hex 12)
  set_env ADMIN_DASH_PASS "$ADMIN_DASH_PASS_VAL"
  set_env ADMIN_DASH_USER "admin"
  echo "  + ADMIN_DASH_PASS"
  echo "  + ADMIN_DASH_USER"
  echo
  echo "  ▶ USUÁRIO DO PAINEL ADMIN: admin"
  echo "  ▶ SENHA DO PAINEL ADMIN:   $ADMIN_DASH_PASS_VAL"
  echo "    (anote agora — não será mostrada de novo)"
  echo
fi

# ── Chaves Ed25519 (necessário para assinar license tokens) ──────────────────
if need ED25519_PRIVATE_KEY_B64; then
  echo "  Gerando chaves Ed25519..."
  ED25519_KEYS=$(python3 - <<'PYEOF'
import subprocess, base64, sys

r = subprocess.run(
    ['openssl', 'genpkey', '-algorithm', 'ed25519', '-outform', 'DER'],
    capture_output=True)
if r.returncode != 0:
    sys.exit("openssl genpkey failed: " + r.stderr.decode())
priv_der = r.stdout            # 48-byte PKCS8

r2 = subprocess.run(
    ['openssl', 'pkey', '-inform', 'DER', '-pubout', '-outform', 'DER'],
    input=priv_der, capture_output=True)
if r2.returncode != 0:
    sys.exit("openssl pkey failed: " + r2.stderr.decode())
pub_der = r2.stdout            # 44-byte SubjectPublicKeyInfo

seed   = priv_der[16:48]       # 32-byte seed
pub    = pub_der[12:44]        # 32-byte raw public key
go_priv = seed + pub           # 64-byte Go ed25519.PrivateKey

print(base64.b64encode(go_priv).decode())
print(base64.b64encode(pub).decode())
PYEOF
)
  ED25519_PRIV=$(echo "$ED25519_KEYS" | sed -n '1p')
  ED25519_PUB=$(echo "$ED25519_KEYS"  | sed -n '2p')
  [[ -n "$ED25519_PRIV" && -n "$ED25519_PUB" ]] \
    || { echo "✗ Falha ao gerar chaves Ed25519" >&2; exit 1; }
  set_env ED25519_PRIVATE_KEY_B64 "$ED25519_PRIV"
  set_env ED25519_PUBLIC_KEY_B64  "$ED25519_PUB"
  echo "  + ED25519_PRIVATE_KEY_B64"
  echo "  + ED25519_PUBLIC_KEY_B64"
fi

# ── htpasswd do registry ─────────────────────────────────────────────────────
if [[ ! -f api-license/auth/htpasswd ]]; then
  mkdir -p api-license/auth
  REG_USER=$(grep "^REG_USER=" "$ENV_FILE" | cut -d= -f2- || true)
  REG_PASS=$(grep "^REG_PASS=" "$ENV_FILE" | cut -d= -f2- || true)
  [[ -n "$REG_USER" && -n "$REG_PASS" ]] \
    || die "REG_USER ou REG_PASS nao encontrado no .env"
  docker run --rm httpd:2-alpine htpasswd -Bbn "$REG_USER" "$REG_PASS" \
    > api-license/auth/htpasswd
  chmod 640 api-license/auth/htpasswd
  echo "  + api-license/auth/htpasswd (registry)"
fi

for k in DB_PASS REG_PASS ADMIN_DASH_PASS HMAC_PUBLIC_SECRET JWT_SECRET ADMIN_TOKEN RELEASE_MASTER_KEY ED25519_PRIVATE_KEY_B64 ED25519_PUBLIC_KEY_B64; do
  v=$(grep "^${k}=" "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
  [[ -n "$v" ]] || die "Segredo obrigatorio ficou vazio: $k"
done

echo
echo "✓ Segredos prontos em $ENV_FILE"
