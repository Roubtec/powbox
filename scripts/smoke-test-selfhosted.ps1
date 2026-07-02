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

# Reuse the PowerShell engine running THIS script for the launcher child processes,
# instead of hard-coding `pwsh`. On Windows PowerShell 5.1 (Desktop) without
# PowerShell 7 on PATH, a bare `pwsh` would fail before any launcher check runs; the
# launcher .ps1 keeps 5.1 compatibility, so whichever host is running us can run it
# too. (Get-Process -Id $PID).Path is the exact current host exe (PowerShell adds
# .Path to process objects on both editions); fall back to an edition-based name if
# the process path is unavailable.
$psExe = (Get-Process -Id $PID).Path
if (-not $psExe) { $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' } }

$rootDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$launcher = Join-Path $rootDir "scripts/launch-agent.ps1"
# A tiny, stable public repo - no gh auth needed to clone it.
$defaultPublicRepo = "https://github.com/octocat/Hello-World.git"
$publicRepo = if ($env:POWBOX_SMOKE_PUBLIC_REPO) { $env:POWBOX_SMOKE_PUBLIC_REPO } else { $defaultPublicRepo }
# Two of the Stage-B ref cases assert against contents specific to the default repo:
# a tracked top-level path that is NOT a ref (octocat/Hello-World ships "README"),
# and a valid non-default branch ("test"). They are configurable so a custom
# POWBOX_SMOKE_PUBLIC_REPO fixture can still exercise them, but the Hello-World
# defaults apply ONLY to the default repo - so against any other repo with neither
# override set, each case self-skips rather than failing on a fixture mismatch. (The
# bogus-ref fallback case is repo-agnostic: every repo lacks "no-such-ref-zzz-9999".)
if ($publicRepo -eq $defaultPublicRepo) {
  $refPath = if ($env:POWBOX_SMOKE_REF_PATH) { $env:POWBOX_SMOKE_REF_PATH } else { "README" }
  $refBranch = if ($env:POWBOX_SMOKE_REF_BRANCH) { $env:POWBOX_SMOKE_REF_BRANCH } else { "test" }
}
else {
  $refPath = $env:POWBOX_SMOKE_REF_PATH
  $refBranch = $env:POWBOX_SMOKE_REF_BRANCH
}

$script:pass = 0
function Fail([string]$m) { Write-Error "FAIL: $m"; exit 1 }
function Ok([string]$m) { $script:pass++; Write-Host "  ok: $m" }

# Run the launcher with the print-identity hook (as a child process so its `exit`
# does not terminate this script) and return a hashtable of KEY=VALUE fields.
function Get-Identity {
  param([string[]]$LauncherArgs)
  $env:POWBOX_PRINT_IDENTITY = "1"
  try {
    $out = & $psExe -NoProfile -File $launcher @LauncherArgs 2>$null
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

# --- dir-mounted volume-gate matrix (the SPLIT gate, task 011) -----------------
# agent-nm-* keys on the JS/powbox gate (package.json / pnpm-workspace.yaml /
# .powbox.yml -> MOUNT_WORKSPACE_VOLUMES, which also gates PNPM_STORE_DIR);
# agent-wt-* keys on the WIDER worktrees gate that additionally triggers on
# go.mod (MOUNT_WORKTREES_VOLUME, which gates GOMODCACHE/GOCACHE) - so a pure-Go
# repo gets persistent Go caches + worktrees WITHOUT an empty node_modules/
# mountpoint littering the host folder. Four fixture shapes pin the matrix.
$matrixRoot = Join-Path ([System.IO.Path]::GetTempPath()) "powbox-smoke-gate-$PID"
try {
  foreach ($dir in @("pkg-only", "gomod-only", "both", "neither")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $matrixRoot $dir) | Out-Null
  }
  foreach ($marker in @(@("pkg-only", "package.json"), @("gomod-only", "go.mod"), @("both", "package.json"), @("both", "go.mod"))) {
    New-Item -ItemType File -Force -Path (Join-Path (Join-Path $matrixRoot $marker[0]) $marker[1]) | Out-Null
  }
  foreach ($case in @(
      @("pkg-only", "true", "true"),
      @("gomod-only", "false", "true"),
      @("both", "true", "true"),
      @("neither", "false", "false"))) {
    $gid = Get-Identity @("-Agent", "claude", "-ProjectPath", (Join-Path $matrixRoot $case[0]))
    if ($gid["MOUNT_WORKSPACE_VOLUMES"] -ne $case[1]) { Fail "gate matrix $($case[0]): MOUNT_WORKSPACE_VOLUMES is '$($gid["MOUNT_WORKSPACE_VOLUMES"])', want '$($case[1])'" }
    if ($gid["MOUNT_WORKTREES_VOLUME"] -ne $case[2]) { Fail "gate matrix $($case[0]): MOUNT_WORKTREES_VOLUME is '$($gid["MOUNT_WORKTREES_VOLUME"])', want '$($case[2])'" }
  }
}
finally {
  Remove-Item -Recurse -Force $matrixRoot -ErrorAction SilentlyContinue
}
Ok "volume-gate matrix: nm keys on the JS/powbox gate, wt also on go.mod (pkg-only / go.mod-only / both / neither)"

# --- named -> deterministic ---------------------------------------------------
$n1 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/Repo.git", "-Name", "foo")
$n2 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/Repo.git", "-Name", "foo")
if ($n1["mode"] -ne "isolated") { Fail "-Isolated did not select isolated mode" }
if ($n1["CONTAINER_NAME"] -ne $n2["CONTAINER_NAME"]) { Fail "named instance is not deterministic across launches" }
if ($n1["WORKSPACE_MOUNT"] -ne $n2["WORKSPACE_MOUNT"]) { Fail "named instance workspace path (-> Claude session slug) is not stable" }
Ok "named instance is deterministic (same workspace path / session slug on relaunch)"

# --- the -Name slug is visible in the container name (so cc-list / docker ps show WHICH
# instance), sitting between the repo slug and the trailing hash.
if ($n1["CONTAINER_NAME"] -notlike "*-foo-*") { Fail "named instance does not surface the -Name slug: $($n1["CONTAINER_NAME"])" }
Ok "named instance surfaces the -Name slug in the container name"

# --- two -Names that SLUGIFY ALIKE stay DISTINCT (the hash folds in the RAW name), so a
# slug collision never merges two instances - yet both show the SAME visible slug, so the
# raw powbox.instance-name label (not asserted here; no Docker) is the tiebreaker.
$c1 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/app", "-Name", "Feature A")
$c2 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/app", "-Name", "feature/a")
if ($c1["CONTAINER_NAME"] -eq $c2["CONTAINER_NAME"]) { Fail "two -Names that slugify alike collided (the hash must fold in the raw name)" }
if ($c1["CONTAINER_NAME"] -notlike "*-feature-a-*") { Fail "slug 'feature-a' not derived from 'Feature A'" }
if ($c2["CONTAINER_NAME"] -notlike "*-feature-a-*") { Fail "slug 'feature-a' not derived from 'feature/a'" }
Ok "slug collisions stay distinct (raw name in the hash) while sharing the visible slug"

# --- -Ref is VOLATILE and must NOT enter the identity hash: a re-run with a different
# -Ref has to reuse the SAME container (not fork a new clone per ref).
$r1 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/app", "-Name", "refstable", "-Ref", "main")
$r2 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/app", "-Name", "refstable", "-Ref", "dev")
if ($r1["CONTAINER_NAME"] -ne $r2["CONTAINER_NAME"]) { Fail "-Ref changed the container identity (it must not enter the hash)" }
Ok "-Ref does not enter the container identity (same name reuses one container across refs)"

# --- named identity is PER-REPO: same -Name on a different repo must not collide
# Two remotes that share a basename (owner1/app, owner2/app) launched with the same
# -Name must resolve to DISTINCT identities; otherwise the second launch would
# attach to (or -Reclone wipe) the first repo's container/workspace.
$p1 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner1/app", "-Name", "shared")
$p2 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner2/app", "-Name", "shared")
if ($p1["CONTAINER_NAME"] -eq $p2["CONTAINER_NAME"]) { Fail "two repos sharing a basename collide under the same -Name" }
if ($p1["WORKSPACE_MOUNT"] -eq $p2["WORKSPACE_MOUNT"]) { Fail "two repos sharing a basename share a workspace path under the same -Name" }
Ok "named identity is per-repo (owner1/app vs owner2/app, same -Name, differ)"

# ... while the SAME repo expressed different ways (slug, full https URL, an uppercase
# .GIT extension, or a copied URL with a trailing slash) under the same -Name stays
# stable, so reuse is not broken by spec form (the .GIT case also guards .sh/.ps1
# strip-case parity; the trailing-slash case guards the slash-trim before .git strip).
$s1 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/app", "-Name", "stable")
$s2 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "https://github.com/owner/app.git", "-Name", "stable")
$s3 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/app.GIT", "-Name", "stable")
$s4 = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "https://github.com/owner/app.git/", "-Name", "stable")
if ($s1["CONTAINER_NAME"] -ne $s2["CONTAINER_NAME"]) { Fail "same repo via slug vs https URL produced different identities under the same -Name" }
if ($s1["CONTAINER_NAME"] -ne $s3["CONTAINER_NAME"]) { Fail "uppercase .GIT extension produced a different identity (case-sensitive .git strip)" }
if ($s1["CONTAINER_NAME"] -ne $s4["CONTAINER_NAME"]) { Fail "a trailing slash on the clone URL produced a different identity (reuse would break)" }
Ok "named identity is spec-form stable (slug == https URL == owner/app.GIT == trailing slash)"

