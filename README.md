# XSP Licensing — Servidor Central

Sistema de licenciamento anti-pirataria para o painel IPTV XSP.  
Distribui o painel como imagem Docker cifrada, com validação online por HWID + IP.

## Instalação na VPS (1 comando)

Execute como **root** na VPS que vai rodar o servidor central:

```bash
docker run --rm -it \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /root:/root \
  -w /root \
  ghcr.io/flaviokalleu/xsp-licensing:latest
```

O instalador vai perguntar interativamente:

| Pergunta | Descrição |
|---|---|
| Modo de acesso | `S` = subdomínios separados + TLS (recomendado produção) |
| | `U` = domínio único com paths `/api`, `/admin` |
| | `I` = só IP, sem TLS (testes locais) |
| Domínios | Configurados conforme o modo escolhido |
| E-mail Let's Encrypt | Para emissão automática de certificados TLS |
| Usuário admin | Login do painel administrativo |

Ao final, a senha do admin é exibida **uma única vez** — anote.

## O que sobe

| Container | Função |
|---|---|
| `api` | API central em Go (licenças, heartbeat, fraude) |
| `admin` | Painel admin PHP (CRUD de keys) |
| `portal` | Portal self-service do cliente |
| `caddy` | Reverse proxy + TLS automático (Let's Encrypt) |
| `postgres` | Banco de dados central |
| `redis` | Cache de nonces e heartbeats |
| `registry` | Registry Docker privado para imagens do painel |

## Pré-requisitos

- VPS Linux (Ubuntu 22.04+ recomendado)
- Docker 24+ instalado
- Portas abertas: `80`, `443`, `5000` (registry)
- DNS apontado para o IP da VPS (modo S ou U)

### Instalar Docker na VPS

```bash
curl -fsSL https://get.docker.com | sh
```

## Comandos pós-instalação

Execute em `/root` após instalar:

```bash
docker compose ps          # estado dos containers
docker compose logs -f     # logs em tempo real
docker compose logs -f api # logs de um serviço específico
docker compose restart     # reinicia tudo
make release               # publica nova versão do painel
make release-loader        # recompila extensão C (xsp_loader.so)
```

## Próximos passos após instalar

1. Acesse `https://SEU_DOMINIO_ADMIN` com o usuário e senha gerados
2. Crie uma **KEY** para o cliente
3. Envie ao cliente o comando de instalação:
   ```bash
   curl -fsSL https://SEU_DOMINIO/install.sh | sudo bash -s -- XSP-KEY-AQUI
   ```
4. Para publicar o painel: `make release`

## Arquitetura de segurança

- **AES-256-GCM** — arquivos `.php` do painel trafegam e ficam em disco cifrados
- **Ed25519** — tokens de licença assinados com chave privada do servidor
- **HMAC-SHA256** — autenticação de requests entre painel e API
- **HWID binding** — licença vinculada ao hardware + IP de ativação
- **Heartbeat 5 min** — painel bloqueia após 24h sem contato com API
- **Clone detection** — IP de heartbeat diferente do IP de ativação → bloqueio imediato

## Estrutura do repositório

```
├── Dockerfile              Imagem Docker do instalador (CI/CD)
├── entrypoint.sh           Script bash do instalador interativo
├── docker-compose.yml      Stack completa dos 7 serviços
├── Caddyfile               Configuração do reverse proxy
├── Makefile                Atalhos de operação
├── install-painel.sh       Script de instalação no cliente
├── api-license/            API central em Go
├── admin-dashboard/        Painel admin PHP
├── customer-portal/        Portal do cliente PHP
├── landing/                Página pública de instalação
├── painel-image/           Pipeline de build do painel cifrado
├── xsp-loader/             Extensão PHP em C (decifragem em memória)
└── builder/                Container de build para make release
```

## CI/CD

O GitHub Actions constrói e publica automaticamente a imagem no GHCR a cada push em `main`:

```
ghcr.io/flaviokalleu/xsp-licensing:latest
ghcr.io/flaviokalleu/xsp-licensing:<sha>
```

Também cria um GitHub Release com o comando de instalação pronto.

## Segredos (nunca commitar)

- `.env` — ADMIN_TOKEN, Ed25519 privada, RELEASE_MASTER_KEY
- `api-license/.env`
- `api-license/auth/htpasswd`
- Qualquer `*.pem` privado

O `.gitignore` já exclui todos esses arquivos.
