param(
  [string]$Image = "powbox-agent:latest"
)

# Smoke-test the DURABLE worktree-metadata lifecycle (task 017), behaviourally
# identical to scripts/smoke-test-worktree-metadata.sh except for one deliberate,
# narrower divergence - see NON-LINUX HOSTS below. In dir-mounted mode a linked
# git worktree - and its per-worktree admin metadata - must SURVIVE a container
# stop/recreate, because the metadata is bound from the persistent .worktrees volume
# over .git/worktrees instead of living in the tmpfs shadow that vanishes on recycle.
# This is the headline acceptance criterion; the hermetic
# scripts/test-wt-orphan-safety.sh only unit-tests the orphan-reaping SAFETY net, not
# the central bind/survive path, so a broken bind, a commondir/gitdir path that does
# not resolve after recreate, or a metadata dir that lands on the host instead of the
# volume would pass every other test and still ship broken.
#
# What it exercises, end to end, against a REAL built agent image:
#   1. Container A: dir-mount a throwaway git repo at /workspace/repo with a NAMED
#      agent-wt-style volume at /workspace/repo/.worktrees, run the SAME privileged
#      helper the entrypoint uses (/usr/local/bin/shadow-mounts.sh) to bind the
#      volume's .gitworktrees subdir over .git/worktrees, then `git worktree add` a
#      linked worktree under .worktrees/<container>/<slug> and leave it DIRTY - a
#      tracked-file modification AND an untracked new file.
#   2. Container A exits: its mount namespace (and the bind) is torn down; only the
#      persistent volume survives.
#   3. Container B: recreate on the SAME volume + repo, re-establish the bind, and
#      assert the recycled worktree is intact - `git status` works (metadata
#      survived), HEAD is on the worktree branch, and BOTH the tracked modification
#      and the untracked file are still present.
#   4. Host-side: the dir-mounted checkout's real .git/worktrees gained NO container
#      registrations - the bind kept every registration inside the volume.
#   5. Host-side (task 053): every mountpoint directory shadow-mounts.sh had to CREATE
#      inherited the ownership of the deepest ancestor that already existed, instead of
#      being left root-owned. Covered: a SINGLE created component on the ordinary tmpfs
#      path (proj/bin - the .NET artifact shape the chown was written for, whose proj
#      parent already existed), a MULTI-component creation (.claude/worktrees, where two
#      levels are created and the walk has to reach the workspace root), and the
#      SINGLE-component case on the special durable-bind path (.git/worktrees), which
#      takes a different branch through shadow-mounts.sh and so is not redundant. These
#      assertions are deliberately tolerant and are therefore VACUOUS on a squashing
#      filesystem, under a rootless engine, and when the smoke itself runs as root; see
#      the block itself.
#
# NON-LINUX HOSTS (task 053a): item 5 is the one place this driver is deliberately
# narrower than the Bash script. This driver runs anywhere pwsh runs, and on a
# Windows/macOS bind mount uid:gid is squashed - every path reports the same owner, so
# the equality assertions would compare equal without proving anything. A vacuous green
# is the very disease this coverage exists to cure, so the ownership assertions are
# gated on $IsLinux and a counted Note-Skip is recorded (and surfaced in the umbrella
# banner) on any other host. The rest of the stage stays OS-agnostic: the durable bind
# itself happens inside the Linux VM. Both containers' inner scripts are SHARED with the
# Bash driver (scripts/smoke-test-worktree-metadata-container-a.bash and
# -container-b.bash) so they cannot drift apart again; the host-side assertions are
# written natively in each.
#
# Privileges: the durable bind is a `mount --bind`, so the container needs
# CAP_SYS_ADMIN + an unconfined seccomp/apparmor profile - the launch-time wiring the
# launcher supplies via compose.shared.yml and that smoke-test-podman.ps1 replicates.
#
# FAIL-CLOSED contract (round-3 review): this stage exists to guard the durable-bind
# lifecycle, so a regression in that bind must NOT masquerade as a skip. Each inner
# container runs an INDEPENDENT mount-capability preflight (a throwaway temp-over-temp
# `mount --bind` that does NOT touch shadow-mounts.sh / bind_git_worktrees) and
# self-skips (exit 42) ONLY when that preflight proves the runtime genuinely cannot
# bind-mount, or the persistent .worktrees volume is not mounted. Once capability is
# proven, a shadow-mounts.sh failure, a tmpfs fallback, a missing mountpoint, or a
# bind that maps the wrong source is a HARD TEST FAILURE (non-42 exit), never a skip.
#
# Self-skips (no failure) when it cannot meaningfully run: the agent image is absent
# (unless POWBOX_SMOKE_REQUIRE_IMAGE is set, then it fails); or the independent
# preflight proves the runtime cannot `mount --bind` at all, or the persistent
# .worktrees volume is not mounted. A durable bind that fails to materialize AFTER
# capability is proven is a hard failure, not a skip. The recreate lifecycle runs for
# real on a native-Linux CI runner.

