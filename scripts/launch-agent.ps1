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
  [string]$Exec = ""
)

$ErrorActionPreference = "Stop"

$resolvedProject = (Resolve-Path $ProjectPath).Path
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

$env:WORKSPACE_PATH = $resolvedProject
$env:PROJECT_NAME = $projectSlug

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

docker compose @composeArgs run @runArgs `
  @envArgs `
  @agentSeedArgs `
  @gitConfigArgs `
  @ghConfigArgs `
  -v "${nodeModulesVolume}:/workspace/node_modules" `
  agent `
  @command
