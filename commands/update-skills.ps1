[CmdletBinding()]
param(
  [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Refresh the image-baked agent skills onto the persistent config volumes.
#
# Skill text is baked into powbox-agent:latest at build time and seeded onto the
# claude-config / codex-config volumes the first time each skill folder is absent
# (no-clobber, see docker/shared/entrypoint-*-hook.sh). That no-clobber means a
# rebuilt image with updated skills does NOT overwrite the stale copies already
# on the volume. This command closes that gap in one go: it runs a throwaway
# container that copies the freshly built skills over the volume copies, removing
# the old "enter a container, delete skills, exit, relaunch to re-seed" dance.
#
# Rebuild the image first (e.g. `cc <project> -Build`, `agent-update`, or
# `.\build.ps1 agent`) so the baked skills reflect your latest edits — this
# command seeds from whatever is currently in powbox-agent:latest.
#
# The config volumes are shared by every agent container, so this works whether
# or not any containers are running. A container that is already running picks up
# a refreshed skill the next time that skill is invoked; restart it for certainty.

$image = "powbox-agent:latest"
# $PSScriptRoot is the commands/ directory, where the worker lives alongside it.
$worker = Join-Path $PSScriptRoot "update-skills-incontainer.sh"

docker image inspect $image *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Error "Image '$image' not found. Build it first (e.g. '.\build.ps1 agent' or 'cc <project> -Build')."
  exit 1
}

if (-not (Test-Path -LiteralPath $worker)) {
  Write-Error "Worker script not found: $worker"
  exit 1
}

$dryRunValue = if ($DryRun) { "true" } else { "false" }

# Run the worker inside powbox-agent (the only image that carries the baked seed
# dirs) with both config volumes mounted. --entrypoint bash bypasses the agent
# entrypoint; the worker is bind-mounted read-only and executed by path.
docker run --rm `
  -v "claude-config:/home/node/.claude" `
  -v "codex-config:/home/node/.codex" `
  -v "${worker}:/usr/local/bin/update-skills-incontainer.sh:ro" `
  -e "POWBOX_DRY_RUN=$dryRunValue" `
  --entrypoint bash `
  $image /usr/local/bin/update-skills-incontainer.sh
if ($LASTEXITCODE -ne 0) {
  Write-Error "Skill refresh failed."
  exit 1
}
