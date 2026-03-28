param(
    [string]$Version = "latest"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$composeFile = Join-Path $scriptDir "docker-compose.yml"

Write-Host "Building claude-code-dev image with Claude Code version: $Version"
docker compose -f $composeFile build --build-arg CLAUDE_CODE_VERSION=$Version --no-cache

Write-Host "Done. Image: claude-code-dev:latest"
Write-Host "Run: .\claude-container.ps1 C:\path\to\project"
