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
$composeFuse = Join-Path $rootDir "compose.fuse.yml"
$composeNetdev = Join-Path $rootDir "compose.netdev.yml"
$composeArgs = @("-p", "powbox", "-f", $composeShared, "-f", $composeOverlay)

# Ensure named volumes exist (compose won't auto-create external volumes). Both
# config volumes are always created/mounted so the non-primary agent can be
# spun up in-container with its own persistent login and skills.
# agent-podman-imagestore is the single GLOBAL read-only image cache shared by
# every container across all projects (consumed via Podman additionalimagestores).
# It is infra, like the config volumes — created here, never per-container.
$sharedVolumes = @("agent-gh-config", "agent-zsh-history", "claude-config", "codex-config", "agent-podman-imagestore")
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

# Resolve which host devices rootless Podman will receive this launch into a
# normalised set string ("fuse,tun" / "fuse" / "tun" / "none"). The device list is
# frozen at container creation — `docker start` can't add /dev/fuse or /dev/net/tun
# to an existing container — so this is recorded as a label and a change recreates a
# stopped container (mirrors the /ctx and -Continue handling). 'auto' resolves against
# the launcher host's /dev here (on a Windows host shell /dev/* is absent, so auto ->
# none; force with POWBOX_PODMAN=on for the Docker Desktop VM); 'on' forces both
# devices, 'off' neither. The compose-file selection below derives from the same
# value, so the label and the actual attach never disagree.
$podmanRequest = if ($env:POWBOX_PODMAN) { $env:POWBOX_PODMAN } elseif ($env:POWBOX_FUSE) { $env:POWBOX_FUSE } else { "auto" }
$podmanDevices = switch ($podmanRequest) {
  "on" { "fuse,tun" }
  "off" { "none" }
  default {
    $devs = @()
    if (Test-Path "/dev/fuse") { $devs += "fuse" }
    if (Test-Path "/dev/net/tun") { $devs += "tun" }
    if ($devs.Count -gt 0) { ($devs -join ",") } else { "none" }
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
      Write-Host "Note: container $containerName predates the per-container Podman storage volume; nested-container images and volumes won't persist and the podman devices (/dev/fuse, /dev/net/tun) aren't attached. Stop it and relaunch (or use -Volatile) to enable persistent rootless Podman storage." -ForegroundColor Yellow
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

# Detect whether the existing container was created with a different rootless-Podman
# device set than this launch resolves (POWBOX_PODMAN changed, or the host's /dev
# visibility changed under `auto`). The device list is frozen at creation, so a
# stopped container first created with POWBOX_PODMAN=off — or under `auto` on a host
# that couldn't see the devices — can't gain /dev/fuse or /dev/net/tun on `docker
# start`: nested Podman would stay on vfs with no default networking. Recreate a
# stopped mismatch so the new device set attaches; warn (don't disrupt) a running
# one. A container with no recorded label predates this check — leave it alone, since
# we can't know what it was created with and the storage-mount check above already
# recreates truly pre-Podman containers.
if (-not $Volatile -and $containerExists) {
  $existingPodmanDevices = (docker inspect --format '{{with .Config.Labels}}{{with (index . "powbox.podman-devices")}}{{.}}{{end}}{{end}}' $containerName 2>$null)
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($existingPodmanDevices)) {
    $existingPodmanDevices = ""
  }
  else {
    $existingPodmanDevices = $existingPodmanDevices.Trim()
  }
  if ($existingPodmanDevices -ne "" -and $existingPodmanDevices -ne $podmanDevices) {
    if ($containerRunning) {
      Write-Host "Note: container $containerName is running with Podman devices '$existingPodmanDevices'; this launch resolves to '$podmanDevices'. The device set is fixed at container creation — stop it and relaunch (or use -Volatile) to apply the change." -ForegroundColor Yellow
    }
    else {
      Write-Host "Podman device set changed (was '$existingPodmanDevices', now '$podmanDevices'); recreating container."
      docker rm $containerName *> $null
      if ($LASTEXITCODE -ne 0) {
        docker container inspect $containerName *> $null
        if ($LASTEXITCODE -eq 0) {
          Write-Error "Failed to remove container $containerName after detecting a Podman device set change."
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
  -v "agent-podman-imagestore:/mnt/podman-imagestore" `
  agent `
  -lc "mkdir -p /mnt/node_modules /mnt/worktrees /mnt/containers /mnt/podman-imagestore && chown node:node /mnt/node_modules /mnt/worktrees /mnt/containers /mnt/podman-imagestore"

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

# Pass the host devices rootless Podman needs through to the agent, each in its
# own compose overlay (`docker compose run` has no --device flag, only `docker
# run` does, so a device must be declared in a compose file added to the -f chain):
#   compose.fuse.yml   -> /dev/fuse    (fuse-overlayfs overlay storage driver;
#                                       absence just falls back to the vfs driver)
#   compose.netdev.yml -> /dev/net/tun (slirp4netns/pasta nested networking;
#                                       absence breaks every default `podman run`)
# POWBOX_PODMAN gates both (POWBOX_FUSE is the deprecated alias):
#   on   -> force both. Use on Docker Desktop / WSL2, where the devices live in the
#          Docker VM and the launcher's host shell cannot see them to auto-detect;
#          if the Docker host cannot expose a forced device the run hard-fails.
#   off  -> neither (Podman still runs: vfs storage, networking only via
#          --network=host/none).
#   auto -> attach each device independently when the host shell can see it. On a
#          Windows host shell /dev/* does not exist, so `auto` resolves to off
#          there; force with POWBOX_PODMAN=on when the Docker Desktop VM has them.
#          The two are detected separately so a host exposing /dev/net/tun but not
#          /dev/fuse still gets networking on vfs.
if (-not $env:POWBOX_PODMAN -and $env:POWBOX_FUSE) {
  Write-Host "Note: POWBOX_FUSE is deprecated; use POWBOX_PODMAN (it now gates both /dev/fuse and /dev/net/tun)." -ForegroundColor Yellow
}
# Attach each compose overlay from the already-resolved $podmanDevices set so the
# devices actually passed match the powbox.podman-devices label recorded below.
switch -Wildcard (",$podmanDevices,") {
  "*,fuse,*" { $composeArgs += @("-f", $composeFuse) }
}
switch -Wildcard (",$podmanDevices,") {
  "*,tun,*" { $composeArgs += @("-f", $composeNetdev) }
}

$continueLabel = if ($Continue) { "true" } else { "false" }

# Seed the GLOBAL shared image store from a dedicated, short-lived, DETACHED
# writer — the ONLY container that mounts agent-podman-imagestore read-write. The
# agent container below mounts the same volume read-only, so a runaway process in
# one project can't poison the cache every other project resolves images from.
# Detached so the launch never blocks on pulls; idempotent and quick once
# populated (seed-image-store.sh skips images already present, and its flock
# serializes concurrent writers). Only meaningful on the overlay path — an
# additionalimagestores entry must match the consumer's driver, and consumers
# only enable overlay when /dev/fuse is present — so gate it on the resolved fuse
# device. Best-effort: a writer that can't start must never abort the agent launch.
if (",$podmanDevices," -like "*,fuse,*") {
  try {
    # Go straight to entrypoint-core.sh (firewall + XDG + the writer-role Podman
    # setup) instead of the default entrypoint-agent.sh, so the writer skips the
    # per-agent skill/config seeding and stays lean — it only needs egress and a
    # Podman that can pull. AGENT_CONFIG_DIR is required by core but unused here, so
    # point it at a throwaway path; AGENT_SETUP_HOOK is cleared so no agent hook runs.
    docker compose @composeArgs run --rm -d --no-deps `
      --entrypoint /usr/local/bin/entrypoint-core.sh `
      -e POWBOX_IMAGE_STORE_ROLE=writer `
      -e AGENT_CONFIG_DIR=/tmp/powbox-imgstore-writer `
      -e AGENT_SETUP_HOOK= `
      -v "agent-podman-imagestore:/mnt/podman-imagestore" `
      agent `
      seed-image-store.sh seed *> $null
  }
  catch {
    # Best-effort cache seeding must never abort the agent launch.
  }
  $global:LASTEXITCODE = 0
}

# PRIMARY_AGENT selects which agent the unified image runs and seeds as primary.
# Both API keys flow through via compose.agent.yml so a delegated peer agent can
# authenticate too.
$envArgs = @("--name", $containerName, "--label", "powbox.continue=$continueLabel", "--label", "powbox.podman-devices=$podmanDevices", "-e", "CONTAINER_NAME=$containerName", "-e", "PRIMARY_AGENT=$Agent", "-e", "PNPM_STORE_DIR=$worktreesStoreDir")

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
  -v "agent-podman-imagestore:/mnt/podman-imagestore:ro" `
  -w $workspaceMount `
  agent `
  @command
