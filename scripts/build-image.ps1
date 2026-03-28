param(
  [ValidateSet("base", "claude", "codex", "all")]
  [string]$Target = "all",
  [string]$ClaudeVersion = "latest",
  [string]$CodexVersion = "latest",
  [switch]$NoCache,
  [switch]$Pull
)

$ErrorActionPreference = "Stop"
$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Invoke-Bake {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Targets
  )

  $args = @("buildx", "bake", "--file", (Join-Path $rootDir "docker-bake.hcl"))

  if ($Pull) {
    $args += "--pull"
  }

  if ($NoCache) {
    $args += "--no-cache"
  }

  $args += $Targets

  Write-Host "Running: CLAUDE_CODE_VERSION=$ClaudeVersion CODEX_VERSION=$CodexVersion docker $($args -join ' ')"
  $env:CLAUDE_CODE_VERSION = $ClaudeVersion
  $env:CODEX_VERSION = $CodexVersion
  docker @args
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}

function Ensure-BaseImage {
  docker image inspect "powbox-agent-base:latest" *> $null
  if ($LASTEXITCODE -eq 0) {
    return
  }

  Write-Host "Base image powbox-agent-base:latest was not found locally. Building it first."
  $env:CLAUDE_CODE_VERSION = $ClaudeVersion
  $env:CODEX_VERSION = $CodexVersion
  docker buildx bake --file (Join-Path $rootDir "docker-bake.hcl") base
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }
}

switch ($Target) {
  "all" {
    Invoke-Bake -Targets @("base")
    Invoke-Bake -Targets @("claude", "codex")
  }
  "base" {
    Invoke-Bake -Targets @("base")
  }
  "claude" {
    Ensure-BaseImage
    Invoke-Bake -Targets @("claude")
  }
  "codex" {
    Ensure-BaseImage
    Invoke-Bake -Targets @("codex")
  }
}
