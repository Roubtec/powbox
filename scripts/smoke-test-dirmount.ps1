param(
  [string]$Image = "powbox-agent:latest"
)

# Smoke-test the native-Linux dir-mount ownership fix (PR #55).
#
# On a NATIVE-LINUX host a bind-mounted repo keeps its host uid/gid. When that is
# root (a repo under /root, or a host running powbox as root) the mount is
# root:root inside the container and the `node` agent (uid 1000) cannot write the
# working tree or .git - every touch/git pull/git commit fails with EACCES
# (`cannot open '.git/FETCH_HEAD': Permission denied`). entrypoint-core.sh probes
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

Write-Host "Dir-mount ownership smoke test (image: $Image)"

# --- image gate (mirrors smoke-test-selfhosted.ps1) ---------------------------
docker image inspect $Image *> $null
if ($LASTEXITCODE -ne 0) {
  if ($env:POWBOX_SMOKE_REQUIRE_IMAGE) {
    throw "image '$Image' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set - the dir-mount ownership stage requires the image."
  }
  Write-Host "Dir-mount stage skipped: image '$Image' not found (build it to exercise the entrypoint chown path)."
  return
}

# --- native-Linux gate --------------------------------------------------------
# The bug only manifests on a native-Linux bind mount. Windows/macOS bind mounts
# honour node's writes regardless of the displayed owner, and the POSIX tooling
# below (id/sudo/chown/stat/mktemp) is Linux-only anyway. $IsLinux is $null on
# Windows PowerShell 5.1, so this also short-circuits there.
if (-not $IsLinux) {
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
  Write-Host "Dir-mount stage skipped: cannot create a root-owned fixture here (need root or passwordless sudo, e.g. a CI runner)."
  Write-Host "  Locally this is expected - the native-Linux root-owned-mount bug only reproduces where a root-owned path can be made. In CI (task 003) this stage runs for real."
  return
}

# Run a command as root, prefixing sudo only when we are not already root.
function Invoke-AsRoot {
  param([Parameter(Mandatory)][string[]]$Argument)
  $all = @($script:rootPrefix) + $Argument
  $exe = $all[0]
  $rest = @($all[1..($all.Count - 1)])
  & $exe @rest
}

# The in-container assertion, run AS node against the bind-mounted fixture. Built
# with explicit LF joins (single-quoted lines so PowerShell leaves the shell $vars
# alone); a here-string would inherit this file's CRLF endings (*.ps1 is pinned to
# eol=crlf) and the stray ^M would break /bin/bash -c on a Windows checkout. It
# takes the mount path as $1 and signals back via exit code: 0 passed, 42 masked
# (node could already write -> self-skip), other = genuine failure.
$assertScript = @(
  'set -u'
  'WS="$1"'
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
  'if ! git -C "$WS" -c user.email=smoke@powbox.local -c user.name="powbox smoke" commit --allow-empty -m "powbox dirmount smoke" >/dev/null 2>&1; then'
  '  echo "FAIL: node git commit failed after the fix (.git still not writable by node?)" >&2'
  '  exit 1'
  'fi'
  'owner="$(stat -c %u "${WS}/smoke-write" 2>/dev/null || echo "?")"'
  'if [ "$owner" != "1000" ]; then'
  '  echo "FAIL: smoke-write owned by uid ${owner} after the fix, expected node (1000)" >&2'
  '  exit 1'
  'fi'
  'echo "  ok: node can touch + git-commit after the fix, and the tree is node-owned (uid 1000)"'
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
  docker run --rm -v "${fixture}:${mount}" --entrypoint /bin/bash $Image -c $assertScript powbox-dirmount $mount
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
  else { Fail "node could not write the dir-mounted tree after the entrypoint fix (see the FAIL line above)" }

  # -- Task 007 extension seam ----------------------------------------------
  # Task 007 adds a SECOND case here - "mixed-ownership": a node-owned repo ROOT
  # with nested root-owned files (a tracked file plus a .git/objects/<xx> dir
  # chowned to root, simulating a host `sudo git pull`). It reuses mktemp / git /
  # Invoke-AsRoot / $assertScript above but mutates ownership differently (leave
  # the root node-owned; chown only the nested entries) and needs its own
  # self-heal step + assertion. It is RED until 007's self-heal logic lands -
  # 005's root-level write probe sees a node-owned root, writes succeed, and the
  # nested root-owned files are missed - so it is deliberately NOT wired here.
  # Task 007 owns delivering and gating that case. DO NOT enable it as part of 005.
}
finally {
  foreach ($f in $fixtures) {
    if ($f) { Invoke-AsRoot @('rm', '-rf', $f) 2>$null | Out-Null }
  }
}

if ($masked) {
  Write-Host "Dir-mount stage skipped: this host masks the native-Linux bind-mount uid bug (node could already write the root-owned mount). Nothing to assert."
  return
}

Write-Host "Dir-mount ownership smoke test passed ($passed case(s))."
