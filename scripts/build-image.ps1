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
      [string[]]$Targets,
      [switch]$WithPull,
      [switch]$WithNoCache
    )

    $docker_args = @("buildx", "bake", "--file", (Join-Path $rootDir "docker-bake.hcl"))

    if ($WithPull) {
      $docker_args += "--pull"
    }

    if ($WithNoCache) {
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

    # Build the base image without -NoCache. That flag applies to the top-layer
    # agent build only (i.e. "don't reuse cached agent layers"). When the base
    # image is simply absent locally there is nothing to skip caching for, and
    # rebuilding it fresh unconditionally on every no-cache top-layer build
    # would be unnecessarily slow. Use `build.ps1 base -NoCache` if you
    # explicitly want a fresh base.
    Write-Host "Base image powbox-agent-base:latest was not found locally. Building it first."
    $env:CLAUDE_CODE_VERSION = $ClaudeVersion
    $env:CODEX_VERSION = $CodexVersion
    docker buildx bake --file (Join-Path $rootDir "docker-bake.hcl") base
    if ($LASTEXITCODE -ne 0) {
      exit $LASTEXITCODE
    }
  }

  # -Pull only makes sense for the base image (whose FROM is an upstream
  # registry image). The agent images' only FROM is the locally-built
  # powbox-agent-base, so passing --pull to their bake invocation would make
  # buildx try to resolve it from a registry and fail. When the user requests
  # -Pull on an agent target, refresh the base first (cascading any digest
  # change into the agent layers automatically) and then build the agent
  # without --pull.
  switch ($Target) {
    "all" {
      Invoke-Bake -Targets @("base") -WithPull:$Pull -WithNoCache:$NoCache
      Invoke-Bake -Targets @("claude", "codex") -WithNoCache:$NoCache
    }
    "base" {
      Invoke-Bake -Targets @("base") -WithPull:$Pull -WithNoCache:$NoCache
    }
    "claude" {
      if ($Pull) {
        Invoke-Bake -Targets @("base") -WithPull
      } else {
        Assert-BaseImage
      }
      Invoke-Bake -Targets @("claude") -WithNoCache:$NoCache
    }
    "codex" {
      if ($Pull) {
        Invoke-Bake -Targets @("base") -WithPull
      } else {
        Assert-BaseImage
      }
      Invoke-Bake -Targets @("codex") -WithNoCache:$NoCache
    }
  }
}
finally {
  Pop-Location
}
