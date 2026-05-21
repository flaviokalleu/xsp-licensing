###############################################################################
#  XSP Licensing — Imagem do instalador do servidor central
#
#  Uso na VPS (um único comando):
#    docker run --rm -it \
#      -v /var/run/docker.sock:/var/run/docker.sock \
#      -v /root:/root \
#      -w /root \
#      ghcr.io/flaviokalleu/xsp-licensing:latest
###############################################################################

FROM alpine:3.19

# Ferramentas necessárias para o entrypoint.sh
RUN apk add --no-cache \
      bash \
      curl \
      openssl \
      python3 \
      docker-cli \
      docker-cli-compose

# Copia todos os arquivos do repositório para /app dentro da imagem
COPY . /app

RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
