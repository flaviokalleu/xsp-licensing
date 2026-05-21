# OPERATIONS — Runbook do dia-a-dia

## Comandos rápidos via API

```bash
# Variáveis úteis
export API=https://license.seudominio.com
export TOK=$(grep ^ADMIN_TOKEN /opt/xsp/licensing/api-license/.env | cut -d= -f2)
H="Authorization: Bearer $TOK"
```

### Criar uma KEY

```bash
curl -X POST "$API/admin/keys" -H "$H" -H 'Content-Type: application/json' -d '{
  "email": "cliente@exemplo.com",
  "name":  "Cliente Exemplo",
  "plan_code": "pro",
  "period_days": 30
}'
```

### Listar KEYs

```bash
curl -s "$API/admin/keys?limit=200" -H "$H" | jq .
```

### Revogar uma KEY (imediato)

```bash
curl -X PATCH "$API/admin/keys/<UUID>" -H "$H" -H 'Content-Type: application/json' -d '{
  "status": "revoked",
  "reason": "pagamento estornado"
}'
```

O cliente irá detectar no próximo heartbeat (até 5 min) ou ao expirar o cache local (24 h).

### Estender assinatura +30 dias

```bash
curl -X PATCH "$API/admin/keys/<UUID>" -H "$H" -H 'Content-Type: application/json' -d '{
  "extend_days": 30
}'
```

### Blacklist por HWID / IP

```bash
curl -X POST "$API/admin/blacklist" -H "$H" -H 'Content-Type: application/json' -d '{
  "kind":"hwid","value":"abcd1234...","reason":"chave vazada em fórum"
}'
```

### Publicar nova release do painel

```bash
cd /opt/xsp/licensing/painel-image
export VERSION=10.0.4
bash build/package.sh    # gera e publica imagem + registra master_key
```

Cliente atualiza automaticamente no próximo heartbeat se a flag `action:"update"` vier no response (a implementar conforme política).

---

## Troubleshooting

### Cliente reclama "license_required" sem motivo

1. Checar relógio da VPS do cliente: `date -u` (drift > 60s mata HMAC).
2. Verificar logs:
   ```bash
   docker exec <painel> tail -f /var/log/apache2/error.log
   ```
3. Conferir validation_logs:
   ```sql
   SELECT created_at, ip, result, latency_ms
     FROM validation_logs
    WHERE installation_id = '<UUID>'
    ORDER BY created_at DESC LIMIT 20;
   ```

### Cliente trocou hardware (placa-mãe) e KEY parou

```sql
-- Limpa instalação anterior para liberar slot
UPDATE installations SET status='deactivated', deactivated_at=NOW()
 WHERE license_id='<UUID>' AND hwid='<HWID antigo>';
```

Ou via API:
```bash
# Reset HWID — depende do limite max_instances; se já no limite, marca a anterior como deactivated
curl -X POST "$API/admin/keys/<UUID>/reset-hw" -H "$H"  # (TODO: implementar)
```

Por enquanto, basta editar via SQL como acima e o cliente roda `curl … install.sh` de novo.

### Imagem do registry não baixa no cliente

- Confirmar que o registry está atrás de TLS (`https://registry.seudominio.com`).
- Conferir digest no manifest da release:
  ```bash
  docker buildx imagetools inspect registry.seudominio.com/xsp/panel:10.0.3
  ```

### Picos de fraude

Consulta:
```sql
SELECT kind, severity, COUNT(*)
  FROM fraud_events
 WHERE created_at > NOW() - INTERVAL '24 hours'
 GROUP BY kind, severity
 ORDER BY 3 DESC;
```

Bloqueio em massa por CIDR:
```bash
curl -X POST "$API/admin/blacklist" -H "$H" -d '{
  "kind":"cidr","value":"45.123.0.0/16","reason":"botnet"
}' -H 'Content-Type: application/json'
```

---

## Auditoria mensal

```sql
-- MRR estimado
SELECT p.code, COUNT(*) AS ativas, SUM(p.price_cents)/100.0 AS mrr_brl
  FROM licenses l JOIN plans p ON p.id = l.plan_id
 WHERE l.status='active'
 GROUP BY p.code;

-- Churn (canceladas / revogadas no mês)
SELECT COUNT(*) FROM licenses
 WHERE status IN ('revoked','expired')
   AND updated_at > NOW() - INTERVAL '30 days';
```
