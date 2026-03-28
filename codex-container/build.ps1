param(
    [string]$Version = "latest"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$composeFile = Join-Path $scriptDir "docker-compose.yml"

Write-Host "Building codex-dev image with Codex CLI version: $Version"
docker compose -f $composeFile build --build-arg CODEX_VERSION=$Version --no-cache

Write-Host "Done. Image: codex-dev:latest"
Write-Host "Run: .\codex-container.ps1 C:\path\to\project"
