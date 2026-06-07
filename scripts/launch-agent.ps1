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
  [switch]$Continue,
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
# Per-project worktrees volume. Holds the git worktrees AND the pnpm store under
# ONE mount so pnpm hardlinks package files into per-worktree node_modules
# instead of copying them. ext4, persistent, container-local, and shared between
# this project's Claude and Codex containers (project-keyed, like the nm volume).
$worktreesVolume = "agent-wt-$projectSlug"
# pnpm store path inside the worktrees volume (same mount as .worktrees/<task>).
$worktreesStoreDir = "/workspace/$projectSlug/.worktrees/.pnpm-store"
# Per-container rootless Podman storage (images + named volumes) so an in-sandbox
# agent's containers and their data persist across restarts. Keyed by the OUTER
# container (agent + project), NOT just the project: a project's Claude and Codex
# containers can run concurrently, and two Podman instances with separate
# runroots/namespaces sharing one graphroot corrupt each other's metadata and
# lifecycle state. A shared image cache is a separate concern (additionalimagestores).
$podmanVolume = "agent-podman-$containerName"

$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$composeShared = Join-Path $rootDir "compose.shared.yml"
$composeOverlay = Join-Path $rootDir "compose.agent.yml"
$composeArgs = @("-p", "powbox", "-f", $composeShared, "-f", $composeOverlay)

# Ensure named volumes exist (compose won't auto-create external volumes). Both
# config volumes are always created/mounted so the non-primary agent can be
# spun up in-container with its own persistent login and skills.
$sharedVolumes = @("agent-gh-config", "agent-zsh-history", "claude-config", "codex-config")
foreach ($vol in $sharedVolumes) {
  docker volume inspect $vol *> $null
  if ($LASTEXITCODE -ne 0) {
    docker volume create $vol *> $null
    if ($LASTEXITCODE -ne 0) {
      Write-Error "Failed to create required Docker volume '$vol'. Ensure Docker is running and you have permission to access the Docker daemon."
      exit 1
    }
  }
}

$env:WORKSPACE_PATH = $resolvedProject
$env:PROJECT_NAME = $projectSlug
$workspaceMount = "/workspace/$projectSlug"

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
  & (Join-Path $rootDir "scripts/build-image.ps1") -Target agent
}

if ($Resume) {
  if (-not $containerExists) {
    Write-Error "No persisted container named $containerName was found. Start it once normally, or with -Persist if you want to be explicit."
    exit 1
  }
  if ($Ctx -ne "") {
    Write-Host "Note: -Ctx is ignored with -Resume; container will resume with its existing mounts. Omit -Resume to apply ctx changes." -ForegroundColor Yellow
  }
  if ($Continue) {
    Write-Host "Note: -Continue is ignored with -Resume; container will restart with the CMD it was originally created with. Omit -Resume to apply a continue-flag change." -ForegroundColor Yellow
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
      if ($LASTEXITCODE -ne 0) {
        docker container inspect $containerName *> $null
        if ($LASTEXITCODE -eq 0) {
          Write-Error "Failed to remove container $containerName after detecting a /ctx mount change."
          exit 1
        }
      }
      $containerExists = $false
    }
  }
  elseif ($existingCtx -ne "") {
    Write-Host "Note: container has /ctx mounted from a previous session ($existingCtx). Use -Volatile to start fresh or -Ctx to change it."
  }
}

# Detect whether the -Continue flag state differs from what the container was created with.
# The CMD is frozen at container creation, so a flag change only takes effect after recreation.
# Missing label on an existing container predates this flag — treat it as "true" so the old
# auto-resume default remains in effect for reused containers until the user explicitly opts out,
# at which point this branch recycles the container to honour the new intent.
if (-not $Volatile -and $containerExists) {
  $existingContinue = (docker inspect --format '{{with .Config.Labels}}{{with (index . "powbox.continue")}}{{.}}{{end}}{{end}}' $containerName 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($existingContinue)) {
    $existingContinue = "true"
  }
  $existingContinue = $existingContinue.Trim()
  $wantContinue = if ($Continue) { "true" } else { "false" }
  if ($existingContinue -ne $wantContinue) {
    if ($containerRunning) {
      Write-Host "Note: container $containerName is running; -Continue=$wantContinue is ignored because the existing process was started with -Continue=$existingContinue. Attaching to the running process. Stop it and relaunch to apply the flag change." -ForegroundColor Yellow
    }
    else {
      Write-Host "Continue flag changed (was '$existingContinue', now '$wantContinue'); recreating container."
      docker rm $containerName *> $null
      if ($LASTEXITCODE -ne 0) {
        docker container inspect $containerName *> $null
        if ($LASTEXITCODE -eq 0) {
          Write-Error "Failed to remove container $containerName after detecting a -Continue flag change."
          exit 1
        }
      }
      $containerExists = $false
    }
  }
}

