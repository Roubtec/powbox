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
Push-Location $rootDir
try {
  function Invoke-Bake {
    param(
      [Parameter(Mandatory = $true)]
      [string[]]$Targets
    )

    $docker_args = @("buildx", "bake", "--file", (Join-Path $rootDir "docker-bake.hcl"))

    if ($Pull) {
      $docker_args += "--pull"
    }

    if ($NoCache) {
      $docker_args += "--no-cache"
    }

    $docker_args += $Targets

    Write-Host "Running: CLAUDE_CODE_VERSION=$ClaudeVersion CODEX_VERSION=$CodexVersion docker $($docker_args -join ' ')"
    $env:CLAUDE_CODE_VERSION = $ClaudeVersion
    $env:CODEX_VERSION = $CodexVersion
    docker @docker_args
    if ($LASTEXITCODE -ne 0) {
      exit $LASTEXITCODE
    }
  }

  function Assert-BaseImage {
    docker image inspect "powbox-agent-base:latest" *> $null
    if ($LASTEXITCODE -eq 0) {
      return
    }

    # Build the base image without -NoCache/-Pull. Those flags apply to the
    # top-layer agent build only (i.e. "don't reuse cached agent layers"). When
    # the base image is simply absent locally there is nothing to skip caching
    # for, and rebuilding it fresh unconditionally on every no-cache top-layer
    # build would be unnecessarily slow. Use `build.ps1 base -NoCache` if you
    # explicitly want a fresh base.
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
      Assert-BaseImage
      Invoke-Bake -Targets @("claude")
    }
    "codex" {
      Assert-BaseImage
      Invoke-Bake -Targets @("codex")
    }
  }
}
finally {
  Pop-Location
}
