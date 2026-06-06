[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Prune,
  [switch]$AdoptAll
)

$ErrorActionPreference = "Stop"

# Refresh the image-baked agent skills onto the persistent config volumes.
#
# Skill text is baked into powbox-agent:latest at build time and seeded onto the
# claude-config / codex-config volumes the first time each skill folder is absent
# (no-clobber, see docker/shared/entrypoint-*-hook.sh). That no-clobber means a
# rebuilt image with updated skills does NOT overwrite the stale copies already
# on the volume. This command closes that gap: it runs a throwaway container that
# force-copies the freshly built skills over the volume copies, removing the old
# "enter a container, delete skills, exit, relaunch" dance.
#
# Each skill powbox places carries a hidden .powbox-seeded ownership marker, so
# this command can tell its own copies from skills you authored:
#   - marked skills are refreshed (and, with -Prune, removed when no longer baked)
#   - an UNMARKED folder whose name collides with a baked skill is a CONFLICT and
#     is never overwritten silently; resolve it with -AdoptAll (take the baked
#     version + track it) or by renaming your folder.
#
# Rebuild the image first (e.g. `cc <project> -Build`, `agent-update`, or
# `.\build.ps1 agent`) so the baked skills reflect your latest edits - this
# command seeds from whatever is currently in powbox-agent:latest.
#
# The config volumes are shared by every agent container, so this works whether
# or not any containers are running. A container that is already running picks up
# a refreshed skill the next time that skill is invoked; restart it for certainty.

$image = "powbox-agent:latest"
# $PSScriptRoot is the commands/ directory, where the worker lives alongside it.
$worker = Join-Path $PSScriptRoot "update-skills-incontainer.sh"

docker info *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Error "Docker daemon is not running. Start Docker Desktop (or the Docker daemon) and try again."
  exit 1
}

docker image inspect $image *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Error "Image '$image' not found. Build it first (e.g. '.\build.ps1 agent' or 'cc <project> -Build')."
  exit 1
}

if (-not (Test-Path -LiteralPath $worker)) {
  Write-Error "Worker script not found: $worker"
  exit 1
}

# Run the worker inside powbox-agent (the only image that carries the baked seed
# dirs and the shared seed-skills.sh) with both config volumes mounted. The
# worker is bind-mounted read-only and prints TAB-separated records on stdout,
# which we capture and parse; its warnings flow through to the console.
function Invoke-Worker {
  param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [bool]$Adopt = $false,
    [bool]$PruneOrphans = $false
  )
  $adoptVal = if ($Adopt) { "true" } else { "false" }
  $pruneVal = if ($PruneOrphans) { "true" } else { "false" }
  return docker run --rm `
    -v "claude-config:/home/node/.claude" `
    -v "codex-config:/home/node/.codex" `
    -v "${worker}:/usr/local/bin/update-skills-incontainer.sh:ro" `
    -e "POWBOX_SEED_MODE=$Mode" `
    -e "POWBOX_ADOPT_ALL=$adoptVal" `
    -e "POWBOX_PRUNE=$pruneVal" `
    --entrypoint bash `
    $image /usr/local/bin/update-skills-incontainer.sh
}

$interactive = -not [System.Console]::IsInputRedirected

# --- Classify: build the plan and collect conflicts / orphans -----------------
$records = Invoke-Worker -Mode "classify"
if ($LASTEXITCODE -ne 0) {
  Write-Error "Skill refresh failed during planning."
  exit 1
}

$nSeed = 0
$nRefresh = 0
$conflicts = @()
$orphans = @()
foreach ($line in $records) {
  if (-not $line) { continue }
  $f = $line -split "`t"
  switch ($f[0]) {
    'would-seed'    { $nSeed++ }
    'would-refresh' { $nRefresh++ }
    'conflict'      { $conflicts += "$($f[1])/$($f[2])" }
    'orphan'        { $orphans += "$($f[1])/$($f[2])" }
  }
}

Write-Host "Image: $image"
Write-Host "Plan: $nSeed to seed, $nRefresh to refresh."
if ($conflicts.Count -gt 0) {
  Write-Host "Conflicts (unmarked skills shadowing a baked skill - left untouched):"
  $conflicts | ForEach-Object { Write-Host "  - $_" }
}
if ($orphans.Count -gt 0) {
  Write-Host "Obsolete seeded skills (marked, no longer baked into the image):"
  $orphans | ForEach-Object { Write-Host "  - $_" }
}

# --- Decide adopt / prune (switches pre-approve; otherwise prompt on a TTY) ----
$doAdopt = [bool]$AdoptAll
$doPrune = [bool]$Prune
if ($conflicts.Count -gt 0 -and -not $doAdopt -and -not $DryRun -and $interactive) {
  Write-Host "Adopt the $($conflicts.Count) conflicting skill(s) above (overwrite with the baked version + track them)?"
  $reply = Read-Host "Answer N and rename any you want to keep as your own. [y/N]"
  if ($reply -match '^(y|yes)$') { $doAdopt = $true }
}
if ($orphans.Count -gt 0 -and -not $doPrune -and -not $DryRun -and $interactive) {
  $reply = Read-Host "Remove the $($orphans.Count) obsolete seeded skill(s) above? [y/N]"
  if ($reply -match '^(y|yes)$') { $doPrune = $true }
}

if ($DryRun) {
  Write-Host "(dry run - no changes made)"
  if ($conflicts.Count -gt 0) { Write-Host "Re-run with -AdoptAll to take the baked version of the conflicts." }
  if ($orphans.Count -gt 0) { Write-Host "Re-run with -Prune to remove the obsolete seeded skills." }
  exit 0
}

# --- Apply --------------------------------------------------------------------
$records = Invoke-Worker -Mode "apply" -Adopt $doAdopt -PruneOrphans $doPrune
$applyExit = $LASTEXITCODE
$applied = 0
$failed = 0
$keptConflicts = 0
$keptOrphans = 0
foreach ($line in $records) {
  if (-not $line) { continue }
  $f = $line -split "`t"
  $agent = $f[1]
  $name = $f[2]
  switch ($f[0]) {
    'seeded'    { Write-Host "[$agent] seeded skill: $name"; $applied++ }
    'refreshed' { Write-Host "[$agent] refreshed skill: $name"; $applied++ }
    'adopted'   { Write-Host "[$agent] adopted skill: $name"; $applied++ }
    'pruned'    { Write-Host "[$agent] pruned obsolete skill: $name"; $applied++ }
    'conflict'  { $keptConflicts++ }
    'orphan'    { $keptOrphans++ }
    'error'     { Write-Warning "[$agent] failed to update skill: $name"; $failed++ }
  }
}

Write-Host "$applied skill(s) updated."
if ($keptConflicts -gt 0) { Write-Host "$keptConflicts conflict(s) left untouched (run with -AdoptAll to take the baked version)." }
if ($keptOrphans -gt 0) { Write-Host "$keptOrphans obsolete seeded skill(s) kept (run with -Prune to remove)." }
if ($failed -gt 0 -or $applyExit -ne 0) {
  Write-Error "Skill refresh completed with $failed failure(s)."
  exit 1
}
