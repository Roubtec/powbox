param(
  [string]$Image = "powbox-agent:latest"
)

# Smoke-test the native-Linux dir-mount ownership fix (PR #55) and its mixed-ownership
# extension (task 007). Two cases run: an all-root-owned mount (PR #55) and a node-owned
# root that hides nested root-owned files left by a host `sudo git pull` (task 007).
#
# On a NATIVE-LINUX host a bind-mounted repo keeps its host uid/gid. When that is
# root (a repo under /root, or a host running powbox as root) the mount is
# root:root inside the container and the `node` agent (uid 1000) cannot write the
# working tree or .git - every touch/git pull/git commit fails with EACCES
# (`cannot open '.git/FETCH_HEAD': Permission denied`). A subtler variant: a host
# operation that runs as root against a live bind mount (most often `sudo git pull`)
# re-owns to uid 0 only the paths it writes (new .git/objects/*, refs, changed
# working-tree files), leaving the node-owned top dir but nested root-owned files that
# block `git commit` with `insufficient permission for adding an object to repository
# database`. entrypoint-core.sh probes
# write access as node and, for any workspace it cannot write, runs the
# sudo-allowlisted root helper /usr/local/bin/fix-workspace-perms.sh, which chowns
# a root-owned tree to node. Windows/WSL/macOS bind mounts honour node's writes
# regardless of the displayed owner, so the bug - and this guard - is native-Linux
# only. A regression (entrypoint reorder, a dropped sudoers entry, a renamed
# helper) would silently re-break every native-Linux host whose repo is not
# uid-1000-owned; this stage is the automated guard.
#
# Like scripts/smoke-test-selfhosted.ps1's Stage B, this validates the baked helper
# + its sudoers wiring in isolation (it invokes /usr/local/bin/fix-workspace-perms.sh
# by the exact path and sudo mechanism entrypoint-core.sh uses), not the full
# entrypoint chain.
#
# Self-skips (no failure) when it cannot meaningfully run: the agent image is
# absent (unless POWBOX_SMOKE_REQUIRE_IMAGE is set, then it fails); the host is not
# native Linux (Windows/macOS bind mounts mask the bug); it cannot create a
# root-owned fixture (no root / no passwordless sudo - the local-dev case; CI runs
# it for real); or the host masks the native-Linux uid bug.

$ErrorActionPreference = "Stop"

# A constant in-container mount point. Each case runs its own --rm container, so
# the path never collides; the host-side fixture dir is always a unique mktemp.
$mount = "/workspace/powbox-dirmount-smoke"

function Fail([string]$m) { Write-Error "FAIL: $m"; exit 1 }

# Record a runtime self-skip reason for the umbrella banner. The stage still
# returns success on a self-skip, so commands/smoke-test.ps1 cannot tell a real
# pass from a skip on its own; it passes POWBOX_SMOKE_SKIP_MARKER and we write the
# reason there. A no-op when unset, so direct callers keep the plain success
# contract.
function Note-Skip([string]$Reason) {
  if ($env:POWBOX_SMOKE_SKIP_MARKER) {
    Set-Content -LiteralPath $env:POWBOX_SMOKE_SKIP_MARKER -Value $Reason -NoNewline
  }
}

Write-Host "Dir-mount ownership smoke test (image: $Image)"

# --- image gate (mirrors smoke-test-selfhosted.ps1) ---------------------------
docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) {
  if ($env:POWBOX_SMOKE_REQUIRE_IMAGE) {
    throw "image '$Image' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set - the dir-mount ownership stage requires the image."
  }
  Note-Skip "image '$Image' not found"
  Write-Host "Dir-mount stage skipped: image '$Image' not found (build it to exercise the fix-workspace-perms.sh chown path)."
  return
}

# --- native-Linux gate --------------------------------------------------------
# The bug only manifests on a native-Linux bind mount. Windows/macOS bind mounts
# honour node's writes regardless of the displayed owner, and the POSIX tooling
# below (id/sudo/chown/stat/mktemp) is Linux-only anyway. $IsLinux is $null on
# Windows PowerShell 5.1, so this also short-circuits there.
if (-not $IsLinux) {
  Note-Skip "host is not native Linux"
  Write-Host "Dir-mount stage skipped: the native-Linux bind-mount uid bug does not manifest on this OS (Windows/macOS bind mounts honour node's writes)."
  return
}

