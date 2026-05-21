# installer-go

Binário Go que o cliente baixa via `curl | sudo bash` e que automatiza tudo:
ativação da licença, instalação do Docker, download das imagens do painel,
geração de `.env`/`docker-compose.yml` e subida do stack.

## Build

```bash
cd licensing/installer-go
go mod tidy

# Os segredos abaixo são embutidos no binário em compile time
export XSP_API_BASE=https://license.seudominio.com
export XSP_HMAC_SECRET=$(grep ^HMAC_PUBLIC_SECRET ../api-license/.env | cut -d= -f2)
export XSP_REGISTRY_URL=registry.seudominio.com
export XSP_PUBKEY_B64=$(grep ^ED25519_PUBLIC_KEY_B64 ../api-license/.env | cut -d= -f2)
export XSP_SIGN_KEY=/path/to/release-priv.pem   # gere com: openssl genpkey -algorithm ed25519 -out ...

make build       # gera dist/installer-linux-amd64 + .sig + .sha256 + pub.pem
```

Suba `dist/` em CDN/S3 atrás de `https://seudominio.com/dl/installer/`.

## Distribuição ao cliente

```bash
curl -sSL https://seudominio.com/install.sh | sudo bash
```

O `install.sh` faz:

1. Detecta arquitetura.
2. Baixa `installer-linux-$ARCH`, `.sig` e `pub.pem`.
3. Verifica a assinatura Ed25519.
4. Executa o instalador.

## Fluxo dentro do instalador

1. Pede `KEY`, `domínio`, `email`.
2. Calcula HWID (machine-id + MAC + UUID do disco + UUID da placa).
3. `POST /v1/activate` na API central.
4. Instala Docker se ausente.
5. `docker login` no registry privado.
6. `docker pull` das imagens listadas no manifest da release.
7. Gera `/opt/xsp/.env` (com `MASTER_KEY_SEALED` e demais segredos).
8. Gera `/opt/xsp/docker-compose.yml`.
9. `docker compose up -d`.
10. Health check em `http://localhost/healthz`.

## Dependências resolvem com `go mod tidy`

Os erros de import (`fatih/color`, `progressbar`) no editor desaparecem após
`go mod tidy`.