# Detect whether the existing container predates the per-project .worktrees volume
# (and its co-located pnpm store). Such a container was created before this change,
# so it still has a tmpfs .worktrees shadow and points pnpm at the old shared store —
# it never gets the hardlinking store-dir, even after the image is rebuilt. Recreate a
# stopped container that lacks the agent-wt-* mount so the new mount + PNPM_STORE_DIR
# take effect; warn (don't disrupt) if it is currently running.
if (-not $Volatile -and $containerExists) {
  $hasWtMount = (docker inspect --format "{{range .Mounts}}{{if eq .Destination `"$workspaceMount/.worktrees`"}}yes{{end}}{{end}}" $containerName 2>$null)
  if ($LASTEXITCODE -ne 0) { $hasWtMount = "" }
  if ([string]::IsNullOrWhiteSpace($hasWtMount)) {
    if ($containerRunning) {
      Write-Host "Note: container $containerName predates the per-project .worktrees volume; it is still using a tmpfs .worktrees and the old pnpm store, so worktree installs won't hardlink. Stop it and relaunch (or use -Volatile) to enable hardlinked worktree node_modules." -ForegroundColor Yellow
    }
    else {
      Write-Host "Container $containerName predates the per-project .worktrees volume; recreating it so worktree node_modules hardlink from the co-located pnpm store."
      docker rm $containerName *> $null
      if ($LASTEXITCODE -ne 0) {
        docker container inspect $containerName *> $null
        if ($LASTEXITCODE -eq 0) {
          Write-Error "Failed to remove container $containerName after detecting a missing .worktrees volume mount."
          exit 1
        }
      }
      $containerExists = $false
    }
  }
}

# Detect whether the existing container predates the per-container Podman storage
# volume. Such a container was created before rootless-Podman support, so its
# /home/node/.local/share/containers is ephemeral (no agent-podman-* mount) and
# it was launched without /dev/fuse — pulled images and podman volumes would not
# persist, even after the image is rebuilt. Recreate a stopped container that
# lacks the mount so the new volume + device attach; warn (don't disrupt) if it
# is currently running.
if (-not $Volatile -and $containerExists) {
  $hasPodmanMount = (docker inspect --format "{{range .Mounts}}{{if eq .Destination `"/home/node/.local/share/containers`"}}yes{{end}}{{end}}" $containerName 2>$null)
  if ($LASTEXITCODE -ne 0) { $hasPodmanMount = "" }
  if ([string]::IsNullOrWhiteSpace($hasPodmanMount)) {
    if ($containerRunning) {
      Write-Host "Note: container $containerName predates the per-container Podman storage volume; nested-container images and volumes won't persist and /dev/fuse isn't attached. Stop it and relaunch (or use -Volatile) to enable persistent rootless Podman storage." -ForegroundColor Yellow
    }
    else {
      Write-Host "Container $containerName predates the per-container Podman storage volume; recreating it so rootless Podman images and volumes persist."
      docker rm $containerName *> $null
      if ($LASTEXITCODE -ne 0) {
        docker container inspect $containerName *> $null
        if ($LASTEXITCODE -eq 0) {
          Write-Error "Failed to remove container $containerName after detecting a missing Podman storage volume mount."
          exit 1
        }
      }
      $containerExists = $false
    }
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
  if ($Continue) {
    Write-Host "Note: -Continue has no effect with -Shell; this launch opens a plain zsh." -ForegroundColor Yellow
  }
}
elseif ($Agent -eq "codex" -and $Exec -ne "") {
  $command = @("codex", "exec", $Exec)
  if ($Continue) {
    Write-Host "Note: -Continue has no effect with -Exec; codex exec always starts a fresh non-interactive session." -ForegroundColor Yellow
  }
}
elseif ($Agent -eq "claude") {
  if ($Continue) {
    # Pre-flight check: only pass --continue if a session history exists for this
    # working directory. Claude stores sessions in ~/.claude/projects/<slug>/,
    # where <slug> is the cwd with every non-alphanumeric, non-dash character
    # replaced by '-' (verified empirically against '/', '.', '_', spaces, '+',
    # and uppercase; case is preserved and adjacent dashes are not collapsed).
    # Passing --continue when no session exists makes claude print "No
    # conversation found" and exit instead of falling back to a fresh session.
    # The check runs inside the container where claude-config is mounted.
    $continueCheck = 'slug=$(printf %s "$PWD" | sed "s/[^a-zA-Z0-9-]/-/g"); if ls "$HOME/.claude/projects/$slug"/*.jsonl >/dev/null 2>&1; then exec claude --dangerously-skip-permissions --continue; else exec claude --dangerously-skip-permissions; fi'
    $command = @("sh", "-c", $continueCheck)
  }
  else {
    $command = @("claude", "--dangerously-skip-permissions")
  }
}
else {
  if ($Continue) {
    # Codex resume --last already filters to the current cwd and falls through to
    # a fresh interactive session when nothing resumable exists there.
    $command = @("codex", "resume", "--last", "--dangerously-bypass-approvals-and-sandbox")
  }
  else {
    $command = @("codex", "--dangerously-bypass-approvals-and-sandbox")
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
  -v "${worktreesVolume}:/mnt/worktrees" `
  -v "${podmanVolume}:/mnt/containers" `
  agent `
  -lc "mkdir -p /mnt/node_modules /mnt/worktrees /mnt/containers && chown node:node /mnt/node_modules /mnt/worktrees /mnt/containers"

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

# Pass /dev/fuse through for rootless Podman's fuse-overlayfs storage driver.
# Auto-detect on the host; POWBOX_FUSE=on|off overrides. In `auto` (and `off`)
# this is best-effort: a missing device just drops the container to the slower vfs
# driver (see entrypoint-core.sh), never aborting the launch. `on` forces the
# device, so if the Docker host cannot expose /dev/fuse the run hard-fails. On a
# Windows host shell /dev/fuse does not exist, so `auto` resolves to off there;
# force it with POWBOX_FUSE=on only when the Docker Desktop VM exposes the device.
switch ($env:POWBOX_FUSE) {
  "on" { $runArgs += @("--device", "/dev/fuse") }
  "off" { }
  default {
    if (Test-Path "/dev/fuse") { $runArgs += @("--device", "/dev/fuse") }
  }
}

$continueLabel = if ($Continue) { "true" } else { "false" }
# PRIMARY_AGENT selects which agent the unified image runs and seeds as primary.
# Both API keys flow through via compose.agent.yml so a delegated peer agent can
# authenticate too.
$envArgs = @("--name", $containerName, "--label", "powbox.continue=$continueLabel", "-e", "CONTAINER_NAME=$containerName", "-e", "PRIMARY_AGENT=$Agent", "-e", "PNPM_STORE_DIR=$worktreesStoreDir")

# Mount per-project named volumes over node_modules and .worktrees inside the
# bind mount. Both shadow the host paths with Linux-native ext4 volumes so that
# native binaries compiled for the container OS are never mixed with host
# binaries. The .worktrees volume additionally co-locates the pnpm store
# (PNPM_STORE_DIR) with each worktree's node_modules under one mount, so
# per-worktree `pnpm install` hardlinks from the store instead of copying.
# The trade-off is that Docker may create empty node_modules/ and .worktrees/
# directories on the host the first time (harmless; .worktrees is gitignored in
# worktree-enabled repos), and the host's copies are inaccessible inside the
# container (intentional — use the volume copies for all in-container installs).
docker compose @composeArgs run @runArgs `
  @envArgs `
  @gitConfigArgs `
  @ghConfigArgs `
  @ctxArgs `
  -v "${nodeModulesVolume}:${workspaceMount}/node_modules" `
  -v "${worktreesVolume}:${workspaceMount}/.worktrees" `
  -v "${podmanVolume}:/home/node/.local/share/containers" `
  -w $workspaceMount `
  agent `
  @command
