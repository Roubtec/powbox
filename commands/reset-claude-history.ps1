[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param()

$ErrorActionPreference = "Stop"

# Prune per-project session history from the shared claude-config volume,
# preserving settings.json, credentials, and any other top-level config files.
# Runs a throwaway container to access the volume's contents, since named
# volumes on Docker Desktop (Windows) are not directly reachable from the
# host filesystem.
#
# Prefers powbox-agent-base:latest (guaranteed present whenever claude-config
# has content) so the helper stays offline-friendly and inherits whatever
# base image docker/base/Dockerfile declares. Falls back to node:24-slim if
# the base image has not been built yet.

$volumeName = "claude-config"

docker volume inspect $volumeName *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Volume '$volumeName' does not exist. Nothing to prune." -ForegroundColor Yellow
  exit 0
}

# Running containers with the volume mounted would race against the prune.
# Stopped containers are fine — they do not hold the volume open.
$runningContainers = docker ps --filter "volume=$volumeName" --format "{{.Names}}"
if ($LASTEXITCODE -ne 0) {
  Write-Error "Failed to query running containers. Is Docker running?"
  exit 1
}
if ($runningContainers) {
  Write-Error "Refusing to prune: the following running container(s) have '$volumeName' mounted. Stop them first.`n$($runningContainers -join "`n")"
  exit 1
}

docker image inspect powbox-agent-base:latest *> $null
if ($LASTEXITCODE -eq 0) {
  $helperImage = "powbox-agent-base:latest"
} else {
  $helperImage = "node:24-slim"
  Write-Host "powbox-agent-base:latest not found; falling back to $helperImage." -ForegroundColor Yellow
}

Write-Host "Project histories currently in '$volumeName':" -ForegroundColor Cyan
docker run --rm -v "${volumeName}:/data" $helperImage sh -c 'if [ -d /data/projects ]; then ls -1 /data/projects 2>/dev/null | sed "s/^/  /"; else echo "  (none)"; fi; echo; echo "Other pruneable state:"; for d in todos shell-snapshots; do if [ -d "/data/$d" ]; then echo "  $d/"; fi; done'
if ($LASTEXITCODE -ne 0) {
  Write-Error "Failed to inspect volume contents."
  exit 1
}

$target = "$volumeName (projects, todos, shell-snapshots)"
$action = "Delete per-project history, todos, and shell snapshots (credentials and settings preserved)"

if (-not $PSCmdlet.ShouldProcess($target, $action)) {
  exit 0
}

docker run --rm -v "${volumeName}:/data" $helperImage sh -c 'rm -rf /data/projects /data/todos /data/shell-snapshots'
if ($LASTEXITCODE -ne 0) {
  Write-Error "Prune failed."
  exit 1
}

Write-Host "Done. Credentials and settings preserved." -ForegroundColor Green