# --- root-capability gate -----------------------------------------------------
# Creating a genuinely root-owned fixture needs root. Already-root needs no
# prefix; otherwise general passwordless sudo (a CI runner) works. powbox's own
# dev container scopes node's sudo to a few allowlisted helpers, so `sudo -n true`
# is denied there and the stage self-skips instead of failing.
$script:rootPrefix = @()
$canRoot = $false
if ((& id -u).Trim() -eq '0') {
  $canRoot = $true
}
elseif (Get-Command sudo -ErrorAction SilentlyContinue) {
  & sudo -n true 2>$null
  if ($LASTEXITCODE -eq 0) { $script:rootPrefix = @('sudo'); $canRoot = $true }
}
if (-not $canRoot) {
  Note-Skip "no root / passwordless sudo to build a root-owned fixture"
  Write-Host "Dir-mount stage skipped: cannot create a root-owned fixture here (need root or passwordless sudo, e.g. a CI runner)."
  Write-Host "  Locally this is expected - the native-Linux root-owned-mount bug only reproduces where a root-owned path can be made. In CI (task 003) this stage runs for real."
  return
}

# Run a command as root, prefixing sudo only when we are not already root.
function Invoke-AsRoot {
  param([Parameter(Mandatory)][string[]]$Argument)
  $all = @($script:rootPrefix) + $Argument
  $exe = $all[0]
  # Guard the slice: with a single element, $all[1..0] indexes in reverse and
  # re-includes $exe; an empty $rest is the correct "no extra args" case.
  $rest = if ($all.Count -gt 1) { @($all[1..($all.Count - 1)]) } else { @() }
  & $exe @rest
}

# The in-container assertion, run AS node - pinned with `--user node` on the docker
# run below (not merely the image default), so a USER regression in the image
# cannot quietly run this as root and mask the bug. Built with explicit LF joins
# (single-quoted lines so PowerShell leaves the shell $vars alone); a here-string
# would inherit this file's CRLF endings (*.ps1 is pinned to eol=crlf) and the
# stray ^M would break /bin/bash -c on a Windows checkout. It takes the mount path
# as $1 and signals back via exit code: 0 passed, 42 masked (node could already
# write -> self-skip), other = genuine failure.
$assertScript = @(
  'set -u'
  'WS="$1"'
  '# Only meaningful as the node agent (uid 1000); hard-FAIL (not a masked skip) if not.'
  'if [ "$(id -u)" != "1000" ]; then'
  '  echo "FAIL: dir-mount assertion not running as node (uid 1000) - got uid $(id -u)" >&2'
  '  exit 1'
  'fi'
  'if probe="$(mktemp "${WS}/.powbox-dirmount-probe.XXXXXX" 2>/dev/null)"; then'
  '  rm -f "$probe" 2>/dev/null || true'
  '  echo "  skip: node can already write the root-owned mount (this host masks the native-Linux uid bug)"'
  '  exit 42'
  'fi'
  'echo "  ok: node cannot write the root-owned mount before the fix (genuinely root-owned, EACCES as expected)"'
  'if ! sudo /usr/local/bin/fix-workspace-perms.sh "$WS"; then'
  '  echo "FAIL: sudo fix-workspace-perms.sh failed (dropped sudoers entry or renamed/missing helper?)" >&2'
  '  exit 1'
  'fi'
  'if ! touch "${WS}/smoke-write" 2>/dev/null; then'
  '  echo "FAIL: node still cannot write the tree after the fix (cannot open: Permission denied)" >&2'
  '  exit 1'
  'fi'
  '# node must also be able to MODIFY a pre-existing working-tree file, not just create new ones:'
  '# a regression that chowns only the workspace root + .git would leave existing files root-owned.'
  'if ! printf "smoke edit\n" >>"${WS}/README.md" 2>/dev/null; then'
  '  echo "FAIL: node cannot modify the pre-existing root-owned README.md after the fix (working-tree contents still not writable)" >&2'
  '  exit 1'
  'fi'
  'if ! git -C "$WS" -c user.email=smoke@powbox.local -c user.name="powbox smoke" commit --allow-empty -m "powbox dirmount smoke" >/dev/null 2>&1; then'
  '  echo "FAIL: node git commit failed after the fix (.git still not writable by node?)" >&2'
  '  exit 1'
  'fi'
  'for f in smoke-write README.md; do'
  '  owner="$(stat -c %u "${WS}/${f}" 2>/dev/null || echo "?")"'
  '  if [ "$owner" != "1000" ]; then'
  '    echo "FAIL: ${f} owned by uid ${owner} after the fix, expected node (1000)" >&2'
  '    exit 1'
  '  fi'
  'done'
  'echo "  ok: node can touch + modify existing files + git-commit after the fix, and the tree is node-owned (uid 1000)"'
  'exit 0'
) -join "`n"

