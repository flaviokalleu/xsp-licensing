# SECURITY — Camadas de Proteção e Limitações

## Camadas de defesa

| # | Camada | Onde está |
|---|---|---|
| 1 | PHP cifrado em disco (AES-256-GCM) | `painel-image/build/encrypt.sh` |
| 2 | Master key entregue pela API a cada boot, cifrada com HWID | `api-license/internal/crypto/SealMasterKey` |
| 3 | Decifragem em extensão C compilada, não em PHP | `xsp-loader/xsp_loader.c` |
| 4 | HWID lock (machine-id + board UUID + disk UUID + MAC) | `system.ComputeHWID` |
| 5 | Heartbeat HMAC + cache 24h máx | `php-stub/license_check.php` |
| 6 | Anti-debug ptrace | `xsp_loader.c::xsp_anti_debug` |
| 7 | Container read-only + sem shell + cap_drop | `installer-go/.../composeYAML` |
| 8 | Token JWT-like Ed25519 (chave privada só no server) | `crypto.Signer` |
| 9 | Rate limit + anti-replay (nonce em Redis) | `middleware.HMACVerify` |
| 10 | Auditoria + fraud events | `repo.LogFraud`, `repo.LogValidation` |
| 11 | Binário do instalador obfuscado (garble) + assinado (Ed25519) | `installer-go/scripts/build.sh` |
| 12 | `disable_functions` PHP (exec, system, eval, ...) | `painel-image/docker/php.ini-overrides` |

## Modelo de ameaça

Quem pode atacar:

1. **Cliente honesto que perdeu a licença**: o painel para. Solução: pagar.
2. **Cliente que quer rodar a mais máquinas**: HWID lock + `max_instances` no banco. Quando atingir limite, recebe erro `409`.
3. **Cliente que clonou a VPS** (snapshot, restore em outro IP): HWID muda (disk UUID + machine-id mudam), API recusa. Master key nunca chega na máquina clonada.
4. **Ex-cliente com a imagem Docker baixada**: tem `.php.enc` ilegível e a `.so` que precisa de chave externa. Sem licença ativa, não recebe chave.
5. **Atacante com `gdb` na VPS**: `ptrace(PTRACE_TRACEME)` no MINIT bloqueia anexação. `disable_functions` impede tools PHP comuns.
6. **Atacante com root + dump de memória**: pode extrair a master key do processo apache. **Aqui paramos** — ver "Limitações".

## Limitações honestas

- **Root na máquina do cliente vence**. Qualquer DRM acaba na mesma trincheira: se o atacante controla o kernel, ele eventualmente tira a chave da RAM. Mitigamos com TracerPid check + remoção de gdb/strace da imagem, mas não é um cofre HSM.
- **Vazamento da MASTER_KEY no seu servidor é catastrófico** — todo cliente da release fica vulnerável. Trate `RELEASE_MASTER_KEY` no `.env` como segredo crítico: backup criptografado, rotate por release, considere mover para Vault/KMS depois.
- **DDoS na API tira todos os clientes do ar em 24h** (cache offline expira). Mitigação: Cloudflare na frente, multi-VPS atrás de DNS round-robin.
- **O schema do MariaDB do cliente é visível** — qualquer um com `docker exec` no MariaDB vê estrutura de tabelas. Conteúdo do painel (regras de negócio, layout) pode ser inferido. Lógica em PHP cifrado continua opaca.
- **`disable_functions` pode ser revertido** se o cliente substituir `php.ini`. Mitigação: container read-only impede edição; imagem nova a cada release.
- **Yakpro-po (ofuscação PHP)** é só "speed bump" — não substitui a cifragem.

## Boas práticas operacionais

1. **Rotacione `RELEASE_MASTER_KEY` a cada release**. Defina política: 1 MK por versão minor.
2. **Não commit `.env`** — use `git-crypt` ou `sops` se versionar.
3. **Logs centralizados** — encaminhe `/var/log/api-license/*` para Loki/CloudWatch.
4. **Alertas em fraud_events severity >= 4** — Telegram/Slack imediato.
5. **Rotação do `ADMIN_TOKEN`** sempre que alguém da equipe sair.
6. **Honeypot**: gere uma KEY e plante numa rede de "scripts piratas". Se ativar, você captura HWID/IP de quem tentou. Bloqueie e investigue padrões.
7. **Monitoramento de canary tokens**: strings únicas embutidas no PHP cifrado — se aparecerem em fóruns/Google, você sabe que vazou.

## Roadmap de hardening futuro

- [ ] mTLS entre painel e api-license (clientes enterprise)
- [ ] HSM/Vault para `ED25519_PRIVATE_KEY` e `RELEASE_MASTER_KEY`
- [ ] Imagem `FROM scratch` com Apache estaticamente linkado (sem libs externas para hookar)
- [ ] Verificação de assinatura da `.so` pela própria extensão no boot
- [ ] Cosign + Sigstore para assinatura das imagens Docker
- [ ] WebAuthn no admin-dashboard (substituir basic auth)
- [ ] Sentry/Honeycomb para observabilidade
- [ ] Auto-update do painel com canary % por release
