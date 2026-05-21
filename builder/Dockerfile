# Imagem "builder" — contém tudo necessário para empacotar releases do painel:
# Python + cryptography (cifragem AES-GCM), OpenSSL, Docker CLI (docker-out-of-docker),
# rsync, jq, curl. Rodada via `docker compose --profile build run --rm builder`.

FROM python:3.12-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg openssl rsync jq xxd git make \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/debian $(. /etc/os-release && echo bookworm) stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-buildx-plugin \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir cryptography

WORKDIR /work

# Script de entrada — chama o pipeline de build
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["build"]
