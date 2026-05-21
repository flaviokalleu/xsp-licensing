FROM php:8.2-apache

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && docker-php-ext-install opcache \
    && rm -rf /var/lib/apt/lists/*

COPY index.php /var/www/html/index.php

RUN rm -f /var/www/html/index.html && \
    chown -R www-data:www-data /var/www/html

EXPOSE 80