# --- cross-AGENT distinctness: the SAME repo+name under claude vs codex must get a
# DISTINCT workspace PATH (not only a distinct ws volume). Both agents always mount the
# global claude-config/codex-config volumes, and a delegated peer agent resumes sessions
# by cwd, so a shared /workspace/<slug> would let one agent's clone inherit the other's
# session history. The instance hash folds in the agent to keep the path per-container,
# matching the per-container agent-ws-<container> volume.
$ac = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "owner/app", "-Name", "dual")
$ax = Get-Identity @("-Agent", "codex", "-Isolated", "-Repo", "owner/app", "-Name", "dual")
if ($ac["WORKSPACE_MOUNT"] -eq $ax["WORKSPACE_MOUNT"]) { Fail "claude and codex share a workspace path for the same repo/name (session-history bleed)" }
if ($ac["WS_VOLUME"] -eq $ax["WS_VOLUME"]) { Fail "claude and codex share a workspace volume for the same repo/name" }
Ok "cross-agent identity is distinct (claude vs codex, same repo/name, differ in path + volume)"

# --- embedded http(s) credentials are rejected, not frozen into POWBOX_CLONE_REPO (a
# kept self-hosted container would expose the secret via docker inspect). The
# print-identity hook runs AFTER this check, so a rejected spec exits non-zero here.
$env:POWBOX_PRINT_IDENTITY = "1"
& $psExe -NoProfile -File $launcher -Agent claude -Isolated -Repo 'https://x-access-token:ghp_smoketoken@github.com/owner/repo.git' -Name credtest *> $null
$credRejected = ($LASTEXITCODE -ne 0)
Remove-Item Env:POWBOX_PRINT_IDENTITY -ErrorAction SilentlyContinue
if (-not $credRejected) { Fail "a clone URL with embedded credentials should be rejected" }
Ok "embedded-credential clone URLs are rejected"

