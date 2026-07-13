param(
  [string]$Image = "powbox-agent:latest"
)

# Smoke-test the DURABLE worktree-metadata lifecycle (task 017), behaviourally
# identical to scripts/smoke-test-worktree-metadata.sh. In dir-mounted mode a linked
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

# The in-container setup (Container A) and verify (Container B) scripts. Built with
# explicit LF joins (single-quoted lines so PowerShell leaves the shell $vars alone);
# a here-string would inherit this file's CRLF endings (*.ps1 is pinned to eol=crlf)
# and the stray ^M would break /bin/bash -c on a Windows checkout. Positional args:
# $1 = the dir-mounted repo, $2 = the per-worktree branch/slug, $3 = the container
# subdir under .worktrees. Exit codes: 0 = ok; 42 = self-skip, emitted ONLY by the
# independent capability preflight (no bind-mount capability / no persistent
# .worktrees volume); any OTHER non-zero = genuine failure, INCLUDING a durable-bind
# regression detected after the preflight proved the runtime can mount.
$setupScript = @(
  'set -u'
  'WS="$1"'
  'SLUG="$2"'
  'CONT="$3"'
  'export HOME=/root'
  '# The fixture is created on the host; inside the container we touch it as root, so'
  '# silence git dubious-ownership on the borrowed checkout (a throwaway smoke fixture).'
  'git config --global --add safe.directory "*" >/dev/null 2>&1 || true'
  '# Independent mount-capability PREFLIGHT (does NOT touch shadow-mounts.sh /'
  '# bind_git_worktrees): a throwaway temp-over-temp mount --bind with the same cap'
  '# wiring. ONLY its failure is a legitimate skip (exit 42), so a regression in the'
  '# durable bind can no longer masquerade as a missing capability.'
  'pfsrc="$(mktemp -d)"'
  'pfdst="$(mktemp -d)"'
  'if ! mount --bind "$pfsrc" "$pfdst" 2>/dev/null; then'
  '  echo "  skip: runtime cannot perform mount --bind (no CAP_SYS_ADMIN / EPERM) - the durable-bind lifecycle cannot be exercised here"'
  '  rmdir "$pfdst" "$pfsrc" 2>/dev/null || true'
  '  exit 42'
  'fi'
  'umount "$pfdst" 2>/dev/null || umount -l "$pfdst" 2>/dev/null || true'
  'rmdir "$pfdst" "$pfsrc" 2>/dev/null || true'
  '# The persistent .worktrees volume must genuinely be mounted; otherwise there is'
  '# nothing durable to co-locate into (a legit skip). The outer driver always mounts it.'
  'if ! mountpoint -q "$WS/.worktrees"; then'
  '  echo "  skip: the persistent .worktrees volume is not mounted at $WS/.worktrees - nothing durable to exercise"'
  '  exit 42'
  'fi'
  'echo "  ok: mount capability confirmed and the persistent .worktrees volume is present (preflight)"'
  '# Capability + volume are established. From HERE any failure to materialize the durable'
  '# bind is a REGRESSION and a HARD FAILURE (exit 1, NOT a skip) - the case this stage'
  '# exists to catch. Establish the bind exactly as the entrypoint does.'
  'smerr="$(mktemp)"'
  'if ! /usr/local/bin/shadow-mounts.sh "$WS/.git/worktrees" 2>"$smerr"; then'
  '  echo "FAIL: shadow-mounts.sh failed to establish the durable bind despite mount capability being present - durable-bind REGRESSION" >&2'
  '  sed "s/^/    shadow-mounts: /" "$smerr" >&2 || true'
  '  exit 1'
  'fi'
  'if ! mountpoint -q "$WS/.git/worktrees"; then'
  '  echo "FAIL: .git/worktrees is not a mountpoint after shadow-mounts.sh - the durable bind did not materialize (REGRESSION)" >&2'
  '  exit 1'
  'fi'
  '# A tmpfs here means shadow-mounts.sh fell back instead of binding the persistent'
  '# volume - a regression now that capability + volume are both proven present.'
  'fstype="$(findmnt -nro FSTYPE -T "$WS/.git/worktrees" 2>/dev/null || true)"'
  'if [ "$fstype" = tmpfs ]; then'
  '  echo "FAIL: durable bind fell back to tmpfs despite the persistent .worktrees volume being present - durable-bind REGRESSION" >&2'
  '  exit 1'
  'fi'
  '# Prove the bind maps .git/worktrees onto the volume .gitworktrees dir (not merely'
  '# onto some non-tmpfs fs): a sentinel written on the volume side must be visible'
  '# through .git/worktrees; a mismatch means the bind points at the wrong source.'
  'probe=".bindprobe.$$"'
  'if ! : >"$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null; then'
  '  echo "FAIL: cannot write into the volume .gitworktrees dir to verify the durable bind (REGRESSION)" >&2'
  '  exit 1'
  'fi'
  'if [ ! -e "$WS/.git/worktrees/$probe" ]; then'
  '  rm -f "$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null || true'
  '  echo "FAIL: .git/worktrees does not reflect the volume .gitworktrees dir - durable bind maps the wrong source (REGRESSION)" >&2'
  '  exit 1'
  'fi'
  'rm -f "$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null || true'
  'echo "  ok: durable .git/worktrees bind established from the persistent .worktrees volume (verified maps .gitworktrees)"'
  'WTDIR="$WS/.worktrees/$CONT/$SLUG"'
  'if ! git -C "$WS" worktree add -q "$WTDIR" -b "$SLUG" >/dev/null 2>&1; then'
  '  echo "FAIL: git worktree add failed while creating the linked worktree" >&2'
  '  git -C "$WS" worktree add "$WTDIR" -b "$SLUG" >&2 || true'
  '  exit 1'
  'fi'
  '# The admin metadata must have landed in the durable volume (via the bind).'
  'if [ ! -e "$WS/.worktrees/.gitworktrees/$SLUG/gitdir" ]; then'
  '  echo "FAIL: worktree metadata did not land in the durable volume (.worktrees/.gitworktrees/$SLUG missing)" >&2'
  '  exit 1'
  'fi'
  '# Leave the worktree DIRTY: a tracked modification AND an untracked new file.'
  'echo "durable-change-A" >>"$WTDIR/tracked.txt"'
  'echo "untracked-content-A" >"$WTDIR/UNTRACKED_NEW.txt"'
  'echo "  ok: linked worktree created and left dirty (tracked mod + untracked file)"'
  'exit 0'
) -join "`n"

