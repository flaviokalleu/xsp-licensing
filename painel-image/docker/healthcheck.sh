#!/usr/bin/env bash
# Falha se o Apache não responder ou a licença não estiver válida (token cache expirado).
set -e
curl -fsS -o /dev/null --max-time 3 http://127.0.0.1/healthz
