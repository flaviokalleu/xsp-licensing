# painel-image

Pipeline que **transforma o painel PHP original (script/) em uma imagem Docker
fechada**, com PHP cifrado em disco e destravado em runtime pela extensão
`xsp_loader`.

## Pré-requisitos

- Docker + buildx
- `python3` com `cryptography` (`pip install cryptography`)
- `openssl`, `rsync`, `curl`
- A extensão `xsp_loader.so` compilada (`../xsp-loader/build.sh`)
- A `api-license` rodando e acessível em `$API_BASE`
- O `ADMIN_TOKEN` da `api-license`

## Estrutura

```
painel-image/
├── build/                  # scripts do pipeline
│   ├── adapt-panel.py      # 1º — saneia credenciais hardcoded → env vars
│   ├── obfuscate.sh        # 2º — opcional: ofuscação yakpro-po
│   ├── encrypt.sh          # 3º — cifra cada .php em .php.enc (AES-256-GCM)
│   └── package.sh          # orquestra tudo + build Docker + register API
├── docker/                 # contexto da imagem cliente
│   ├── Dockerfile          # FROM php:8.2-apache + ext xsp_loader
│   ├── apache.conf         # auto_prepend_file = bootstrap.php + include_path xsp://
│   ├── php.ini-overrides   # hardening
│   ├── entrypoint.sh
│   └── healthcheck.sh
└── php-stub/               # PHPs em claro que vão dentro da imagem
    ├── bootstrap.php       # carrega license_check + redireciona via xsp://
    ├── license_check.php   # heartbeat + cache + unseal master key
    └── index_router.php
```

## Adaptação do painel (`adapt-panel.py`)

Antes da cifragem, o pipeline roda este script para sanear o painel:

1. **Substitui credenciais hardcoded** (`$db_host = 'localhost'; $db_pass = 'xxx'`)
   por `getenv('DB_HOST') ?: 'localhost'; getenv('DB_PASS') ?: ''`.
   - Cobre `$db_host/$db_user/$db_pass/$db_name`,
     `$endereco/$banco/$dbusuario/$dbsenha`, `$servername/$username_db/...`,
     e `$host/$dbname/$user/$pass`.
2. **Cria `_xsp_db.php`** — conector central usando `xsp_db()` / `xsp_mysqli()`.
3. **Remove arquivos perigosos**: `TUTORIAL.txt`, `error_log*`, `*.bak`, `*.gz`,
   `backups/`, `README.md`, `.htaccess.bak`.
4. **Verifica vazamentos restantes** — se algum credencial conhecido
   sobrar no código, emite warning para revisão manual.

O painel **original em `script/` não é modificado** — o adapt opera sobre
uma cópia em `/tmp/xsp-build.*/raw/`.

## Como executar (publicar uma release)

```bash
# 1) Compile a extensão (uma vez por versão do PHP)
cd ../xsp-loader && bash build.sh && cd ../painel-image

# 2) Configure
export PANEL_SRC=../../script                  # painel original
export VERSION=10.0.3
export REGISTRY=registry.seudominio.com/xsp/panel
export API_BASE=https://license.seudominio.com
export INTERNAL_TOKEN=$ADMIN_TOKEN              # do .env da api-license

# 3) Faça login no registry privado
docker login $REGISTRY

# 4) Rode o pipeline
bash build/package.sh
```

Ao final:
- A imagem `$REGISTRY:$VERSION` está publicada.
- A `MASTER_KEY` foi registrada na `api-license` e será entregue, cifrada por
  HWID, a cada cliente ativo no `/v1/activate` e `/v1/heartbeat`.

## Como o cliente vê

1. Cliente roda `curl … | sudo bash` (do `installer-go`).
2. Instalador puxa essa imagem do registry.
3. Container sobe → `bootstrap.php` valida licença → `xsp_unlock($master)`.
4. Apache serve qualquer `.php` via `xsp://` → painel original roda normalmente.
5. Sem licença válida em 24h → bootstrap retorna HTTP 402 e painel para de servir.
