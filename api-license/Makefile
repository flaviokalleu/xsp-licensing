.PHONY: deps build run secrets test docker

deps:
	go mod tidy

build:
	CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/api-license ./cmd/server
	CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/admin-cli ./cmd/admin-cli

run: build
	./bin/api-license

secrets: build
	./bin/admin-cli gen-secrets

test:
	go test ./...

docker:
	docker build -t xsp/api-license:dev .

up:
	docker compose up -d --build

down:
	docker compose down
