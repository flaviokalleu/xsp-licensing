.PHONY: help bootstrap up down logs restart status secrets release release-loader pull clean build-installer

help:
	@echo "XSP Licensing — comandos disponíveis:"
	@echo ""
	@echo "  make bootstrap   — gera .env com todos os segredos (1ª vez)"
	@echo "  make up          — sobe o stack completo (Caddy, API, admin, DB, Redis, Registry)"
	@echo "  make down        — para tudo"
	@echo "  make restart     — reinicia tudo"
	@echo "  make logs        — segue logs de todos os serviços"
	@echo "  make logs S=api  — logs de um serviço específico"
	@echo "  make status      — mostra estado dos containers"
	@echo ""
	@echo "  make release     — empacota nova release do painel (PHP cifrado)"
	@echo "  make release-loader — recompila só a extensão xsp_loader.so"
	@echo ""
	@echo "  make pull        — atualiza imagens base"
	@echo "  make clean       — APAGA tudo (volumes, dados — CUIDADO)"

bootstrap:
	@test -f .env || cp .env.example .env
	bash bootstrap-secrets.sh

up: bootstrap
	docker compose up -d --build
	@echo ""
	@echo "✓ Stack rodando. Verifique status com: make status"

down:
	docker compose down

restart:
	docker compose restart

logs:
ifdef S
	docker compose logs -f $(S)
else
	docker compose logs -f
endif

status:
	docker compose ps

release:
	docker compose --profile build run --rm builder build

release-loader:
	docker compose --profile build run --rm builder build-loader

pull:
	docker compose pull

build-installer:
	@echo "→ Gerando bundle.zip..."
	@rm -f bundle.zip
	@zip -r bundle.zip api-license admin-dashboard customer-portal landing builder \
	      painel-image xsp-loader docker-compose.yml Makefile .env.example \
	      install-painel.sh Caddyfile
	@echo "→ Compilando install-server → binário único Linux/amd64..."
	@CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
	  go build -ldflags="-s -w" -o install-server install-server.go
	@rm -f bundle.zip
	@echo "✓ Pronto: ./install-server  (copie para a VPS e rode: sudo ./install-server)"

clean:
	@echo "⚠ Isso vai APAGAR TODOS os dados (Postgres, Redis, Registry). Continuar?"
	@read -p "Digite 'sim' para confirmar: " c && [ "$$c" = "sim" ]
	docker compose down -v
	rm -rf builder-cache www-public
