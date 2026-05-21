# api-license

API central de licenciamento (Go + Fiber + Postgres + Redis).

## Setup local

```bash
cd licensing/api-license
go mod tidy                # baixa as dependências (resolve os diagnósticos do editor)
make secrets               # gera os segredos para o .env (após build)
cp .env.example .env       # cole os secrets gerados
# edite DATABASE_URL/REDIS_URL conforme sua infra
docker compose up -d       # sobe Postgres + Redis + Registry + a API
```

## Endpoints

### Públicos (HMAC obrigatório)

- `POST /v1/activate` — ativa licença e registra HWID
- `POST /v1/heartbeat` — renova token e devolve master_key cifrada
- `POST /v1/deactivate` — libera instalação
- `POST /v1/fraud/report` — painel reporta evento suspeito

### Admin (Bearer ADMIN_TOKEN)

- `POST /admin/keys` — cria nova KEY (body: email, plan_code, period_days?)
- `GET  /admin/keys?limit=50&offset=0` — lista
- `PATCH /admin/keys/:id` — body: `{status,expires_at,extend_days,reason}`
- `POST /admin/blacklist` — body: `{kind:hwid|ip|cidr|key,value,reason}`
- `POST /admin/releases` — body: `{version,master_key,manifest}` (usado pelo pipeline de build)

## Assinatura HMAC dos requests públicos

Headers obrigatórios:
- `X-Timestamp`: unix ts (segundos)
- `X-Nonce`: hex aleatório de 8+ bytes
- `X-Signature`: hex(HMAC-SHA256(HMAC_PUBLIC_SECRET, METHOD + PATH + BODY + TS + NONCE))

Janela de tolerância de relógio: 60s. Nonce reusado em 5 min é rejeitado.

## Criando a primeira licença

```bash
curl -X POST http://localhost:8443/admin/keys \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"email":"cliente@exemplo.com","plan_code":"pro","period_days":30}'
```

## Observação sobre diagnósticos

Se você abrir os `.go` antes de rodar `go mod tidy`, o editor reclama de imports
(`fiber`, `pgx`, `uuid`, etc.). Isso é esperado — `go mod tidy` baixa tudo.