# ... and the scheme match is case-insensitive (RFC 3986), so an UPPERCASE scheme
# cannot smuggle the credential past the reject.
$env:POWBOX_PRINT_IDENTITY = "1"
& $psExe -NoProfile -File $launcher -Agent claude -Isolated -Repo 'HTTPS://x-access-token:ghp_smoketoken@github.com/owner/repo.git' -Name credtest *> $null
$credRejectedUpper = ($LASTEXITCODE -ne 0)
Remove-Item Env:POWBOX_PRINT_IDENTITY -ErrorAction SilentlyContinue
if (-not $credRejectedUpper) { Fail "an embedded-credential clone URL with an uppercase scheme should still be rejected" }
Ok "embedded-credential URLs with an uppercase scheme are rejected"

# ... while an ssh:// spec (benign git@ SSH user, no secret; normalised to https in the
# container) is accepted and passed through unchanged, not mistaken for a credential.
$sshId = Get-Identity @("-Agent", "claude", "-Isolated", "-Repo", "ssh://git@github.com/owner/repo.git", "-Name", "sshok")
if ($sshId["REPO_SPEC"] -ne "ssh://git@github.com/owner/repo.git") { Fail "ssh:// GitHub spec was rejected or altered by the launcher (should pass through)" }
Ok "ssh:// GitHub spec is accepted (normalised to https in-container, not treated as a credential)"