$ErrorActionPreference = "Stop"

# Constant in-container paths. Each case runs its own container, so these never
# collide; the host-side fixture and the named volume are per-run unique.
$mount = "/workspace/powbox-wtmeta-smoke"
$containerSlug = "smokecont"
$wtSlug = "durable-task"

function Fail([string]$m) { Write-Error "FAIL: $m"; exit 1 }

# Record a runtime self-skip reason for the umbrella banner. The stage still returns
# success on a self-skip, so commands/smoke-test.ps1 cannot tell a real pass from a
# skip on its own; it passes POWBOX_SMOKE_SKIP_MARKER and we write the reason there.
# A no-op when unset. Mirrors scripts/smoke-test-dirmount.ps1.
function Note-Skip([string]$Reason) {
  if ($env:POWBOX_SMOKE_SKIP_MARKER) {
    Set-Content -LiteralPath $env:POWBOX_SMOKE_SKIP_MARKER -Value $Reason -NoNewline
  }
}

# GNU (-c) vs BSD/macOS (-f) stat: a host smoke run may be on either. Shelling out is
# owner_of() from scripts/smoke-test-worktree-metadata.sh, byte for byte, and it is the
# whole story - .NET exposes UnixFileMode but not the owner uid/gid, so a native route
# would mean P/Invoke into libc. Returns $null when NEITHER form works; the caller then
# skips the ownership assertions rather than failing (same tolerance as the .sh).
function Get-PathOwnerId([string]$Path) {
  foreach ($fmt in @('-c', '-f')) {
    # try/catch per attempt, not once around the loop: a pwsh host with
    # $PSNativeCommandUseErrorActionPreference on turns a non-zero `stat` into a
    # terminating error, and a failed GNU -c must still fall through to the BSD -f form.
    try {
      $out = & stat $fmt '%u:%g' $Path 2>$null
      if ($LASTEXITCODE -eq 0 -and $out) { return ([string](@($out)[0])).Trim() }
    }
    catch {
      Write-Debug "stat $fmt on '$Path' failed: $_"
    }
  }
  return $null
}

# Assert a mountpoint directory shadow-mounts.sh had to CREATE inherited the uid:gid of
# the deepest ancestor that already existed. EQUALITY with that ancestor, never
# "-eq (id -u)": where chown is a no-op every path reports the same squashed owner, so
# this passes instead of failing spuriously, while on a native-Linux mount a missing
# chown leaves the directory root-owned and the assertion fires. Equality also subsumes
# the weaker "must not be root" form whenever the tree's owner is not root.
function Assert-CreatedMountpointOwner([string]$Dir, [string]$Ancestor, [string]$Label) {
  if (-not (Test-Path -LiteralPath $Dir)) {
    Fail "mountpoint ownership ($Label): shadow-mounts.sh should have created '$Dir', but it is absent on the host after the container exited"
  }
  $got = Get-PathOwnerId $Dir
  if (-not $got) { Fail "mountpoint ownership ($Label): cannot stat '$Dir'" }
  $want = Get-PathOwnerId $Ancestor
  if (-not $want) { Fail "mountpoint ownership ($Label): cannot stat '$Ancestor'" }
  if ($got -ne $want) {
    Fail "mountpoint ownership ($Label): '$Dir' is owned by $got but its deepest pre-existing ancestor '$Ancestor' is owned by $want - the created mountpoint did NOT inherit the tree's ownership. The shadow-mounts.sh mountpoint chown has regressed; on a native-Linux bind mount the host user is left unable to populate or remove that directory."
  }
  $shortDir = $Dir.Replace($script:fixture, '<fixture>')
  $shortAnc = $Ancestor.Replace($script:fixture, '<fixture>')
  Write-Host "  ok: mountpoint ownership ($Label) - $shortDir inherited $got from its pre-existing ancestor $shortAnc"
}

