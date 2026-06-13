param(
  [string]$Image = "powbox-agent:latest"
)

# Smoke-test the self-hosted ("-Isolated") launch mode. Two stages:
#
#   Stage A - launcher identity. Drives scripts/launch-agent.ps1 with the
#   POWBOX_PRINT_IDENTITY hook (which resolves names and exits before any Docker
#   call), so it runs ANYWHERE - no image, no daemon, no network. It asserts the
#   naming contract: dir-mounted is byte-for-byte unchanged; a -Name is
#   deterministic (so a relaunch re-attaches the same workspace path -> same Claude
#   session slug); an unnamed launch is fresh each time; the repo-slug strips .git
#   and lowercases; and the per-mode volume set is correct.
#
#   Stage B - entrypoint clone behavior, exercised against the agent IMAGE
#   (default powbox-agent:latest). It runs the baked seed-workspace.sh directly
#   (--entrypoint, bypassing the firewall/podman setup) to check clone-on-first-run,
#   reuse-skips-clone, -Reclone, and the loud unauthenticated-clone announcement,
#   plus the single-mount hardlink invariant the one-volume layout relies on. It
#   needs the image and network, so it SELF-SKIPS when the image is absent rather
#   than failing. Skip it explicitly with POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE=1.

$ErrorActionPreference = "Stop"

$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$launcher = Join-Path $rootDir "scripts/launch-agent.ps1"
# A tiny, stable public repo - no gh auth needed to clone it.
$publicRepo = if ($env:POWBOX_SMOKE_PUBLIC_REPO) { $env:POWBOX_SMOKE_PUBLIC_REPO } else { "https://github.com/octocat/Hello-World.git" }

$script:pass = 0
function Fail([string]$m) { Write-Error "FAIL: $m"; exit 1 }
function Ok([string]$m) { $script:pass++; Write-Host "  ok: $m" }

# Run the launcher with the print-identity hook (as a child process so its `exit`
# does not terminate this script) and return a hashtable of KEY=VALUE fields.
function Get-Identity {
  param([string[]]$LauncherArgs)
  $env:POWBOX_PRINT_IDENTITY = "1"
  try {
    $out = & pwsh -NoProfile -File $launcher @LauncherArgs 2>$null
  }
  finally {
    Remove-Item Env:POWBOX_PRINT_IDENTITY -ErrorAction SilentlyContinue
  }
  $h = @{}
  foreach ($line in $out) {
    $idx = $line.IndexOf('=')
    if ($idx -ge 0) { $h[$line.Substring(0, $idx)] = $line.Substring($idx + 1) }
  }
  return $h
}

Write-Host "Self-hosted smoke test (launcher: $launcher)"
Write-Host "Stage A - launcher identity (no image/daemon needed)"

# --- dir-mounted is unchanged: hash == SHA256(canonical path)[:12] ------------
$dm = Get-Identity @("-Agent", "claude", "-ProjectPath", $rootDir)
if ($dm["mode"] -ne "dir-mounted") { Fail "default mode is not dir-mounted" }
$sha = [System.BitConverter]::ToString(
  [System.Security.Cryptography.SHA256]::Create().ComputeHash(
    [System.Text.Encoding]::UTF8.GetBytes($rootDir.ToLowerInvariant())
  )
).Replace("-", "").Substring(0, 12).ToLowerInvariant()
if (-not $dm["CONTAINER_NAME"].EndsWith("-$sha")) { Fail "dir-mounted hash changed (want suffix -$sha): $($dm["CONTAINER_NAME"])" }
if ([string]::IsNullOrEmpty($dm["NM_VOLUME"]) -or [string]::IsNullOrEmpty($dm["WT_VOLUME"])) { Fail "dir-mounted is missing nm/wt volumes" }
if (-not [string]::IsNullOrEmpty($dm["WS_VOLUME"])) { Fail "dir-mounted must not have a WS_VOLUME" }
Ok "dir-mounted hash matches SHA256(path)[:12], has nm/wt and no ws volume"

# --- named -> deterministic ---------------------------------------------------
$n1 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/Repo.git", "-Name", "foo")
$n2 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/Repo.git", "-Name", "foo")
if ($n1["mode"] -ne "isolated") { Fail "-Isolated did not select isolated mode" }
if ($n1["CONTAINER_NAME"] -ne $n2["CONTAINER_NAME"]) { Fail "named instance is not deterministic across launches" }
if ($n1["WORKSPACE_MOUNT"] -ne $n2["WORKSPACE_MOUNT"]) { Fail "named instance workspace path (-> Claude session slug) is not stable" }
Ok "named instance is deterministic (same workspace path / session slug on relaunch)"