$verifyScript = @(
  'set -u'
  'WS="$1"'
  'SLUG="$2"'
  'CONT="$3"'
  'export HOME=/root'
  'git config --global --add safe.directory "*" >/dev/null 2>&1 || true'
  '# Independent mount-capability PREFLIGHT (see Container A): only its failure is a'
  '# legitimate skip. Once it passes, a bind that does not re-materialize on recreate is'
  '# a durable-bind REGRESSION and a HARD FAILURE, never a skip.'
  'pfsrc="$(mktemp -d)"'
  'pfdst="$(mktemp -d)"'
  'if ! mount --bind "$pfsrc" "$pfdst" 2>/dev/null; then'
  '  echo "  skip: runtime cannot perform mount --bind (no CAP_SYS_ADMIN / EPERM) - the recreate lifecycle cannot be exercised here"'
  '  rmdir "$pfdst" "$pfsrc" 2>/dev/null || true'
  '  exit 42'
  'fi'
  'umount "$pfdst" 2>/dev/null || umount -l "$pfdst" 2>/dev/null || true'
  'rmdir "$pfdst" "$pfsrc" 2>/dev/null || true'
  'if ! mountpoint -q "$WS/.worktrees"; then'
  '  echo "  skip: the persistent .worktrees volume is not mounted at $WS/.worktrees - nothing durable to exercise"'
  '  exit 42'
  'fi'
  '# Re-establish the durable bind, as the entrypoint would on the recreated container.'
  '# Capability is proven, so any failure here is a REGRESSION (hard failure, NOT skip).'
  'smerr="$(mktemp)"'
  'if ! /usr/local/bin/shadow-mounts.sh "$WS/.git/worktrees" 2>"$smerr"; then'
  '  echo "FAIL: shadow-mounts.sh failed to re-establish the durable bind on recreate despite mount capability - durable-bind REGRESSION" >&2'
  '  sed "s/^/    shadow-mounts: /" "$smerr" >&2 || true'
  '  exit 1'
  'fi'
  'if ! mountpoint -q "$WS/.git/worktrees"; then'
  '  echo "FAIL: durable bind not re-established on recreate (.git/worktrees is not a mountpoint) - REGRESSION" >&2'
  '  exit 1'
  'fi'
  'fstype="$(findmnt -nro FSTYPE -T "$WS/.git/worktrees" 2>/dev/null || true)"'
  'if [ "$fstype" = tmpfs ]; then'
  '  echo "FAIL: durable bind fell back to tmpfs on recreate despite the persistent .worktrees volume being present - REGRESSION" >&2'
  '  exit 1'
  'fi'
  '# Symmetrical with Container A (defense in depth): prove the RE-established bind maps'
  '# .git/worktrees onto the volume .gitworktrees dir (not merely onto some non-tmpfs'
  '# fs). A fresh sentinel written on the volume side must be visible through'
  '# .git/worktrees; a mismatch means the recreate bind points at the wrong source, so'
  '# the recreate side also fails closed on bind-source, never a skip.'
  'probe=".bindprobe.$$"'
  'if ! : >"$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null; then'
  '  echo "FAIL: cannot write into the volume .gitworktrees dir to verify the recreate bind (REGRESSION)" >&2'
  '  exit 1'
  'fi'
  'if [ ! -e "$WS/.git/worktrees/$probe" ]; then'
  '  rm -f "$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null || true'
  '  echo "FAIL: .git/worktrees does not reflect the volume .gitworktrees dir on recreate - bind maps the wrong source (REGRESSION)" >&2'
  '  exit 1'
  'fi'
  'rm -f "$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null || true'
  'echo "  ok: recreate .git/worktrees bind maps the persistent .worktrees volume (verified maps .gitworktrees)"'
  'WTDIR="$WS/.worktrees/$CONT/$SLUG"'
  '[ -d "$WTDIR" ] || { echo "FAIL: the linked worktree dir did not survive recreation ($WTDIR missing)" >&2; exit 1; }'
  '# 1. Metadata survived: git status works, and the admin dir is visible via the bind.'
  'if ! git -C "$WTDIR" status >/dev/null 2>&1; then'
  '  echo "FAIL: git status failed in the recycled worktree - per-worktree metadata did not survive recreation" >&2'
  '  git -C "$WTDIR" status >&2 2>&1 || true'
  '  exit 1'
  'fi'
  '[ -e "$WS/.git/worktrees/$SLUG/gitdir" ] || { echo "FAIL: .git/worktrees/$SLUG metadata not visible after recreate (bind broken?)" >&2; exit 1; }'
  'echo "  ok: git status works in the recycled worktree; per-worktree metadata survived recreate"'
  '# 2. HEAD is still on the worktree branch.'
  'br="$(git -C "$WTDIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"'
  '[ "$br" = "$SLUG" ] || { echo "FAIL: recycled worktree HEAD is $br, expected $SLUG" >&2; exit 1; }'
  '# 3. The tracked modification survived (working-tree file lives in the volume).'
  'status="$(git -C "$WTDIR" status --porcelain 2>/dev/null || true)"'
  'printf "%s\n" "$status" | grep -qE "^.M[[:space:]]+tracked\.txt$" || {'
  '  echo "FAIL: the tracked modification to tracked.txt did not survive recreation. git status --porcelain:" >&2'
  '  printf "%s\n" "$status" >&2'
  '  exit 1'
  '}'
  'grep -q "durable-change-A" "$WTDIR/tracked.txt" || { echo "FAIL: tracked.txt content lost after recreation" >&2; exit 1; }'
  '# 4. The untracked file survived.'
  'printf "%s\n" "$status" | grep -qE "^\?\?[[:space:]]+UNTRACKED_NEW\.txt$" || {'
  '  echo "FAIL: the untracked file UNTRACKED_NEW.txt did not survive recreation. git status --porcelain:" >&2'
  '  printf "%s\n" "$status" >&2'
  '  exit 1'
  '}'
  '[ -f "$WTDIR/UNTRACKED_NEW.txt" ] || { echo "FAIL: UNTRACKED_NEW.txt is gone after recreation" >&2; exit 1; }'
  'grep -q "untracked-content-A" "$WTDIR/UNTRACKED_NEW.txt" || { echo "FAIL: UNTRACKED_NEW.txt content lost after recreation" >&2; exit 1; }'
  'echo "  ok: HEAD on $SLUG; tracked modification + untracked file both survived the container recreate"'
  'exit 0'
) -join "`n"

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
  # The container (root) may have left an empty, root-owned .git/worktrees /
  # .worktrees mountpoint dir inside the fixture; Remove-Item -Recurse unlinks them
  # (their user-owned parent grants the unlink on Linux). Best-effort either way.
  if ($fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
  & docker volume rm -f $wtVol *> $null
}
