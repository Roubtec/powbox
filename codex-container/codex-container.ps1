param(
  [string]$ProjectPath = ".",
  [switch]$Build,
  [switch]$Detach,
  [switch]$Shell,
  [switch]$Persist,
  [switch]$Resume,
  [switch]$Volatile,
  [string]$Exec = ""
)

$resolvedProject = (Resolve-Path $ProjectPath).Path
$projectName = Split-Path $resolvedProject -Leaf
$projectHash = [System.BitConverter]::ToString(
  [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [System.Text.Encoding]::UTF8.GetBytes($resolvedProject.ToLowerInvariant())
  )
).Replace("-", "").Substring(0, 12).ToLowerInvariant()

$safeProject = (($projectName.ToLowerInvariant() -replace '[^a-z0-9_.-]', '-') -replace '-+', '-').Trim('-')
$containerName = "codex-$safeProject-$projectHash"
$nodeModulesVolume = "agent-nm-$safeProject-$projectHash"

$env:WORKSPACE_PATH = $resolvedProject
$env:CODEX_HOST_CONFIG_DIR = Join-Path $env:USERPROFILE ".codex"
$ghHostConfigPath = "$env:APPDATA\GitHub CLI"
$gitConfigPath = Join-Path $env:USERPROFILE ".gitconfig"
$env:PROJECT_NAME = "$safeProject-$projectHash"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$composeFile = Join-Path $scriptDir "docker-compose.yml"

$containerExists = $false
$containerRunning = $false

docker container inspect $containerName *> $null
if ($LASTEXITCODE -eq 0) {
  $containerExists = $true
  $runningState = docker container inspect --format '{{.State.Running}}' $containerName 2>$null
  $containerRunning = ($LASTEXITCODE -eq 0 -and $runningState.Trim() -eq 'true')
}

if ($Build) {
  docker compose -f $composeFile build
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
} elseif ($Exec -ne "") {
  $command = @("codex", "exec", $Exec)
} else {
  $command = @("codex", "--dangerously-bypass-approvals-and-sandbox")
}

$codexSeedArgs = @()
if (Test-Path $env:CODEX_HOST_CONFIG_DIR) {
  $codexSeedArgs = @("-v", "$($env:CODEX_HOST_CONFIG_DIR):/home/node/.codex-host:ro")
}

$gitConfigArgs = @()
if (Test-Path $gitConfigPath) {
  $gitConfigArgs = @("-v", "${gitConfigPath}:/home/node/.gitconfig-host:ro")
}

$ghConfigArgs = @()
if (Test-Path $ghHostConfigPath) {
  $ghConfigArgs = @("-v", "${ghHostConfigPath}:/home/node/.config/gh-host:ro")
}

$composeArgs = @("run")

if ($Detach) {
  $composeArgs += "-d"
}
elseif ($Volatile -and -not $Persist) {
  $composeArgs += "--rm"
}

docker compose -f $composeFile run --rm --no-deps --user root --entrypoint /bin/sh `
  -v "${nodeModulesVolume}:/mnt/node_modules" codex `
  -lc "mkdir -p /mnt/node_modules && chown node:node /mnt/node_modules"

if ($LASTEXITCODE -ne 0) {
  exit $LASTEXITCODE
}

$apiKey = if ($env:OPENAI_API_KEY) { $env:OPENAI_API_KEY } else { "" }

$composeArgs += @(
  "--name", $containerName,
  "-e", "CONTAINER_NAME=$containerName",
  "-e", "OPENAI_API_KEY=$apiKey"
)

$composeArgs += $codexSeedArgs
$composeArgs += $gitConfigArgs
$composeArgs += $ghConfigArgs

$composeArgs += @(
  "-v", "${nodeModulesVolume}:/workspace/node_modules",
  "codex"
)

$composeArgs += $command

docker compose -f $composeFile @composeArgs
