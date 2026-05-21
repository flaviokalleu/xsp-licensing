# landing/

Página pública de instalação. Quando o cliente acessa
`https://seudominio.com/`, vê uma página bonita com o comando pronto para
copiar — o domínio é detectado automaticamente.

## Como funciona

1. Você hospeda `index.html` (ou `index.php`) em `https://seudominio.com/`.
2. Cliente acessa pelo navegador.
3. JavaScript pega `window.location.host` → monta:
   ```
   curl -sSL https://<host_detectado>/install.sh | sudo bash
   ```
4. Se o cliente já tem KEY, ele cola no input → comando vira:
   ```
   curl -sSL https://<host>/install.sh | sudo bash -s -- XSP-AAAA-BBBB-CCCC-DDDD
   ```
5. Cliente clica em "Copiar" e cola na VPS.

## Duas variantes

| Arquivo | Quando usar |
|---|---|
| **index.html** | Estático puro. Detecta domínio em JS. Funciona em qualquer web server. |
| **index.php**  | Server-side: detecta domínio via `$_SERVER`, aceita `?key=...`, dá pra logar acessos, marca `noindex`. |

Use **só uma das duas**. Se tiver as duas, configure o Apache/Caddy para
preferir a `.php`.

## Pre-fill via URL

Quando o cliente vier de um link/email com a KEY:

```
https://seudominio.com/?key=XSP-AAAA-BBBB-CCCC-DDDD
```

A página recebe a KEY no input, monta o comando final e o cliente só
precisa clicar em "Copiar".

Bom caso de uso: na confirmação de pagamento, envie o link já com a KEY
embutida. O cliente cola na VPS e em 3 minutos tem o painel rodando.

## Como hospedar (via Caddy + install-server.sh)

O `install-server.sh` já cria a pasta `/var/www/dl/`. Copie a landing:

```bash
sudo cp landing/index.html /var/www/dl/index.html
# ou
sudo cp landing/index.php /var/www/dl/index.php
```

E ajuste o `Caddyfile` se quiser servir PHP:

```caddy
seudominio.com {
    root * /var/www/dl
    php_fastcgi unix//run/php/php8.2-fpm.sock
    file_server
    try_files {path} {path}/index.php
}
```

Sem PHP, basta a versão HTML — não precisa configurar nada extra.

## Customização

Edite o CSS no topo dos dois arquivos. Procure por:
- `--accent` para a cor principal (verde água por padrão)
- `XSP. Painel Office Xtream` para mudar o título
- O rodapé com `mailto:suporte@SEUDOMINIO_CONTATO`
