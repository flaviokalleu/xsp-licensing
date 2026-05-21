# DEPLOY — XSP Licensing

Guia passo-a-passo para subir a infra do zero numa VPS Ubuntu 22.04+.

## Pré-requisitos

- VPS Ubuntu 22.04 (mínimo 2 vCPU, 4 GB RAM, 40 GB SSD).
- Domínio próprio (ex: `license.seudominio.com`).
- DNS apontando para o IP da VPS.
- Acesso root via SSH.

---

## 1. Preparar a VPS

```bash
# Como root na VPS
apt-get update -y && apt-get upgrade -y
apt-get install -y curl gnupg ca-certificates ufw fail2ban git make

# Firewall
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw enable

# Docker
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
```

## 2. TLS com Caddy (proxy reverso)

```bash
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update && apt-get install -y caddy
```

Edite `/etc/caddy/Caddyfile`:

```caddy
license.seudominio.com {
    reverse_proxy 127.0.0.1:8443
}

registry.seudominio.com {
    reverse_proxy 127.0.0.1:5000
}

admin.seudominio.com {
    reverse_proxy 127.0.0.1:8081
}

seudominio.com {
    root * /var/www/dl
    file_server
    # install.sh fica em /var/www/dl/install.sh
    # binários em /var/www/dl/dl/installer/
}
```

Recarregue: `systemctl reload caddy`.

## 3. Subir a api-license

```bash
git clone <SEU_REPO_PRIVADO> /opt/xsp
cd /opt/xsp/licensing/api-license

# Gere os segredos
docker run --rm -v $PWD:/src -w /src golang:1.22 \
  sh -c 'go mod tidy && go run ./cmd/admin-cli gen-secrets' > /tmp/secrets

# Cole em .env
cp .env.example .env
cat /tmp/secrets >> .env
rm /tmp/secrets
vim .env  # edite DATABASE_URL, REDIS_URL etc. (defaults do compose já funcionam)

# Crie htpasswd para o registry
mkdir -p auth
docker run --rm --entrypoint htpasswd httpd:2 -Bbn license SENHA_FORTE > auth/htpasswd

# Sobe
docker compose up -d --build
docker compose logs -f api
```

Verifique: `curl https://license.seudominio.com/healthz` → `ok`.

## 4. Compilar a extensão xsp_loader

```bash
cd /opt/xsp/licensing/xsp-loader
bash build.sh   # produz build/xsp_loader.so
```

## 5. Publicar o painel como imagem Docker

```bash
cd /opt/xsp/licensing/painel-image

export PANEL_SRC=/opt/xsp/script         # ajuste se necessário
export VERSION=10.0.3
export REGISTRY=registry.seudominio.com/xsp/panel
export API_BASE=https://license.seudominio.com
export INTERNAL_TOKEN=$(grep ^ADMIN_TOKEN /opt/xsp/licensing/api-license/.env | cut -d= -f2)

# Login no registry privado
echo SENHA_FORTE | docker login registry.seudominio.com -u license --password-stdin

bash build/package.sh
```

## 6. Compilar o installer-go

```bash
cd /opt/xsp/licensing/installer-go

# Gere uma keypair Ed25519 PARA ASSINAR os binários (chave separada da API)
openssl genpkey -algorithm ed25519 -out /opt/xsp/keys/release-priv.pem
chmod 400 /opt/xsp/keys/release-priv.pem

export XSP_API_BASE=https://license.seudominio.com
export XSP_HMAC_SECRET=$(grep ^HMAC_PUBLIC_SECRET ../api-license/.env | cut -d= -f2)
export XSP_REGISTRY_URL=registry.seudominio.com
export XSP_PUBKEY_B64=$(grep ^ED25519_PUBLIC_KEY_B64 ../api-license/.env | cut -d= -f2)
export XSP_SIGN_KEY=/opt/xsp/keys/release-priv.pem

# garble opcional
go install mvdan.cc/garble@latest

make build
# Resultado em dist/

# Publica em /var/www/dl/
mkdir -p /var/www/dl/dl/installer
cp dist/installer-linux-amd64{,.sig,.sha256} /var/www/dl/dl/installer/
cp dist/installer-linux-arm64{,.sig,.sha256} /var/www/dl/dl/installer/
cp dist/pub.pem                              /var/www/dl/dl/installer/
cp scripts/install.sh                        /var/www/dl/install.sh
```

## 7. Subir o admin-dashboard

```bash
cd /opt/xsp/licensing/admin-dashboard
export ADMIN_API_TOKEN=$(grep ^ADMIN_TOKEN ../api-license/.env | cut -d= -f2)
export ADMIN_DASH_USER=admin
export ADMIN_DASH_PASS='SUA_SENHA_FORTE'
docker compose up -d --build
```

Acesse `https://admin.seudominio.com`.

## 8. Smoke test

```bash
# Crie uma KEY pelo admin (botão "Gerar KEY") OU via curl:
curl -X POST https://license.seudominio.com/admin/keys \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"email":"teste@me.com","plan_code":"pro","period_days":7}'

# Copie a KEY retornada e teste em outra VPS:
curl -sSL https://seudominio.com/install.sh | sudo bash
# Cole a KEY, domínio e email quando perguntado.
```

## 9. Backups

```bash
# Postgres
docker exec api-license-db-1 pg_dump -U xsp xsp_license | gzip > backup-$(date +%F).sql.gz

# Registry (volumes)
docker run --rm -v api-license_regdata:/data -v $PWD:/bkp alpine \
  tar czf /bkp/registry-$(date +%F).tar.gz -C /data .
```

Coloque no cron diário e copie para S3/B2.
