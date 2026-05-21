<?php
/**
 * Roteador minimalista para servir o painel via xsp://.
 *
 * Apache aponta DocumentRoot=/var/www/html/.  Como os .php do painel estão
 * cifrados como .php.enc, este script captura todas as requisições
 * que terminam em .php e as redireciona pelo stream wrapper.
 *
 * Em prática, configuramos no Apache:
 *   <FilesMatch "\.php$">
 *     SetHandler "proxy:unix:/run/php-fpm.sock|fcgi://localhost"
 *   </FilesMatch>
 *   php_value auto_prepend_file /var/www/html/bootstrap.php
 *
 * O bootstrap valida licença e depois inclui o arquivo real via xsp://.
 */

if (PHP_SAPI === 'cli') {
    echo "use via web (Apache + PHP)\n";
    exit(0);
}

require __DIR__ . '/bootstrap.php';
