# build-installer.ps1 — Gera bundle.zip e compila install-server para Linux amd64.
# Execute dentro do diretório licensing/:
#   cd licensing
#   .\build-installer.ps1

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

Write-Host "-> Gerando bundle.zip..."

# Remove bundle anterior
if (Test-Path bundle.zip) { Remove-Item bundle.zip -Force }

# Itens a empacotar (ordem importa para estrutura do zip)
$items = @(
    "api-license",
    "admin-dashboard",
    "customer-portal",
    "landing",
    "builder",
    "painel-image",
    "xsp-loader",
    "docker-compose.yml",
    "Makefile",
    ".env.example",
    "install-painel.sh",
    "Caddyfile"
)

# Verifica que todos existem
foreach ($item in $items) {
    if (-not (Test-Path $item)) {
        Write-Error "Nao encontrado: $item"
        exit 1
    }
}

Compress-Archive -Path $items -DestinationPath bundle.zip -CompressionLevel Optimal
$z = Get-Item bundle.zip
Write-Host ("   bundle.zip: {0:N0} KB" -f ($z.Length / 1KB))

Write-Host "-> Compilando install-server (linux/amd64)..."
$env:GOOS        = "linux"
$env:GOARCH      = "amd64"
$env:CGO_ENABLED = "0"

go build -ldflags="-s -w" -o install-server install-server.go
if ($LASTEXITCODE -ne 0) {
    Write-Error "go build falhou."
    exit 1
}

Remove-Item bundle.zip -Force -ErrorAction SilentlyContinue

$b = Get-Item install-server
Write-Host ("   install-server: {0:F1} MB (Linux amd64, binario unico)" -f ($b.Length / 1MB))
Write-Host ""
Write-Host "Pronto! Copie 'install-server' para a VPS e rode:"
Write-Host "   sudo ./install-server"