# The privileged run wiring the durable bind needs: CAP_SYS_ADMIN for mount(2) and an
# unconfined seccomp/apparmor profile. Same set smoke-test-podman.ps1 uses. We run as
# root so shadow-mounts.sh (normally invoked via sudo from the entrypoint) can bind.
$runArgs = @(
  '--rm'
  '--user', 'root'
  '--cap-add', 'SYS_ADMIN'
  '--security-opt', 'seccomp=unconfined'
  '--security-opt', 'apparmor=unconfined'
)

# The in-container setup script (Container A) is SHARED with
# scripts/smoke-test-worktree-metadata.sh (task 053a): ONE file, so a change to it
# cannot land in one driver only. Its header carries the arg/exit-code contract.
# -Encoding UTF8 is load-bearing, not decorative: Windows PowerShell 5.1 decodes a
# BOM-less file with the system ANSI codepage, so a non-ASCII byte in a shared file
# would reach `bash -c` mangled from here and intact from the .sh driver - exactly the
# per-driver drift these shared files exist to prevent. The CRLF strip is defensive -
# .gitattributes pins that file to LF, but a checkout that mangled it would feed
# /bin/bash -c a payload with stray ^M. The emptiness check stops a truncated file from
# handing the container a no-op payload that exits 0 and reports the stage as passed.
# -PathType Leaf is load-bearing too: a bare Test-Path answers yes for a directory, whose
# Get-Content would then throw past this stage's own Fail messaging.
$setupScriptPath = Join-Path $PSScriptRoot 'smoke-test-worktree-metadata-container-a.bash'
if (-not (Test-Path -LiteralPath $setupScriptPath -PathType Leaf)) { Fail "the shared Container A script is missing or not a file: $setupScriptPath" }
$setupScript = (Get-Content -Raw -Encoding UTF8 -LiteralPath $setupScriptPath) -replace "`r`n", "`n"
if ([string]::IsNullOrWhiteSpace($setupScript)) { Fail "the shared Container A script is empty: $setupScriptPath" }

# The in-container verify script (Container B) is SHARED with
# scripts/smoke-test-worktree-metadata.sh in exactly the way Container A above is
# (task 053b): ONE file, so a change to it cannot land in one driver only. Its header
# carries the arg/exit-code contract. It also holds the only non-ASCII character in
# either shared file (an em dash), so the -Encoding UTF8 explained above is what makes
# this read deliver the same characters as the .sh driver's - the em dash included, on
# 5.1 as well as on 7. The two captures still differ by a single trailing LF, because
# Bash command substitution strips trailing newlines and Get-Content -Raw does not; that
# byte is immaterial to what /bin/bash -c executes. Same CRLF strip, same Leaf test and
# same emptiness check, for the same reasons.
$verifyScriptPath = Join-Path $PSScriptRoot 'smoke-test-worktree-metadata-container-b.bash'
if (-not (Test-Path -LiteralPath $verifyScriptPath -PathType Leaf)) { Fail "the shared Container B script is missing or not a file: $verifyScriptPath" }
$verifyScript = (Get-Content -Raw -Encoding UTF8 -LiteralPath $verifyScriptPath) -replace "`r`n", "`n"
if ([string]::IsNullOrWhiteSpace($verifyScript)) { Fail "the shared Container B script is empty: $verifyScriptPath" }

Write-Host "Worktree durable-metadata smoke test (image: $Image)"

# --- image gate (mirrors smoke-test-dirmount.ps1) -----------------------------
docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) {
  if ($env:POWBOX_SMOKE_REQUIRE_IMAGE) {
    throw "image '$Image' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set - the durable-metadata stage requires the image."
  }
  Note-Skip "image '$Image' not found"
  Write-Host "Worktree durable-metadata stage skipped: image '$Image' not found (build it to exercise the recreate lifecycle)."
  return
}

