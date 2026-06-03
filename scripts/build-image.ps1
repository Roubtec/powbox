param(
  [ValidateSet("base", "agent", "all")]
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
  # Upstream base image, parsed from the base Dockerfile's FROM so it never
  # drifts from what is actually built. $script:BaseSourceDigest is resolved
  # lazily just before the base target is built and stamped onto the image as a
  # label (see docker/base/Dockerfile) so agent-check-updates can detect a
  # newer base.
  $baseFrom = Select-String -Path (Join-Path $rootDir "docker/base/Dockerfile") -Pattern '^FROM\s+(\S+)' | Select-Object -First 1
  $script:BaseSourceImage = if ($baseFrom) { $baseFrom.Matches[0].Groups[1].Value } else { "node:24-slim" }
  $script:BaseSourceDigest = ""

  function Get-RegistryBaseDigest {
    $digest = docker buildx imagetools inspect $script:BaseSourceImage --format '{{.Manifest.Digest}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $digest) { return "" }
    return $digest.Trim()
  }

  function Get-LocalBaseDigest {
    $repoDigests = docker image inspect $script:BaseSourceImage --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $repoDigests) { return "" }
    foreach ($line in $repoDigests) {
      if ($line -match '@(sha256:[0-9a-f]{64})') { return $Matches[1] }
    }
    return ""
  }

  function Resolve-BaseSourceDigest {
    param([bool]$WithPull)
    # With -Pull the build uses the registry-latest base, so stamp the registry
    # digest. Otherwise the build reuses whatever base is cached locally; stamp
    # that, falling back to the registry digest when the base is not present
    # locally (buildx will pull it).
    if ($WithPull) {
      $script:BaseSourceDigest = Get-RegistryBaseDigest
    } else {
      $script:BaseSourceDigest = Get-LocalBaseDigest
      if (-not $script:BaseSourceDigest) {
        $script:BaseSourceDigest = Get-RegistryBaseDigest
      }
    }
  }

  function Invoke-Bake {
    param(
      [Parameter(Mandatory = $true)]
      [string[]]$Targets,
      [switch]$WithPull,
      [switch]$WithNoCache
    )

    if ($Targets -contains "base") {
      Resolve-BaseSourceDigest -WithPull:$WithPull.IsPresent
    }

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
    $env:BASE_SOURCE_IMAGE = $script:BaseSourceImage
    $env:BASE_SOURCE_DIGEST = $script:BaseSourceDigest
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
    Resolve-BaseSourceDigest -WithPull:$false
    $env:CLAUDE_CODE_VERSION = $ClaudeVersion
    $env:CODEX_VERSION = $CodexVersion
    $env:BASE_SOURCE_IMAGE = $script:BaseSourceImage
    $env:BASE_SOURCE_DIGEST = $script:BaseSourceDigest
    docker buildx bake --file (Join-Path $rootDir "docker-bake.hcl") base
    if ($LASTEXITCODE -ne 0) {
      exit $LASTEXITCODE
    }
  }

  # -Pull only makes sense for the base image (whose FROM is an upstream
  # registry image). The agent image's only FROM is the locally-built
  # powbox-agent-base, so passing --pull to its bake invocation would make
  # buildx try to resolve it from a registry and fail. When the user requests
  # -Pull on the agent target, refresh the base first (cascading any digest
  # change into the agent layers automatically) and then build the agent
  # without --pull.
  switch ($Target) {
    "all" {
      Invoke-Bake -Targets @("base") -WithPull:$Pull -WithNoCache:$NoCache
      Invoke-Bake -Targets @("agent") -WithNoCache:$NoCache
    }
    "agent" {
      if ($Pull) {
        Invoke-Bake -Targets @("base") -WithPull
      } else {
        Assert-BaseImage
      }
      Invoke-Bake -Targets @("agent") -WithNoCache:$NoCache
    }
    "base" {
      Invoke-Bake -Targets @("base") -WithPull:$Pull -WithNoCache:$NoCache
    }
  }
}
finally {
  Pop-Location
}
