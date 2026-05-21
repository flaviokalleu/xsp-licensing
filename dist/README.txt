═══════════════════════════════════════════════════════════════════════════════
                   XSP LICENSING — Pacotes de Distribuição
═══════════════════════════════════════════════════════════════════════════════

Esta pasta contém 3 ZIPs prontos para uso, mais cópias soltas dos instaladores
para acesso rápido.


┌─────────────────────────────────────────────────────────────────────────────┐
│ 1) xsp-licensing-FULL.zip   (75 KB)                                         │
│    BUNDLE COMPLETO — USE ESTE                                               │
├─────────────────────────────────────────────────────────────────────────────┤
│  Conteúdo: tudo (api-license, installer-go, xsp-loader, painel-image,       │
│            admin-dashboard, docs, todos os instaladores)                    │
│                                                                             │
│  Para quem: VOCÊ. É o backup completo do projeto.                           │
│                                                                             │
│  Como usar:                                                                 │
│    unzip xsp-licensing-FULL.zip                                             │
│    cd xsp-licensing                                                         │
│    sudo bash INSTALL.sh                                                     │
└─────────────────────────────────────────────────────────────────────────────┘


┌─────────────────────────────────────────────────────────────────────────────┐
│ 2) xsp-licensing-SERVER.zip   (59 KB)                                       │
│    SÓ LADO SERVIDOR (gerador de licença)                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│  Conteúdo: api-license, xsp-loader, painel-image, admin-dashboard,          │
│            install-server.sh, install-painel.sh (p/ você editar e publicar) │
│                                                                             │
│  Para quem: você ENVIA este zip para a VPS central (que vai gerar/validar   │
│             as licenças).                                                   │
│                                                                             │
│  Como usar na VPS central:                                                  │
│    scp xsp-licensing-SERVER.zip root@SUA_VPS:/tmp/                          │
│    ssh root@SUA_VPS                                                         │
│    cd /opt && unzip /tmp/xsp-licensing-SERVER.zip                           │
│    cd xsp-server                                                            │
│    sudo bash INSTALL.sh server                                              │
└─────────────────────────────────────────────────────────────────────────────┘


┌─────────────────────────────────────────────────────────────────────────────┐
│ 3) xsp-licensing-PAINEL.zip   (7 KB)                                        │
│    SÓ INSTALADOR DO CLIENTE                                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│  Conteúdo: APENAS install-painel.sh + docs                                  │
│                                                                             │
│  Para quem: clientes que compram o painel.                                  │
│                                                                             │
│  NÃO mande este zip para clientes diretamente.                              │
│  Em vez disso:                                                              │
│    1) Edite install-painel.sh substituindo os 4 placeholders                │
│       (API_BASE, HMAC_PUBLIC_SECRET, REGISTRY_HOST, REGISTRY_USER)          │
│    2) Hospede em https://SEUDOMINIO/install.sh                              │
│    3) Cliente roda:                                                         │
│         curl -sSL https://SEUDOMINIO/install.sh | sudo bash                 │
└─────────────────────────────────────────────────────────────────────────────┘


╔═════════════════════════════════════════════════════════════════════════════╗
║                       FLUXO RECOMENDADO PASSO-A-PASSO                       ║
╠═════════════════════════════════════════════════════════════════════════════╣
║                                                                             ║
║  ETAPA 1 — Configurar VPS central (você, uma vez)                           ║
║  ─────────────────────────────────────────────────                          ║
║    1. Aponte 3 subdomínios para a VPS:                                      ║
║         license.SEUDOMINIO.com                                              ║
║         registry.SEUDOMINIO.com                                             ║
║         admin.SEUDOMINIO.com                                                ║
║    2. Envie xsp-licensing-SERVER.zip para a VPS                             ║
║    3. unzip + cd xsp-server + sudo bash INSTALL.sh                          ║
║    4. Anote o ADMIN_TOKEN e o HMAC_PUBLIC_SECRET que aparecem no .env       ║
║                                                                             ║
║  ETAPA 2 — Publicar o instalador do painel (você, uma vez)                  ║
║  ──────────────────────────────────────────────────────────                 ║
║    1. Edite install-painel.sh:                                              ║
║         API_BASE="https://license.SEUDOMINIO.com"                           ║
║         HMAC_PUBLIC_SECRET="<copie do .env>"                                ║
║         REGISTRY_HOST="registry.SEUDOMINIO.com"                             ║
║         REGISTRY_USER="license"                                             ║
║    2. Copie para /var/www/dl/install.sh (Caddy já serve)                    ║
║                                                                             ║
║  ETAPA 3 — Publicar primeira release do painel (você, sempre que mudar)     ║
║  ──────────────────────────────────────────────────────────────────────     ║
║    cd /opt/xsp-server/xsp-loader && bash build.sh                           ║
║    cd ../painel-image                                                       ║
║    export PANEL_SRC=/path/para/script VERSION=10.0.3                        ║
║    export REGISTRY=registry.SEUDOMINIO.com/xsp/panel                        ║
║    export API_BASE=https://license.SEUDOMINIO.com                           ║
║    export INTERNAL_TOKEN=$(grep ^ADMIN_TOKEN ../api-license/.env|cut -d= -f2)║
║    bash build/package.sh                                                    ║
║                                                                             ║
║  ETAPA 4 — Vender uma licença                                               ║
║  ────────────────────────────                                               ║
║    1. Acesse https://admin.SEUDOMINIO.com                                   ║
║    2. Botão "Gerar KEY" → preenche e-mail/plano/dias                        ║
║    3. Envia a KEY ao cliente por email/WhatsApp                             ║
║                                                                             ║
║  ETAPA 5 — Cliente instala (cliente, sempre)                                ║
║  ──────────────────────────────────────────                                 ║
║    Numa VPS Ubuntu 22.04+:                                                  ║
║      curl -sSL https://SEUDOMINIO.com/install.sh | sudo bash                ║
║    Cola a KEY, domínio, e-mail → painel rodando em ~3 min                   ║
║                                                                             ║
╚═════════════════════════════════════════════════════════════════════════════╝


ARQUIVOS SOLTOS (não em zip)
─────────────────────────────
  INSTALL.sh           Master router (pergunta server ou painel)
  install-server.sh    Instalador da infra central
  install-painel.sh    Instalador do painel (EDITE antes de hospedar)
  _make_zips.py        Script que regenera os 3 zips


REGERAR OS ZIPS
───────────────
Se você alterar arquivos no projeto e quiser zipar de novo:

  cd dist/
  python _make_zips.py


DOCUMENTAÇÃO COMPLETA
─────────────────────
  ../README.md         Visão geral
  ../docs/DEPLOY.md    Passo-a-passo de deploy detalhado
  ../docs/OPERATIONS.md Runbook (criar/revogar KEY, troubleshoot)
  ../docs/SECURITY.md  Camadas de proteção e limitações