# --- fixture + volume lifecycle -----------------------------------------------
# A PowerShell-native temp dir (not `mktemp`) so the host side is portable to a
# Windows/macOS host running Docker Desktop - the durable bind itself happens in the
# Linux VM, so unlike the native-Linux-only dir-mount stage this one has no host-OS
# gate; it self-skips (exit 42) if the runtime cannot grant the bind privilege.
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) ("powbox-wtmeta-" + [System.IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$wtVol = "powbox-smoke-wtmeta-$PID"
try {
  & git -C $fixture init -q
  Set-Content -LiteralPath (Join-Path $fixture 'tracked.txt') -Value 'base tracked content'
  # A stand-in project directory for the mountpoint-ownership coverage (task 053): it
  # is created HERE, by the invoking host user, so when Container A shadows proj/bin
  # the only NEW component is bin and its deepest existing ancestor is this
  # invoker-owned proj. That is the .NET artifact shape the chown exists for.
  New-Item -ItemType Directory -Path (Join-Path $fixture 'proj') -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $fixture 'proj/project.marker') -Value 'stand-in for a project whose bin/ is shadowed'
  $gitId = @('-c', 'user.email=smoke@powbox.local', '-c', 'user.name=powbox smoke')
  & git -C $fixture @gitId add -A
  & git -C $fixture @gitId commit -q -m 'init'
  & docker volume create $wtVol *> $null

  # --- Container A ------------------------------------------------------------
  Write-Host "Container A - establish durable bind + create a dirty linked worktree"
  docker run @runArgs -v "${fixture}:${mount}" -v "${wtVol}:${mount}/.worktrees" --entrypoint /bin/bash $Image -c $setupScript powbox-wtmeta $mount $wtSlug $containerSlug
  $rc = $LASTEXITCODE
  if ($rc -eq 42) {
    Note-Skip "runtime cannot grant the mount privilege for the durable .git/worktrees bind"
    Write-Host "Worktree durable-metadata stage skipped: could not establish the durable bind (see the skip line above). The recreate lifecycle runs for real on a native-Linux CI runner."
    return
  }
  elseif ($rc -ne 0) { Fail "Container A could not set up the durable worktree (see the FAIL line above)" }

  # --- Host-side: created mountpoints inherited the tree's ownership (task 053) ---
  # shadow-mounts.sh only ever runs via sudo, so a mountpoint it has to CREATE is
  # created by ROOT. On a native-Linux bind mount that directory OUTLIVES the container
  # once the tmpfs/bind goes away, and if it is left root-owned mode-755 the host user
  # can afterwards neither populate nor remove it (e.g. a later host `dotnet build`
  # writing into bin/obj). Every created component must therefore inherit the uid:gid of
  # the deepest ancestor that already existed.
  #
  # The assertion runs HERE - on the host, after Container A exited - rather than inside
  # the container: the container's mount namespace died with it, so the tmpfs/bind is no
  # longer stacked on top and a plain stat sees the UNDERLYING directory. The
  # intermediate .claude - created but never a mountpoint - is asserted inside Container
  # A instead, where no unmount is needed either.
  #
  # Covered: proj/bin (ONE created component on the ORDINARY tmpfs path),
  # .claude/worktrees (TWO created components), and .git/worktrees (ONE created
  # component, but on the special durable-BIND branch, which reaches the mount through
  # bind_git_worktrees instead of the tmpfs line - a different path through the script,
  # so not a duplicate of the proj/bin case). NOT .worktrees - that mountpoint is created
  # by the container ENGINE for the named volume, never by shadow-mounts.sh, so it is
  # legitimately root-owned and is not evidence of anything.
  #
  # Three conditions would make these checks unable to fail, so a green would prove
  # nothing: a squashing filesystem (Windows/FUSE), a ROOTLESS engine (the container's
  # root maps to the invoker), and the smoke itself run as ROOT on the host. The first is
  # why this whole block is gated on $IsLinux rather than run tolerantly as the Bash
  # driver does (see NON-LINUX HOSTS in the header); the other two cannot be gated out -
  # they are legitimate ways to run - so they are detected and announced. Real teeth come
  # from an unprivileged host user on a rootful Linux engine: the native-Linux CI runner,
  # and a stock Linux desktop install.
  if (-not $IsLinux) {
    # $IsLinux is $null on Windows PowerShell 5.1, so this short-circuits there too.
    Note-Skip "mountpoint-ownership assertions skipped: host is not native Linux (a Windows/macOS bind mount squashes uid:gid, so they would pass vacuously)"
    Write-Host "  note: skipping the mountpoint-ownership assertions - this host is not native Linux, where uid:gid is squashed on the bind mount and the assertions would pass without proving anything. Run this stage on Linux for that coverage."
  }
  elseif (-not (Get-PathOwnerId $fixture)) {
    # Note-Skip, not a bare Write-Host: this is a genuine no-coverage case, so it belongs
    # in the umbrella banner rather than scrolling past in the log. It is a PARTIAL skip
    # (the rest of the stage still runs), and a later whole-stage Note-Skip legitimately
    # overwrites it, that being the more severe outcome. Practically unreachable - every
    # supported host has GNU or BSD stat - but silence here would be indistinguishable
    # from a real pass.
    Note-Skip "mountpoint-ownership assertions skipped: this host's stat supports neither 'stat -c' nor 'stat -f'"
    Write-Host "  note: skipping the mountpoint-ownership assertions - this host's stat supports neither 'stat -c' nor 'stat -f'."
  }
  else {
    # Say out loud when the assertions below cannot fail. Both notes are purely
    # informational: never a skip, never a failure - the engine may not answer, and a
    # vacuous pass is still a pass.
    $secOpts = ''
    try { $secOpts = (& docker info -f '{{.SecurityOptions}}' 2>$null) -join ' ' }
    catch { Write-Debug "docker info: $_" }
    if ($secOpts -match 'rootless') {
      Write-Host "  note: this container engine is ROOTLESS - the mountpoint-ownership assertions below are satisfied vacuously (the container's root maps to you, so an unchowned directory would still look invoker-owned). Real coverage comes from a rootful engine, e.g. the native-Linux CI runner."
    }
    if ((& id -u).Trim() -eq '0') {
      Write-Host "  note: this smoke is running as ROOT on the host - the whole fixture is root-owned, so the mountpoint-ownership assertions below are satisfied vacuously (ancestor and mountpoint are both root with or without the chown). Real coverage comes from an unprivileged host user."
    }
    Assert-CreatedMountpointOwner -Dir (Join-Path $fixture 'proj/bin') -Ancestor (Join-Path $fixture 'proj') -Label 'single created component, tmpfs path'
    Assert-CreatedMountpointOwner -Dir (Join-Path $fixture '.claude/worktrees') -Ancestor $fixture -Label 'multi-component creation'
    Assert-CreatedMountpointOwner -Dir (Join-Path $fixture '.git/worktrees') -Ancestor (Join-Path $fixture '.git') -Label 'single created component, durable-bind path'
  }

  # --- Container B (the recreate) ---------------------------------------------
  Write-Host "Container B - recreate on the SAME .worktrees volume + repo, assert survival"
  docker run @runArgs -v "${fixture}:${mount}" -v "${wtVol}:${mount}/.worktrees" --entrypoint /bin/bash $Image -c $verifyScript powbox-wtmeta $mount $wtSlug $containerSlug
  $rc = $LASTEXITCODE
  if ($rc -eq 42) {
    Note-Skip "runtime cannot grant the mount privilege for the durable .git/worktrees bind"
    Write-Host "Worktree durable-metadata stage skipped: could not re-establish the durable bind on recreate (see the skip line above)."
    return
  }
  elseif ($rc -ne 0) { Fail "the recycled worktree did not survive the container recreate (see the FAIL line above)" }

  # --- Host-side: no registration leaked onto the dir-mounted checkout --------
  # Inside the container the bind shadowed .git/worktrees, so every registration went
  # into the volume. On the host, shadow-mounts.sh mkdir'd the mountpoint before
  # binding, so an EMPTY .git/worktrees may exist - but it must hold NO worktree
  # registration (no <slug> subdir).
  $hostWt = Join-Path $fixture '.git/worktrees'
  if (Test-Path -LiteralPath $hostWt) {
    $leaked = Get-ChildItem -LiteralPath $hostWt -Force -ErrorAction SilentlyContinue
    if ($leaked) { Fail "the dir-mounted checkout's .git/worktrees leaked container registrations: $($leaked.Name -join ', ')" }
  }
  Write-Host "  ok: the host checkout's .git/worktrees gained no container registrations"

  Write-Host "Worktree durable-metadata smoke test passed (recreate lifecycle verified)."
}
finally {
  # The container may have left empty mountpoint dirs inside the fixture: proj/bin,
  # .claude/worktrees and .git/worktrees (created by shadow-mounts.sh, and - per the
  # ownership assertions above - expected to be invoker-owned) plus .worktrees (created
  # root-owned by the container ENGINE for the named volume). Remove-Item -Recurse
  # unlinks them when their PARENT is invoker-owned, which is what grants the unlink -
  # true for .git/worktrees and proj/bin (their parents pre-existed on the host) and for
  # .worktrees. It is NOT guaranteed for .claude/worktrees: the .claude parent is itself
  # container-created, so in exactly the regression case these assertions exist to catch
  # (the chown gone, both levels left root-owned) the removal fails and the fixture
  # tmpdir leaks. Cosmetic only - the run has already FAILED loudly by then, and the leak
  # is a bounded empty dir under the temp root. Best-effort either way: errors are
  # swallowed so cleanup never masks the real failure.
  if ($fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
  & docker volume rm -f $wtVol *> $null
}
