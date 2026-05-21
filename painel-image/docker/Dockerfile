# Painel XSP — imagem final que vai pro cliente.
# Construída pelo pipeline em build/package.sh.
# Contexto de build esperado contém:
#   - bootstrap.php (claro)
#   - license_check.php (claro)
#   - xsp-ext/xsp_loader.so
#   - **/*.php.enc        (todos os PHPs cifrados)
#   - assets (img/css/js/sql/etc.)
#   - apache.conf, php.ini, entrypoint.sh, healthcheck.sh

FROM php:8.2-apache-bookworm

ARG VERSION=10.0.3
ENV XSP_VERSION=$VERSION

# 1) Dependências PHP necessárias
RUN apt-get update && apt-get install -y --no-install-recommends \
        libssl3 libcurl4 libonig5 libxml2 ca-certificates curl \
    && docker-php-ext-install pdo_mysql mysqli opcache \
    && a2enmod rewrite headers \
    && rm -rf /var/lib/apt/lists/*

# 2) Instala extensão xsp_loader
COPY xsp-ext/xsp_loader.so /usr/local/lib/php/extensions/xsp_loader.so
RUN echo "extension=/usr/local/lib/php/extensions/xsp_loader.so" \
        > /usr/local/etc/php/conf.d/00-xsp.ini && \
    echo "opcache.enable=1\nopcache.validate_timestamps=0\nopcache.save_comments=0\nopcache.file_cache_only=0" \
        > /usr/local/etc/php/conf.d/10-opcache.ini

# 3) Copia conteúdo: bootstrap + license_check em claro, demais .php.enc
COPY --chown=www-data:www-data . /var/www/html/

# 4) Remove qualquer .php que tenha vazado (defesa em profundidade) exceto stubs
RUN find /var/www/html -name '*.php' \
        ! -name 'bootstrap.php' \
        ! -name 'license_check.php' \
        ! -name 'index_router.php' \
        -delete && \
    chmod 644 /var/www/html/bootstrap.php /var/www/html/license_check.php

# 5) Apache config + PHP ini
COPY apache.conf       /etc/apache2/sites-enabled/000-default.conf
COPY php.ini-overrides /usr/local/etc/php/conf.d/99-xsp.ini

# 6) Estado runtime
RUN mkdir -p /var/lib/xsp && chown www-data:www-data /var/lib/xsp && chmod 700 /var/lib/xsp

# 7) Healthcheck
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod 755 /usr/local/bin/healthcheck.sh
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
    CMD /usr/local/bin/healthcheck.sh

# 8) Hardening — remove ferramentas que ajudariam análise
RUN rm -f /usr/bin/gdb /usr/bin/strace /usr/bin/ltrace /usr/bin/xxd 2>/dev/null || true && \
    chmod 500 /usr/local/lib/php/extensions/xsp_loader.so && \
    chown root:root /usr/local/lib/php/extensions/xsp_loader.so

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

EXPOSE 80
ENTRYPOINT ["/entrypoint.sh"]
CMD ["apache2-foreground"]