# --- control characters in identity inputs are rejected before they freeze into labels.
# cc-list/agent-list parse the labels back with a \x1f field separator and one-container-
# per-line reads, so a newline or a literal \x1f in -Name/-Repo/-Ref would corrupt the
# listing; the launcher rejects them. The print-identity hook runs AFTER this check.
$env:POWBOX_PRINT_IDENTITY = "1"
& $psExe -NoProfile -File $launcher -Agent claude -Isolated -Repo owner/repo -Name "bad`nname" *> $null
$nlRejected = ($LASTEXITCODE -ne 0)
Remove-Item Env:POWBOX_PRINT_IDENTITY -ErrorAction SilentlyContinue
if (-not $nlRejected) { Fail "a -Name containing a newline should be rejected" }
Ok "control characters in -Name are rejected"

$env:POWBOX_PRINT_IDENTITY = "1"
& $psExe -NoProfile -File $launcher -Agent claude -Isolated -Repo owner/repo -Name ok -Ref ("a" + [char]31 + "b") *> $null
$usRejected = ($LASTEXITCODE -ne 0)
Remove-Item Env:POWBOX_PRINT_IDENTITY -ErrorAction SilentlyContinue
if (-not $usRejected) { Fail "a -Ref containing a \x1f unit separator should be rejected" }
Ok "control characters in -Ref are rejected"

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
& $psExe -NoProfile -File $launcher -Agent claude -Name foo *> $null
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
  if ($env:POWBOX_SMOKE_REQUIRE_IMAGE) {
    throw "image '$Image' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set - Stage B (clone behavior) requires the image."
  }
  Write-Host "Stage B skipped: image '$Image' not found (build it to exercise the clone path)."
  Write-Host "Self-hosted smoke test passed (Stage A only)."
  return
}

