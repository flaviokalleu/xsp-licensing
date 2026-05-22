# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Sobre este diretório

`licensing/` é o **sistema de licenciamento anti-pirataria** para o painel
em `../script/`. Veja `../CLAUDE.md` para o contexto do repo inteiro;
este arquivo cobre as decisões internas de `licensing/`.

## Modelo de proteção em uma frase

Os `.php` do painel viajam **cifrados em disco (AES-256-GCM)** dentro de
container Docker. A chave para decifrar **não fica na imagem** — é entregue
pela API central a cada boot, **cifrada com o HWID da máquina do cliente**.
Sem licença ativa, sem chave. Sem chave, sem decifrar. Sem decifrar, painel
não roda.

## Decisões de design (por quê do jeito que está)

1. **Sem ionCube/SourceGuardian** — encoder grátis. Usamos AES-256-GCM nos
   `.php` + extensão C `xsp_loader` (não PHP) para descriptografar. Defesa
   está em camadas; ver `docs/SECURITY.md`.

2. **Master key vem da API a cada boot**, cifrada com derivação SHA-256 do
   HWID + nonce. Nunca toca o disco do cliente em claro.

3. **Stack cliente roda em Docker** — instalador (bash standalone) automatiza
   tudo. Cliente só vê `.php.enc` ilegíveis no host.

4. **Bancos separados por papel:**
   - **Postgres** na API central — licenças, instalações, fraude, releases
   - **MariaDB** no container do cliente — dados do painel IPTV (clientes, planos)

5. **Heartbeat 5 min**, cache offline máx 24h. Após 24h sem contato → painel
   bloqueia. Janela de tolerância: 60s de clock skew, nonces no Redis 5 min.

6. **Cripto:**
   - Ed25519 para license tokens (pub key embedded no painel via env)
   - HMAC-SHA256 para assinatura de requests entre instalador/painel e API
   - AES-256-GCM para cifragem PHP e selamento da master key
   - Argon2id para hash de KEY no Postgres

## Componentes e seus papéis

```
licensing/
├── docker-compose.yml      Stack completo (8 services)
├── Caddyfile               TLS automático + 5 vhosts
├── Makefile                make up/down/release/logs
├── bootstrap-secrets.sh    Gera segredos via container Go (idempotente)
├── install-server.sh       Setup 1-comando da VPS central
├── install-painel.sh       Setup 1-comando da VPS do cliente
│
├── api-license/            API central em Go (Fiber + pgx + go-redis)
│   ├── cmd/server/         main.go
│   ├── cmd/admin-cli/      Geração de segredos
│   └── internal/
│       ├── handler/        public.go, admin.go, mp_webhook.go, portal.go
│       ├── service/        Activate, Heartbeat
│       ├── repo/           Postgres queries
│       ├── crypto/         GenerateLicenseKey, Ed25519, HMAC, SealMasterKey
│       └── middleware/     HMACVerify, RateLimitByIP, AdminAuth
│
├── xsp-loader/             Extensão PHP em C
│   ├── xsp_loader.c        Stream wrapper xsp://, xsp_unlock(), anti-ptrace
│   └── build.sh            Compila .so via container php:8.2-cli
│
├── painel-image/           Pipeline que vira script/ em imagem Docker
│   ├── build/adapt-panel.py    Saneia credenciais → getenv()
│   ├── build/encrypt.sh        AES-256-GCM por arquivo .php → .php.enc
│   ├── build/obfuscate.sh      yakpro-po (opcional)
│   ├── build/package.sh        Orquestra: adapt → encrypt → docker build → push
│   ├── docker/Dockerfile       Imagem final: php:8.2-apache + xsp_loader
│   ├── docker/apache.conf      auto_prepend_file + include_path xsp://
│   └── php-stub/               PHPs em claro (3 arquivos: bootstrap, license_check, index_router)
│
├── admin-dashboard/        Painel admin (PHP single-file) — CRUD de KEYs
├── customer-portal/        Self-service do cliente (PHP single-file)
├── landing/                Página /install.sh com domínio auto-detect (HTML+PHP)
├── builder/                Imagem Docker para `make release`
├── installer-go/           ALTERNATIVA em Go ao install-painel.sh (não é o caminho padrão)
└── docs/                   DEPLOY.md, OPERATIONS.md, SECURITY.md
```

## Fluxo end-to-end