# The mixed-ownership in-container assertion (task 007), behaviourally identical to the
# .sh ASSERT_SCRIPT_MIXED. The fixture ROOT is node-owned but hides nested root-owned
# entries (a tracked working-tree file + a .git/objects/<xx> shard), as a host `sudo git
# pull` leaves. The node-owned root means the root-level write probe would PASS, so this
# probes the nested root-owned tracked file instead. Same exit contract: 0 passed, 42
# masked (node could already write -> self-skip), other = genuine failure.
$assertScriptMixed = @(
  'set -u'
  'WS="$1"'
  'NESTED="${WS}/nested.txt"'
  'if echo masked 2>/dev/null >>"$NESTED"; then'
  '  echo "  skip: node can already write the nested root-owned file (this host masks the native-Linux uid bug)"'
  '  exit 42'
  'fi'
  'echo "  ok: node cannot write the nested root-owned tracked file before the fix (EACCES as expected)"'
  'if ! sudo /usr/local/bin/fix-workspace-perms.sh "$WS"; then'
  '  echo "FAIL: sudo fix-workspace-perms.sh did not self-heal the node-owned root with nested root-owned files (007 helper node-owned-root path reverted, or dropped sudoers entry?)" >&2'
  '  exit 1'
  'fi'
  'if ! echo healed >>"$NESTED" 2>/dev/null; then'
  '  echo "FAIL: node still cannot write the nested file after the fix (nested root-owned entry not re-owned)" >&2'
  '  exit 1'
  'fi'
  'if ! git -C "$WS" -c user.email=smoke@powbox.local -c user.name="powbox smoke" commit -aqm "powbox dirmount mixed smoke" >/dev/null 2>&1; then'
  '  echo "FAIL: node git commit failed after the fix (.git/objects shard still root-owned?)" >&2'
  '  exit 1'
  'fi'
  'remaining="$(find "$WS" -uid 0 -print -quit 2>/dev/null || true)"'
  'if [ -n "$remaining" ]; then'
  '  echo "FAIL: a root-owned entry survived the fix: $remaining" >&2'
  '  exit 1'
  'fi'
  'echo "  ok: nested root-owned file + .git/objects shard re-owned to node; edit + git-commit succeed"'
  'exit 0'
) -join "`n"

