# admin-dashboard

Painel administrativo em PHP puro (um único `index.php`) para gerenciar
licenças via `api-license`.

Funcionalidades:
- Login básico (basic auth com usuário/senha em env)
- Criar nova KEY (escolhe plano, dias, email do cliente)
- Listar licenças com status, expiração, plano
- Revogar licença
- Estender +30 dias
- Adicionar entrada na blacklist (HWID/IP/CIDR/KEY/Email)

## Setup

```bash
export ADMIN_API_TOKEN=<igual ao do .env da api-license>
export ADMIN_DASH_USER=admin
export ADMIN_DASH_PASS=$(openssl passwd -2 'sua_senha_forte')  # ou texto puro

docker compose up -d
```

Acesse: http://servidor:8081  → login com `ADMIN_DASH_USER`/`ADMIN_DASH_PASS`.

## Em produção

Coloque atrás de um proxy HTTPS (Caddy/Nginx) e restrinja por IP — esse
painel tem o ADMIN_TOKEN da API, é o alvo mais valioso da infra.