```
1. Você → make release
   ↓ (container builder)
   adapt-panel.py(script/) → obfuscate.sh → encrypt.sh → docker build
   ↓ docker push registry.SEUDOMINIO.com
   ↓ POST /admin/releases (registra master_key)

2. Cliente → curl https://SEUDOMINIO/install.sh | sudo bash -s -- XSP-KEY
   ↓ (bash em ~200 linhas)
   compute_hwid → POST /v1/activate → recebe installation_id + master_key_sealed
   ↓
   docker login + pull imagem + cria /opt/xsp/{.env, compose.yml}
   ↓
   docker compose up -d → MariaDB importa SQL inicial → painel sobe

3. Cada request HTTP no painel
   ↓ Apache auto_prepend_file = bootstrap.php (claro)
   ↓ bootstrap → license_check.php (claro)
   ↓ cache local válido? → xsp_unlock(cache.master_key)
   ↓ se não: POST /v1/heartbeat → unseal master_key (HWID-derivado) → xsp_unlock
   ↓
   require 'xsp:///var/www/html/dashboard.php' → wrapper xsp_loader decifra in-memory → executa
```

## Quando trabalhar aqui

Decisão por tipo de pedido:

- **Lógica de licença / planos / fraude** → `api-license/internal/service/` ou `repo/`
- **Webhook de pagamento (Stripe/MP)** → `api-license/internal/handler/mp_webhook.go`
- **Endpoint público novo** → `api-license/internal/handler/public.go` ou `portal.go`
- **Endpoint admin novo** → `api-license/internal/handler/admin.go`
- **Comportamento do instalador cliente** → `install-painel.sh` (bash) ou `installer-go/`
- **Validação no painel rodando** → `painel-image/php-stub/license_check.php`
- **Cifragem / decifragem** → `xsp-loader/xsp_loader.c` ou `painel-image/build/encrypt.sh`
- **Adaptação automática do painel PHP** → `painel-image/build/adapt-panel.py`
- **Página de instalação pública** → `landing/`
- **UI admin** → `admin-dashboard/index.php` (single-file, dark theme)
- **UI cliente** → `customer-portal/index.php` (mesmo estilo)

## Pegadinhas conhecidas

- **`include_path` no Apache é crítico.** Já configurado em `apache.conf` como
  `.:xsp:///var/www/html:/var/www/html`. Sem isso, `require 'menu.php'`
  dentro de um arquivo cifrado não acha o `.enc` correspondente.

- **`disable_functions` no `php.ini-overrides` bloqueia `exec/system/eval`.**
  Se o painel cifrado precisar dessas funções, remover do disable. Mas
  isso reduz a barreira anti-pirataria.

- **`adapt-panel.py` opera in-place no DEST** — não no source. Se rodar
  duas vezes no mesmo DEST, ele apaga e recria. Idempotente do ponto de
  vista do source.

- **MP webhook usa HMAC próprio**, não o nosso (`HMAC_PUBLIC_SECRET`). Eles
  têm formato `ts=...,v1=...` e assinam `id:<id>;request-id:<rid>;ts:<ts>;`.

- **`installer-go/` existe mas não é o padrão.** O bash `install-painel.sh`
  é o caminho oficial. O Go existe como alternativa para clientes
  enterprise que querem binário assinado Ed25519.

- **Versões Go diferentes geram `// indirect` ligeiramente diferentes.** Não
  brigue com isso — `go mod tidy` resolve.

## Lints e validação

```bash
# Go
cd api-license && go vet ./... && go mod tidy
cd installer-go && go vet ./...

# Bash (sem shellcheck no host)
bash -n install-server.sh install-painel.sh bootstrap-secrets.sh

# PHP (lint estático leve sem PHP no host)
python dist/_lint_php.py .
```

## Não esquecer ao subir release nova

1. `make release-loader` se mudou `.c` da extensão.
2. `make release` empacota o painel atual.
3. **Importante**: a `RELEASE_MASTER_KEY` rotaciona a cada release. Clientes
   na versão antiga continuam com a key antiga (registrada por version no
   Postgres). Não delete versões antigas de `releases` sem confirmar.

## Status atual (Maio 2026)

- Painel original em `script/` **já foi sanitizado** — credenciais Hostinger
  trocadas por `getenv()`. Backup do original em `../script-BACKUP-20260519-*`.
- Mercado Pago webhook integrado (sem teste em produção ainda).
- Customer portal implementado.
- Stack tudo-em-Docker funcionando.
- Pendente: testar end-to-end numa VPS de verdade.
