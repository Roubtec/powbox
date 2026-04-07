param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("claude", "codex")]
  [string]$Agent,
  [string]$ProjectPath = ".",
  [switch]$Build,
  [switch]$Detach,
  [switch]$Shell,
  [switch]$Persist,
  [switch]$Resume,
  [switch]$Volatile,
  [string]$Exec = "",
  [string]$Ctx = ""
)

$ErrorActionPreference = "Stop"

if ($Exec -ne "" -and $Agent -ne "codex") {
  Write-Error "-Exec is only supported for codex."
  exit 1
}

if (-not (Test-Path $ProjectPath -PathType Container)) {
  Write-Error "Error: project path does not exist: $ProjectPath"
  exit 1
}

if ($Ctx -ne "" -and -not (Test-Path $Ctx -PathType Container)) {
  Write-Error "Error: context path does not exist: $Ctx"
  exit 1
}
$resolvedCtx = if ($Ctx -ne "") { (Resolve-Path $Ctx).Path } else { "" }
$resolvedProject = (Resolve-Path $ProjectPath).Path
# Resolve symlinks/junctions so the same physical directory always gets the same hash,
# regardless of which path was used to reference it.
try {
  $linkTarget = [System.IO.DirectoryInfo]::new($resolvedProject).ResolveLinkTarget($true)
  if ($linkTarget) { $resolvedProject = $linkTarget.FullName }
}
catch {
  # ResolveLinkTarget requires .NET 6+ / pwsh 7.1+; fall back to Resolve-Path result.
}
# Strip trailing directory separator so that "C:\project" and "C:\project\" hash identically.
# Guard against trimming filesystem root paths (e.g. "C:\" → "C:" or "/" → ""), which would
# break Split-Path, hashing, and Docker bind-mount paths. Only trim when the path extends
# beyond its own root (i.e. it is not itself a root path like "C:\" or "/").
$pathRoot = [System.IO.Path]::GetPathRoot($resolvedProject)
if ($resolvedProject.Length -gt $pathRoot.Length) {
  $resolvedProject = $resolvedProject.TrimEnd([System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar)
}
$projectName = Split-Path $resolvedProject -Leaf
$projectHash = [System.BitConverter]::ToString(
  [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [System.Text.Encoding]::UTF8.GetBytes($resolvedProject.ToLowerInvariant())
  )
).Replace("-", "").Substring(0, 12).ToLowerInvariant()

$safeProject = (($projectName.ToLowerInvariant() -replace '[^a-z0-9_.-]', '-') -replace '-+', '-').Trim('-')
$projectSlug = "$safeProject-$projectHash"
$containerName = "$Agent-$projectSlug"
$nodeModulesVolume = "agent-nm-$projectSlug"

$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$composeShared = Join-Path $rootDir "compose.shared.yml"
$composeOverlay = Join-Path $rootDir "compose.$Agent.yml"
$composeArgs = @("-p", "powbox", "-f", $composeShared, "-f", $composeOverlay)

# Ensure shared named volumes exist (compose won't auto-create external volumes).
$sharedVolumes = @("agent-gh-config", "agent-pnpm-store", "agent-zsh-history")
if ($Agent -eq "claude") { $sharedVolumes += "claude-config" }
else { $sharedVolumes += "codex-config" }
foreach ($vol in $sharedVolumes) {
  docker volume inspect $vol *> $null
  if ($LASTEXITCODE -ne 0) {
    docker volume create $vol *> $null
  }
}

$env:WORKSPACE_PATH = $resolvedProject
$env:PROJECT_NAME = $projectSlug
$workspaceMount = "/workspace/$projectSlug"

if ($Agent -eq "claude") {
  $agentHostConfigDir = if ($env:CLAUDE_HOST_CONFIG_DIR) { $env:CLAUDE_HOST_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".claude" }
}
else {
  $agentHostConfigDir = if ($env:CODEX_HOST_CONFIG_DIR) { $env:CODEX_HOST_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".codex" }
}

$ghHostConfigPath = if ($env:GH_HOST_CONFIG_DIR) { $env:GH_HOST_CONFIG_DIR } else { "$env:APPDATA\GitHub CLI" }
$gitConfigPath = if ($env:GIT_CONFIG_PATH) { $env:GIT_CONFIG_PATH } else { Join-Path $env:USERPROFILE ".gitconfig" }

$containerExists = $false
$containerRunning = $false

docker container inspect $containerName *> $null
if ($LASTEXITCODE -eq 0) {
  $containerExists = $true
  $runningState = docker container inspect --format '{{.State.Running}}' $containerName 2>$null
  $containerRunning = ($LASTEXITCODE -eq 0 -and $runningState.Trim() -eq 'true')
}

if ($Build) {
  & (Join-Path $rootDir "scripts/build-image.ps1") -Target $Agent
}

if ($Resume) {
  if (-not $containerExists) {
    Write-Error "No persisted container named $containerName was found. Start it once normally, or with -Persist if you want to be explicit."
    exit 1
  }

  docker start -ai $containerName
  exit $LASTEXITCODE
}

if (-not $Volatile -and $containerExists) {
  # Detect whether the requested /ctx mount differs from the existing container.
  # If it does, remove the stopped container so it gets recreated with the correct mounts.
  # When -Ctx is omitted, keep whatever is already mounted (or not) — the user can add
  # -Volatile to force a clean slate.
  $existingCtx = (docker inspect --format '{{range .Mounts}}{{if eq .Destination "/ctx"}}{{.Source}}{{end}}{{end}}' $containerName 2>$null)
  if ($LASTEXITCODE -ne 0) { $existingCtx = "" }

  if ($Ctx -ne "") {
    $wantCtx = $resolvedCtx
    # Normalise for comparison: Docker Desktop may report Windows bind-mount sources
    # using Linux-style paths (e.g. /run/desktop/mnt/host/c/..., /host_mnt/c/...,
    # /mnt/c/...).  Convert those known prefixes to drive:/... form so both sides
    # use the same representation before comparing.
    function ConvertFrom-DockerDesktopPath ([string]$p) {
      $p = $p -replace '\\', '/'
      if ($p -match '^/run/desktop/mnt/host/([a-z])/(.+)$') { return "$($Matches[1]):/$($Matches[2])" }
      if ($p -match '^/host_mnt/([a-z])/(.+)$') { return "$($Matches[1]):/$($Matches[2])" }
      if ($p -match '^/mnt/([a-z])/(.+)$') { return "$($Matches[1]):/$($Matches[2])" }
      return $p
    }
    $existingNorm = (ConvertFrom-DockerDesktopPath $existingCtx).TrimEnd('/').ToLowerInvariant()
    $wantNorm = (ConvertFrom-DockerDesktopPath $wantCtx).TrimEnd('/').ToLowerInvariant()
    if ($existingNorm -ne $wantNorm) {
      if ($containerRunning) {
        Write-Error "Container $containerName is running with a different /ctx mount. Stop the container first, then relaunch with the new -Ctx path."
        exit 1
      }
      Write-Host "Context mount changed (was '$existingCtx', now '$resolvedCtx'); recreating container."
      docker rm $containerName *> $null
      $containerExists = $false
    }
  }
  elseif ($existingCtx -ne "") {
    Write-Host "Note: container has /ctx mounted from a previous session ($existingCtx). Use -Volatile to start fresh or -Ctx to change it."
  }
}

if (-not $Volatile -and $containerExists) {
  if ($containerRunning) {
    if ($Detach) {
      Write-Host "Container $containerName is already running."
      exit 0
    }

    docker attach $containerName
    exit $LASTEXITCODE
  }

  if ($Detach) {
    docker start $containerName
    exit $LASTEXITCODE
  }

  docker start -ai $containerName
  exit $LASTEXITCODE
}

if ($Shell) {
  $command = @("zsh")
}
elseif ($Agent -eq "codex" -and $Exec -ne "") {
  $command = @("codex", "exec", $Exec)
}
elseif ($Agent -eq "claude") {
  $command = @("claude", "--dangerously-skip-permissions")
}
else {
  $command = @("codex", "--dangerously-bypass-approvals-and-sandbox")
}

$agentSeedArgs = @()
if (Test-Path $agentHostConfigDir) {
  if ($Agent -eq "claude") {
    $agentSeedArgs = @("-v", "${agentHostConfigDir}:/home/node/.claude-host:ro")
  }
  else {
    $agentSeedArgs = @("-v", "${agentHostConfigDir}:/home/node/.codex-host:ro")
  }
}

$gitConfigArgs = @()
if (Test-Path $gitConfigPath) {
  $gitConfigArgs = @("-v", "${gitConfigPath}:/home/node/.gitconfig-host:ro")
}

$ghConfigArgs = @()
if (Test-Path $ghHostConfigPath) {
  $ghConfigArgs = @("-v", "${ghHostConfigPath}:/home/node/.config/gh-host:ro")
}

$ctxArgs = @()
if ($resolvedCtx -ne "") {
  $ctxArgs = @("-v", "${resolvedCtx}:/ctx:ro")
}

docker compose @composeArgs run --rm --no-deps --user root --entrypoint /bin/sh `
  -v "${nodeModulesVolume}:/mnt/node_modules" `
  agent `
  -lc "mkdir -p /mnt/node_modules && chown node:node /mnt/node_modules"

if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

$runArgs = @()
if ($Detach) {
  $runArgs += "-d"
}
elseif ($Volatile -and -not $Persist) {
  $runArgs += "--rm"
}

$envArgs = @("--name", $containerName, "-e", "CONTAINER_NAME=$containerName")
if ($Agent -eq "codex") {
  $apiKey = if ($env:OPENAI_API_KEY) { $env:OPENAI_API_KEY } else { "" }
  $envArgs += @("-e", "OPENAI_API_KEY=$apiKey")
}

# Mount a per-project named volume over node_modules inside the bind mount.
# This shadows the host's node_modules with a Linux-native volume so that
# native binaries compiled for the container OS are never mixed with host
# binaries. The trade-off is that Docker may create an empty node_modules/
# directory on the host the first time (usually harmless since the project
# already has one), and the host's node_modules is inaccessible inside the
# container (intentional — use the volume copy for all in-container installs).
docker compose @composeArgs run @runArgs `
  @envArgs `
  @agentSeedArgs `
  @gitConfigArgs `
  @ghConfigArgs `
  @ctxArgs `
  -v "${nodeModulesVolume}:${workspaceMount}/node_modules" `
  -w $workspaceMount `
  agent `
  @command