# --- named identity is PER-REPO: same -Name on a different repo must not collide
# Two remotes that share a basename (owner1/app, owner2/app) launched with the same
# -Name must resolve to DISTINCT identities; otherwise the second launch would
# attach to (or -Reclone wipe) the first repo's container/workspace.
$p1 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner1/app", "-Name", "shared")
$p2 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner2/app", "-Name", "shared")
if ($p1["CONTAINER_NAME"] -eq $p2["CONTAINER_NAME"]) { Fail "two repos sharing a basename collide under the same -Name" }
if ($p1["WORKSPACE_MOUNT"] -eq $p2["WORKSPACE_MOUNT"]) { Fail "two repos sharing a basename share a workspace path under the same -Name" }
Ok "named identity is per-repo (owner1/app vs owner2/app, same -Name, differ)"

# ... while the SAME repo expressed different ways (slug, full https URL, or an
# uppercase .GIT extension) under the same -Name stays stable, so reuse is not
# broken by spec form (the .GIT case also guards .sh/.ps1 strip-case parity).
$s1 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/app", "-Name", "stable")
$s2 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "https://github.com/owner/app.git", "-Name", "stable")
$s3 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/app.GIT", "-Name", "stable")
if ($s1["CONTAINER_NAME"] -ne $s2["CONTAINER_NAME"]) { Fail "same repo via slug vs https URL produced different identities under the same -Name" }
if ($s1["CONTAINER_NAME"] -ne $s3["CONTAINER_NAME"]) { Fail "uppercase .GIT extension produced a different identity (case-sensitive .git strip)" }
Ok "named identity is spec-form stable (slug == https URL == owner/app.GIT)"

if (-not $n1["PROJECT_NAME"].StartsWith("repo-")) { Fail "repo-slug derivation wrong: $($n1["PROJECT_NAME"])" }
Ok "repo-slug strips .git and lowercases (Repo.git -> repo)"
if ($n1["WS_VOLUME"] -ne "agent-ws-$($n1["CONTAINER_NAME"])") { Fail "WS_VOLUME is not agent-ws-<container>" }
if (-not [string]::IsNullOrEmpty($n1["NM_VOLUME"]) -or -not [string]::IsNullOrEmpty($n1["WT_VOLUME"])) { Fail "isolated mode must not create nm/wt volumes" }
Ok "isolated has agent-ws-<container> and no nm/wt volumes"

# --- unnamed -> fresh every launch --------------------------------------------
$u1 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/repo")
$u2 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/repo")
if ($u1["CONTAINER_NAME"] -eq $u2["CONTAINER_NAME"]) { Fail "unnamed instances collided (should be fresh each launch)" }
Ok "unnamed instances are fresh each launch"

# --- self-hosted-only flags require -Isolated ---------------------------------
$env:POWBOX_PRINT_IDENTITY = "1"
& pwsh -NoProfile -File $launcher -Agent claude -Name foo *> $null
$rejected = ($LASTEXITCODE -ne 0)
Remove-Item Env:POWBOX_PRINT_IDENTITY -ErrorAction SilentlyContinue
if (-not $rejected) { Fail "-Name without -Isolated should error" }
Ok "self-hosted-only flags are rejected without -Isolated"

Write-Host "Stage A passed ($script:pass checks)."

# --- Stage B - clone behavior against the image -------------------------------
if ($env:POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE) {
  Write-Host "Stage B skipped (POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE is set)."
  Write-Host "Self-hosted smoke test passed (Stage A only)."
  return
}
docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host "Stage B skipped: image '$Image' not found (build it to exercise the clone path)."
  Write-Host "Self-hosted smoke test passed (Stage A only)."
  return
}

