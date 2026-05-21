.PHONY: deps build sign clean

deps:
	go mod tidy

build:
	bash scripts/build.sh

run-dev: deps
	# build local sem ofuscação para teste em VM Ubuntu
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o dist/installer-dev ./cmd/installer

clean:
	rm -rf dist/