$fixtures = New-Object System.Collections.Generic.List[string]
$masked = $false
$passed = 0
try {
  # === Case: all-root-owned mount =============================================
  # The reported and overwhelmingly common case: a repo under /root, so the WHOLE
  # tree is root:root inside the container and node cannot write any of it. This
  # is 005's acceptance case and ships green on its own.
  $fixture = (& mktemp -d "/tmp/powbox-dirmount-XXXXXX").Trim()
  $fixtures.Add($fixture)
  & git -C $fixture init -q
  Set-Content -LiteralPath (Join-Path $fixture 'README.md') -Value 'powbox dir-mount ownership smoke fixture'
  Invoke-AsRoot @('chown', '-R', 'root:root', $fixture)
  Write-Host "Case: all-root-owned mount (a repo under /root; root:root inside the container)"
  docker run --rm --user node -v "${fixture}:${mount}" --entrypoint /bin/bash $Image -c $assertScript powbox-dirmount $mount
  $rc = $LASTEXITCODE
  if ($rc -eq 0) {
    # Host-side: the helper claimed the tree for node end to end. stat as root -
    # the chowned fixture (mktemp -d is mode 700) may not be traversable by a
    # non-owner sudo caller.
    $hostOwner = (Invoke-AsRoot @('stat', '-c', '%u', (Join-Path $fixture 'smoke-write'))).Trim()
    if ($hostOwner -ne '1000') { Fail "host-side smoke-write owned by uid $hostOwner, expected node (1000)" }
    Write-Host "  ok: host-side file is node-owned (uid 1000) after the run"
    $passed++
  }
  elseif ($rc -eq 42) { $masked = $true }
  else { Fail "node could not write the dir-mounted tree after the fix-workspace-perms.sh fix (see the FAIL line above)" }

  # === Case: mixed-ownership mount (task 007) =================================
  # The case 005 left as a seam: a node-owned repo ROOT that hides nested root-owned
  # files (a tracked working-tree file + a .git/objects/<xx> shard chowned to root),
  # exactly what a host `sudo git pull` against a live bind mount leaves behind. 005's
  # root-level write probe sees a node-owned root and passes, so this case is RED until
  # 007's entrypoint nested-uid-0 detection + the helper's node-owned-root path land.
  # Mirrors case_mixed_ownership in the .sh: root stays node-owned; only nested entries
  # go to root; its own probe + assertion ($assertScriptMixed).
  $mfixture = (& mktemp -d "/tmp/powbox-dirmount-XXXXXX").Trim()
  $fixtures.Add($mfixture)
  & git -C $mfixture init -q
  Set-Content -LiteralPath (Join-Path $mfixture 'README.md') -Value 'powbox dir-mount ownership smoke fixture'
  # Build real history so .git/objects holds shard dirs, plus a tracked file to root-own.
  $gitId = @('-c', 'user.email=smoke@powbox.local', '-c', 'user.name=powbox smoke')
  & git -C $mfixture @gitId add -A
  & git -C $mfixture @gitId commit -q -m 'initial'
  Set-Content -LiteralPath (Join-Path $mfixture 'nested.txt') -Value 'tracked nested file'
  & git -C $mfixture @gitId add nested.txt
  & git -C $mfixture @gitId commit -q -m 'add nested file'
  # Locate the .git/objects/<xx> shard to root-own BEFORE chowning the tree to node:
  # mktemp -d gives a mode-700 root owned by the invoking user, so once `chown -R
  # 1000:1000` runs, a passwordless-sudo runner whose uid is not 1000 could no longer
  # traverse it (the unprivileged find would see nothing). The captured path stays
  # valid across the chown.
  $shard = & find (Join-Path $mfixture '.git/objects') -mindepth 1 -maxdepth 1 -type d -name '??' |
  Select-Object -First 1
  if (-not $shard) { Fail 'mixed-ownership fixture has no .git/objects/<xx> shard dir to root-own' }
  # Force the mixed shape regardless of who runs the stage: node-owned ROOT, then
  # root-owned ONLY the paths a host `sudo git pull` rewrites (a tracked file + one
  # .git/objects/<xx> shard). chown the whole tree to node first, then plant the
  # nested root-owned entries.
  Invoke-AsRoot @('chown', '-R', '1000:1000', $mfixture)
  Invoke-AsRoot @('chown', '0:0', (Join-Path $mfixture 'nested.txt'))
  Invoke-AsRoot @('chown', '-R', '0:0', $shard)
  Write-Host "Case: mixed-ownership mount (node-owned root + nested root-owned tracked file & .git/objects/<xx> shard, as from a host 'sudo git pull')"
  docker run --rm -v "${mfixture}:${mount}" --entrypoint /bin/bash $Image -c $assertScriptMixed powbox-dirmount $mount
  $rc = $LASTEXITCODE
  if ($rc -eq 0) {
    # Host-side: stat as root - the chowned fixture (mktemp -d is mode 700) may not be
    # traversable by a non-owner sudo caller.
    $hostOwner = (Invoke-AsRoot @('stat', '-c', '%u', (Join-Path $mfixture 'nested.txt'))).Trim()
    if ($hostOwner -ne '1000') { Fail "host-side nested.txt owned by uid $hostOwner, expected node (1000)" }
    Write-Host "  ok: host-side nested.txt is node-owned (uid 1000) after the run"
    $passed++
  }
  elseif ($rc -eq 42) { $masked = $true }
  else { Fail "node could not write the mixed-ownership tree after the entrypoint fix (see the FAIL line above)" }
}
finally {
  foreach ($f in $fixtures) {
    if ($f) { Invoke-AsRoot @('rm', '-rf', $f) 2>$null | Out-Null }
  }
}

if ($masked) {
  Note-Skip "host masks the native-Linux uid bug (node could already write the root-owned mount)"
  Write-Host "Dir-mount stage skipped: this host masks the native-Linux bind-mount uid bug (node could already write the root-owned mount). Nothing to assert."
  return
}

Write-Host "Dir-mount ownership smoke test passed ($passed case(s))."