Write-Host "Stage B - entrypoint clone behavior against $Image"
$wsVol = "powbox-smoke-ws-$PID"
$hv1 = "powbox-smoke-hl-a-$PID"
$hv2 = "powbox-smoke-hl-b-$PID"
$wsFail = "$wsVol-fail"
try {
  docker volume create $wsVol *> $null

  # clone-on-first-run
  docker run --rm --user root `
    -e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws -e GH_TOKEN= -e GITHUB_TOKEN= `
    -e "POWBOX_CLONE_REPO=$publicRepo" `
    -v "${wsVol}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image *> $null
  if ($LASTEXITCODE -ne 0) { Fail "clone-on-first-run failed for $publicRepo" }
  docker run --rm -v "${wsVol}:/ws" --entrypoint /bin/sh $Image -c '[ -e /ws/.git ]' *> $null
  if ($LASTEXITCODE -ne 0) { Fail "clone-on-first-run did not produce a .git" }
  Ok "clone-on-first-run produced a checkout"

  # reuse-skips-clone: a marker must survive a second run
  docker run --rm --user root -v "${wsVol}:/ws" --entrypoint /bin/sh $Image -c 'touch /ws/SMOKE_MARKER' *> $null
  $reuseOut = docker run --rm --user root `
    -e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws -e GH_TOKEN= -e GITHUB_TOKEN= `
    -e "POWBOX_CLONE_REPO=$publicRepo" `
    -v "${wsVol}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image 2>&1
  if ($reuseOut -notmatch "skipping clone") { Fail "reuse did not skip the clone" }
  docker run --rm -v "${wsVol}:/ws" --entrypoint /bin/sh $Image -c '[ -e /ws/SMOKE_MARKER ]' *> $null
  if ($LASTEXITCODE -ne 0) { Fail "reuse re-cloned (marker was wiped)" }
  Ok "reuse skips the clone and preserves the working tree"

  # -Reclone is a one-shot launcher action: it empties the (kept) volume, then the
  # entrypoint clones fresh. Simulate the launcher's prep wipe, then re-seed.
  docker run --rm --user root -v "${wsVol}:/ws" --entrypoint /bin/sh $Image -c 'find /ws -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; true' *> $null
  docker run --rm --user root `
    -e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws -e GH_TOKEN= -e GITHUB_TOKEN= `
    -e "POWBOX_CLONE_REPO=$publicRepo" `
    -v "${wsVol}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image *> $null
  if ($LASTEXITCODE -ne 0) { Fail "re-clone after a -Reclone wipe failed" }
  docker run --rm -v "${wsVol}:/ws" --entrypoint /bin/sh $Image -c '[ ! -e /ws/SMOKE_MARKER ] && [ -e /ws/.git ]' *> $null
  if ($LASTEXITCODE -ne 0) { Fail "-Reclone wipe + re-clone did not produce a clean checkout" }
  Ok "-Reclone (launcher empties the volume) yields a fresh clone"

  # unauthenticated/failed clone -> loud announcement + non-zero exit
  docker volume create $wsFail *> $null
  $failOut = docker run --rm --user root `
    -e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws -e GH_TOKEN= -e GITHUB_TOKEN= `
    -e "POWBOX_CLONE_REPO=this-org-does-not-exist-zzz/nope-9999" `
    -v "${wsFail}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image 2>&1
  $failRc = $LASTEXITCODE
  if ($failRc -eq 0) { Fail "a failed clone should exit non-zero" }
  if ($failOut -notmatch "POWBOX SELF-HOSTED CLONE FAILED") { Fail "a failed clone did not print the loud announcement" }
  if ($failOut -notmatch "gh auth login") { Fail "the announcement is missing the gh-auth remedy" }
  Ok "a failed clone announces loudly and exits non-zero"

  # Single-mount hardlink invariant: within ONE volume link(2) succeeds; ACROSS two
  # volumes it EXDEVs (the dir-mounted root-node_modules case the layout fixes).
  docker volume create $hv1 *> $null
  docker volume create $hv2 *> $null
  docker run --rm -v "${hv1}:/ws" --entrypoint /bin/sh $Image -c 'set -e; mkdir -p /ws/.worktrees/.pnpm-store /ws/node_modules /ws/.worktrees/task/node_modules; echo pkg > /ws/.worktrees/.pnpm-store/f; ln /ws/.worktrees/.pnpm-store/f /ws/node_modules/f; ln /ws/.worktrees/.pnpm-store/f /ws/.worktrees/task/node_modules/f; [ "$(stat -c %h /ws/.worktrees/.pnpm-store/f)" -ge 3 ]' *> $null
  if ($LASTEXITCODE -ne 0) { Fail "hardlink within one workspace volume failed (root + worktree node_modules)" }
  Ok "store hardlinks into BOTH the root and a worktree node_modules (one mount)"
  docker run --rm -v "${hv1}:/store" -v "${hv2}:/nm" --entrypoint /bin/sh $Image -c 'echo x > /store/g; if ln /store/g /nm/g 2>/dev/null; then exit 1; fi; exit 0' *> $null
  if ($LASTEXITCODE -ne 0) { Fail "cross-volume hardlink unexpectedly succeeded (EXDEV invariant broken)" }
  Ok "cross-mount hardlink EXDEVs (confirms why dir-mounted root node_modules copies)"

  Write-Host "Stage B passed."
}
finally {
  docker volume rm -f $wsVol $wsFail $hv1 $hv2 *> $null
}

Write-Host "Self-hosted smoke test passed."