Write-Host "Stage B - entrypoint clone behavior against $Image"
$wsVol = "powbox-smoke-ws-$PID"
$hv1 = "powbox-smoke-hl-a-$PID"
$hv2 = "powbox-smoke-hl-b-$PID"
$wsFail = "$wsVol-fail"
$wsSsh = "$wsVol-ssh"
$wsSshp = "$wsVol-sshp"
$wsScp = "$wsVol-scp"
$wsSlug = "$wsVol-slug"
$wsRef = "$wsVol-ref"
$wsPath = "$wsVol-path"
$wsBranch = "$wsVol-branch"
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
    -v "${wsVol}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image 2>&1 | Out-String
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

  # A bogus -Ref does NOT fail the clone: seed clones the default branch first, then the
  # post-clone checkout of the ref fails BENIGNLY - warn + stay on default, still a valid
  # checkout (vs. the old `clone --branch` form, which aborted the whole clone).
  docker volume create $wsRef *> $null
  $refOut = docker run --rm --user root `
    -e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws -e GH_TOKEN= -e GITHUB_TOKEN= `
    -e "POWBOX_CLONE_REPO=$publicRepo" -e "POWBOX_CLONE_REF=no-such-ref-zzz-9999" `
    -v "${wsRef}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image 2>&1 | Out-String
  docker run --rm -v "${wsRef}:/ws" --entrypoint /bin/sh $Image -c '[ -e /ws/.git ]' *> $null
  if ($LASTEXITCODE -ne 0) { Fail "a bogus -Ref aborted the clone (should fall back to the default branch)" }
  if ($refOut -notmatch "POWBOX --ref WARNING") { Fail "a bogus -Ref did not print the fallback warning" }
  Ok "a bogus -Ref falls back to the default branch with a warning (clone still succeeds)"

  # A -Ref that is a TYPO matching a tracked PATH ($refPath; octocat/Hello-World ships a
  # top-level "README" file, which is NOT a ref) must ALSO fall back: a bare `git checkout
  # README` would succeed as a path checkout and silently strand the tree on the default
  # branch, so the ref is resolved to a commit first and an unresolved name degrades to the
  # warning. Skipped when no tracked-non-ref path is known for a custom repo (see $refPath).
  if ($refPath) {
    docker volume create $wsPath *> $null
    $pathOut = docker run --rm --user root `
      -e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws -e GH_TOKEN= -e GITHUB_TOKEN= `
      -e "POWBOX_CLONE_REPO=$publicRepo" -e "POWBOX_CLONE_REF=$refPath" `
      -v "${wsPath}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image 2>&1 | Out-String
    docker run --rm -v "${wsPath}:/ws" --entrypoint /bin/sh $Image -c '[ -e /ws/.git ]' *> $null
    if ($LASTEXITCODE -ne 0) { Fail "a path-matching -Ref aborted the clone (should fall back to the default branch)" }
    if ($pathOut -notmatch "POWBOX --ref WARNING") { Fail "a path-matching -Ref was silently checked out as a pathspec instead of warning" }
    if ($pathOut -match ("checked out ref '" + [regex]::Escape($refPath) + "'")) { Fail "a path-matching -Ref reported a successful ref checkout (pathspec ambiguity not rejected)" }
    Ok "a path-matching -Ref typo falls back with a warning (pathspec is not mistaken for a ref)"
  }
  else {
    Write-Host "  skip: path-matching -Ref typo case (set POWBOX_SMOKE_REF_PATH to a tracked non-ref path for a custom repo)"
  }

  # A valid NON-DEFAULT branch by bare name ($refBranch; octocat/Hello-World ships a "test"
  # branch) is the primary -Ref use case and MUST check out: a fresh clone materializes only
  # the default branch as a local head, so the ref-resolution guard has to accept the
  # refs/remotes/origin/* form too - verifying only the bare name would wrongly strand the
  # user on the default branch. Skipped when no non-default branch is known for a custom repo.
  if ($refBranch) {
    docker volume create $wsBranch *> $null
    $branchOut = docker run --rm --user root `
      -e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws -e GH_TOKEN= -e GITHUB_TOKEN= `
      -e "POWBOX_CLONE_REPO=$publicRepo" -e "POWBOX_CLONE_REF=$refBranch" `
      -v "${wsBranch}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image 2>&1 | Out-String
    if ($branchOut -notmatch ("checked out ref '" + [regex]::Escape($refBranch) + "'")) { Fail "a valid non-default branch -Ref was not checked out (origin/ tracking form rejected?)" }
    if ($branchOut -match "POWBOX --ref WARNING") { Fail "a valid non-default branch -Ref printed the fallback warning instead of checking out" }
    $branchHead = (docker run --rm -v "${wsBranch}:/ws" --entrypoint git $Image -C /ws rev-parse --abbrev-ref HEAD 2>$null | Out-String).Trim()
    if ($branchHead -ne $refBranch) { Fail "a valid non-default branch -Ref did not leave HEAD on that branch" }
    Ok "a valid non-default branch -Ref checks out (remote-tracking ref is resolved, not rejected)"
  }
  else {
    Write-Host "  skip: non-default branch -Ref case (set POWBOX_SMOKE_REF_BRANCH to a valid non-default branch for a custom repo)"
  }

  # unauthenticated/failed clone -> loud announcement + non-zero exit
  docker volume create $wsFail *> $null
  $failOut = docker run --rm --user root `
    -e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws -e GH_TOKEN= -e GITHUB_TOKEN= `
    -e "POWBOX_CLONE_REPO=this-org-does-not-exist-zzz/nope-9999" `
    -v "${wsFail}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image 2>&1 | Out-String
  $failRc = $LASTEXITCODE
  if ($failRc -eq 0) { Fail "a failed clone should exit non-zero" }
  if ($failOut -notmatch "POWBOX SELF-HOSTED CLONE FAILED") { Fail "a failed clone did not print the loud announcement" }
  if ($failOut -notmatch "gh auth login") { Fail "the announcement is missing the gh-auth remedy" }
  Ok "a failed clone announces loudly and exits non-zero"

  # ssh:// GitHub URLs are normalised to HTTPS before cloning (the container has no SSH
  # keys; the entrypoint's git@github.com: insteadOf historically missed ssh://). The
  # pre-clone log line prints the RESOLVED url, so a fast-failing nonexistent ssh:// repo
  # (fresh volume -> not the reuse path) must show the https form, proving the normalise.
  docker volume create $wsSsh *> $null
  $sshOut = docker run --rm --user root `
    -e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws -e GH_TOKEN= -e GITHUB_TOKEN= `
    -e 'POWBOX_CLONE_REPO=ssh://git@github.com/this-org-does-not-exist-zzz/nope-9999.git' `
    -v "${wsSsh}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image 2>&1 | Out-String
  if ($sshOut -notmatch 'https://github\.com/this-org-does-not-exist-zzz/nope-9999\.git') { Fail "ssh:// GitHub URL was not normalised to https before cloning" }
  Ok "ssh:// GitHub URL is normalised to https before cloning"

  # ... and an explicit-port, bare-host ssh:// URL (ssh://github.com:22/owner/repo.git -
  # no git@ user, the form git emits for an origin on a custom SSH port) is normalised
  # too. This covers the OTHER two normalisation axes the git@-form ssh test above does
  # not: a missing git@ user AND a :port the entrypoint insteadOf (a prefix rewrite)
  # cannot strip - so clone_url must, or it would fall through to a keyless SSH clone and
  # fail. Same fast-fail proof as above.
  docker volume create $wsSshp *> $null
  $sshpOut = docker run --rm --user root `
    -e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws -e GH_TOKEN= -e GITHUB_TOKEN= `
    -e 'POWBOX_CLONE_REPO=ssh://github.com:22/this-org-does-not-exist-zzz/nope-9999.git' `
    -v "${wsSshp}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image 2>&1 | Out-String
  if ($sshpOut -notmatch 'https://github\.com/this-org-does-not-exist-zzz/nope-9999\.git') { Fail "bare-host ported ssh:// GitHub URL (no git@, with :22) was not normalised to https before cloning" }
  Ok "bare-host ported ssh:// GitHub URL (no git@, explicit :port) is normalised to https before cloning"

  # scp-style GitHub remotes (git@github.com:owner/repo.git - the form inferred from a
  # typical local checkout's origin) are normalised to HTTPS too: the insteadOf rewrite
  # is installed only after gh auth succeeds, so an unauthenticated public clone would
  # otherwise fail on the bare git@ URL. Same fast-fail proof as the ssh:// case above.
  docker volume create $wsScp *> $null
  $scpOut = docker run --rm --user root `
    -e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws -e GH_TOKEN= -e GITHUB_TOKEN= `
    -e 'POWBOX_CLONE_REPO=git@github.com:this-org-does-not-exist-zzz/nope-9999.git' `
    -v "${wsScp}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image 2>&1 | Out-String
  if ($scpOut -notmatch 'https://github\.com/this-org-does-not-exist-zzz/nope-9999\.git') { Fail "scp-style git@github.com: URL was not normalised to https before cloning" }
  Ok "scp-style git@github.com: URL is normalised to https before cloning"

  # A bare owner/repo slug with a TRAILING SLASH (e.g. owner/repo/ - a copied/pasted
  # spec) is normalised to the canonical https://github.com/owner/repo.git: the slug
  # branch trims trailing slashes BEFORE appending .git, so it cannot emit the invalid
  # https://github.com/.../nope-9999/.git. The dots are escaped so the buggy form
  # (.../nope-9999/.git) cannot satisfy the -match. Same fast-fail proof as above.
  docker volume create $wsSlug *> $null
  $slugOut = docker run --rm --user root `
    -e POWBOX_SELF_HOSTED=1 -e POWBOX_WORKSPACE_DIR=/ws -e GH_TOKEN= -e GITHUB_TOKEN= `
    -e 'POWBOX_CLONE_REPO=this-org-does-not-exist-zzz/nope-9999/' `
    -v "${wsSlug}:/ws" --entrypoint /usr/local/bin/seed-workspace.sh $Image 2>&1 | Out-String
  if ($slugOut -notmatch 'https://github\.com/this-org-does-not-exist-zzz/nope-9999\.git') { Fail "a trailing-slash owner/repo slug was not normalised to a clean https URL (saw .../nope-9999/.git?)" }
  Ok "a trailing-slash owner/repo slug is normalised to a clean https URL before cloning"

  # Single-mount hardlink invariant: within ONE volume link(2) succeeds; ACROSS two
  # volumes it EXDEVs (the dir-mounted root-node_modules case the layout fixes). Run as
  # root (like every other volume-writing step above): a fresh empty named volume's
  # root is root-owned, and unlike a real launch this test does not run the launcher's
  # chown pre-seed of the workspace volume (launch-agent.sh), so node could not mkdir
  # here. The link(2)/EXDEV result is a filesystem property, independent of the uid.
  docker volume create $hv1 *> $null
  docker volume create $hv2 *> $null
  docker run --rm --user root -v "${hv1}:/ws" --entrypoint /bin/sh $Image -c 'set -e; mkdir -p /ws/.worktrees/.pnpm-store /ws/node_modules /ws/.worktrees/task/node_modules; echo pkg > /ws/.worktrees/.pnpm-store/f; ln /ws/.worktrees/.pnpm-store/f /ws/node_modules/f; ln /ws/.worktrees/.pnpm-store/f /ws/.worktrees/task/node_modules/f; [ "$(stat -c %h /ws/.worktrees/.pnpm-store/f)" -ge 3 ]' *> $null
  if ($LASTEXITCODE -ne 0) { Fail "hardlink within one workspace volume failed (root + worktree node_modules)" }
  Ok "store hardlinks into BOTH the root and a worktree node_modules (one mount)"
  docker run --rm --user root -v "${hv1}:/store" -v "${hv2}:/nm" --entrypoint /bin/sh $Image -c 'echo x > /store/g; if ln /store/g /nm/g 2>/dev/null; then exit 1; fi; exit 0' *> $null
  if ($LASTEXITCODE -ne 0) { Fail "cross-volume hardlink unexpectedly succeeded (EXDEV invariant broken)" }
  Ok "cross-mount hardlink EXDEVs (confirms why dir-mounted root node_modules copies)"

  Write-Host "Stage B passed."
}
finally {
  docker volume rm -f $wsVol $wsFail $wsSsh $wsSshp $wsScp $wsSlug $wsRef $wsPath $wsBranch $hv1 $hv2 *> $null
}

Write-Host "Self-hosted smoke test passed."
