# xsp_loader

Extensão PHP nativa em C que registra um **stream wrapper `xsp://`** capaz de
decifrar em memória arquivos PHP cifrados com AES-256-GCM.

## Como funciona

1. No boot do container, o bootstrap PHP chama `xsp_unlock($hexkey)` com a
   chave entregue pela API de licença (cifrada com HWID).
2. Após `xsp_unlock`, qualquer `include "xsp:///var/www/html/file.php"` lê o
   arquivo `file.php.enc`, decifra em memória e devolve o conteúdo ao Zend
   engine para execução.
3. A chave reside apenas na memória da extensão — nunca toca o disco e não é
   acessível pelo userland PHP após o unlock (o buffer hex passado é zerado).

## Layout do `.php.enc`

```
[4B  "XSP1"] [12B IV] [N B ciphertext] [16B tag]
```

## Build

```bash
cd licensing/xsp-loader
bash build.sh       # produz build/xsp_loader.so usando Docker
```

Para compilar diretamente numa máquina com PHP devel instalado:

```bash
apt-get install -y libssl-dev php-dev pkg-config build-essential
phpize
./configure --enable-xsp_loader
make
sudo cp modules/xsp_loader.so $(php -r 'echo ini_get("extension_dir");')/
echo 'extension=xsp_loader.so' | sudo tee /etc/php/8.2/cli/conf.d/00-xsp.ini
php -m | grep xsp_loader
```

## Funções expostas ao PHP

| Função          | Descrição                                              |
|-----------------|--------------------------------------------------------|
| `xsp_unlock($hex)` | Recebe master key (64 hex chars). Retorna `bool`. |
| `xsp_locked()`     | `true` se ainda não destravado.                  |
| `xsp_version()`    | Retorna versão da extensão.                      |

## Segurança

- Anti-debug: `ptrace(PTRACE_TRACEME)` no `MINIT` — qualquer debugger ativo
  faz o processo sair com código 99.
- `OPENSSL_cleanse` para zerar a chave em `MSHUTDOWN`.
- Buffer hex é zerado em PHP land após uso (`memset` na string original).
