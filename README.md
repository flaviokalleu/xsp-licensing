# XSP Licensing

Servidor central de licenciamento para distribuir um painel PHP como imagem Docker protegida. O servidor gera licencas, publica o instalador do cliente e hospeda um registry privado; o cliente instala o painel cifrado, cria o banco local e valida a licenca por HWID.

## Visao Rapida

| Parte | Onde roda | Funcao |
|---|---|---|
| Servidor | Sua VPS central | API de licenca, admin, portal, registry, Postgres, Redis e Caddy |
| Cliente | VPS do cliente | Painel PHP cifrado, banco do painel e agente de validacao |
| Build do painel | Servidor | Empacota o painel original em imagem Docker cifrada |

## Instalar o Servidor

Execute como `root` na VPS que sera o servidor central:

```bash
curl -sSL https://raw.githubusercontent.com/flaviokalleu/xsp-licensing/master/setup.sh | sudo bash
```

O instalador configura Docker, baixa o projeto, gera segredos, sobe os containers e mostra os acessos ao final.

Servicos criados:

| Servico | Funcao |
|---|---|
| `api` | API central em Go para licencas, ativacao, heartbeat e releases |
| `admin` | Painel administrativo para gerar keys e acompanhar instalacoes |
| `portal` | Portal do cliente para consultar licenca e resetar instalacao |
| `caddy` | Proxy reverso e publicacao do `install.sh` |
| `db` | Postgres do servidor de licencas |
| `redis` | Cache e controle de nonces |
| `registry` | Registry Docker privado para a imagem do painel |

## Instalar o Cliente

Depois de criar uma key no admin, instale o painel na VPS do cliente:

```bash
curl -sSL http://SEU_SERVIDOR/install.sh | sudo bash -s -- XSP-XXXX-XXXX-XXXX-XXXX
```

O cliente recebe somente o instalador e a imagem cifrada. O PHP original nao fica em texto claro no disco, exceto os stubs necessarios de bootstrap, router e validacao.

## Publicar o Painel do Cliente

O build usa a pasta configurada em `.env`:

```env
PANEL_SRC_HOST=/caminho/do/painel/php/original
PANEL_VERSION=10.0.3
```

Para publicar nova imagem:

```bash
cd /opt/xsp-licensing
make release
```

Durante o build, o pipeline:

- remove arquivos sensiveis como `.env`, logs, ZIPs e arquivos de teste;
- troca credenciais hardcoded por variaveis de ambiente;
- copia o SQL inicial quando existir em `Banco de dados/sql.sql`;
- cifra os arquivos PHP em `.php.enc`;
- publica `REG_HOST/xsp/panel:PANEL_VERSION`;
- registra a release na API de licencas.

## Comandos Uteis

Execute dentro da pasta do projeto no servidor:

```bash
docker compose ps
docker compose logs -f
docker compose logs -f api
docker compose restart
make release
python3 dist/_make_zips.py
```

## Estrutura do Repositorio

```text
.
|-- .github/workflows/     Pipeline de build e release no GitHub
|-- admin-dashboard/       Painel admin PHP
|-- api-license/           API central em Go e migrations do Postgres
|-- builder/               Container usado para buildar a imagem do painel
|-- customer-portal/       Portal do cliente
|-- dist/                  Scripts de distribuicao e gerador de ZIPs
|-- docs/                  Guias operacionais e seguranca
|-- installer-go/          Instalador alternativo em Go
|-- landing/               Pagina publica de instalacao
|-- painel-image/          Adaptacao, cifragem e Dockerfile do painel cliente
|-- xsp-loader/            Extensao PHP em C que abre os arquivos cifrados
|-- docker-compose.yml     Stack completa do servidor
|-- install-server.sh      Instalador shell do servidor
|-- install-painel.sh      Instalador shell do cliente
|-- setup.sh               Instalacao rapida via GitHub
`-- README.md              Este guia
```

As pastas estao separadas por responsabilidade. Evite mover diretorios principais sem atualizar Dockerfiles, `docker-compose.yml`, `Makefile`, workflow e instaladores.

## Arquivos Que Nao Devem Ir Para o Git

O `.gitignore` ja bloqueia segredos e artefatos locais:

- `.env`
- `api-license/auth/htpasswd`
- chaves `*.pem`, `*.key`, `*.p12`
- volumes e dados locais (`pgdata`, `redisdata`, `regdata`)
- artefatos do loader C
- ZIPs gerados em `dist/*.zip`
- `docker-compose.override.yml`

Para gerar ZIPs localmente:

```bash
python3 dist/_make_zips.py
```

## Seguranca

- Arquivos PHP do painel sao cifrados com AES-256-GCM.
- Tokens de licenca sao assinados com Ed25519.
- Requests usam HMAC-SHA256.
- A ativacao usa HWID e limite de instancias.
- Heartbeat mantem a instalacao vinculada ao servidor.
- O banco do painel e criado no cliente a partir do SQL empacotado na imagem.

Observacao: se alguem tiver root total na VPS do cliente, nenhuma protecao em PHP/container e matematicamente impossivel de quebrar. A protecao aqui reduz acesso casual ao codigo fonte e centraliza controle por licenca.

## Documentacao

- `docs/DEPLOY.md`: instalacao manual detalhada.
- `docs/OPERATIONS.md`: operacao e manutencao.
- `docs/SECURITY.md`: modelo de seguranca.
- `painel-image/README.md`: detalhes do empacotamento do painel.
