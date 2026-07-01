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
# BOTH cases drive the GENUINE extracted entrypoint decision unit
# /usr/local/bin/heal-workspace-perms.sh - the byte-for-byte code entrypoint-core.sh runs:
# its node write-probe + nested-uid-0 scan decide whether and with what path/sudo to call
# fix-workspace-perms.sh. So they guard the probe-and-call DECISION path, not only the helper,
# and a regression confined to that decision logic (probe stops detecting the unwritable
# mount, workspace never handed to the helper) is caught here. Because the unit ultimately
# invokes /usr/local/bin/fix-workspace-perms.sh by the exact path + sudo mechanism the
# entrypoint uses, the in-isolation helper + sudoers-wiring coverage is preserved (subsumed),
# not lost. It still does NOT boot the full entrypoint chain (the firewall/gh/shadow setup
# needs the launcher's compose wiring and is out of scope here). The all-root case exercises
# the unit's root-level write probe; the mixed-ownership case (node-owned root + nested uid-0
# entries) exercises the unit's nested-uid-0 DETECTION scan - the production trigger task 007
# added that the root-level probe misses - so reverting ONLY that scan now fails the smoke
# (task 007a).
#
# Four further cases guard the SENSITIVE-SOURCE refusal (the VPS-lockout incident: a cc/cx
# accidentally run from ~ would bind-mount the whole home tree and the heal would chown it to
# node, breaking sshd StrictModes on ~/.ssh and locking the user out of the host):
#   * sensitive-skip - a root-owned fixture launched with POWBOX_WORKSPACE_HOST_PATH=/root and
#     POWBOX_WORKSPACE_DIR=<mount>, so the real heal unit must SKIP the chown and warn (tree
#     stays root-owned) via the launcher-env fallback consulted when no marker is recorded.
#   * fix-mountinfo-backstop - a read-only bind of the host /etc, so fix-workspace-perms.sh (the
#     privileged boundary, run under sudo with env stripped) must refuse via the
#     /proc/self/mountinfo FALLBACK source when no marker is recorded.
#   * fix-true-source (task 009 Gap A) - a root-owned fixture whose mountinfo source is
#     non-sensitive but whose recorded marker true source is /home/alice, so fix must refuse via
#     the marker (which survives sudo env_reset) where the mountinfo-only backstop would have
#     chowned it. Fails if 009 is reverted.
#   * heal-true-source (task 009 Gap B) - a root-owned fixture whose marker true source is a safe
#     /projects while a deliberately sensitive env (/root) is also passed, so the heal must HEAL
#     (marker authoritative) rather than skip on the sensitive env / a degenerate mountinfo `/`.
#     Fails if 009 is reverted.
# The pure predicate + mountinfo parser are also unit-tested by scripts/test-sensitive-host-path.sh.
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
  '# 2. Drive the REAL entrypoint decision unit heal-workspace-perms.sh - the exact code'
  '#    entrypoint-core.sh runs (its node write-probe + nested-uid-0 scan decide whether and'
  '#    with what path/sudo to call fix-workspace-perms.sh). Run as node, NOT via sudo (the'
  '#    unit runs sudo for the inner chown itself). This replaces the former direct sudo'
  '#    fix-workspace-perms.sh call but PRESERVES its coverage: the unit still invokes that'
  '#    helper by the same allowlisted path/sudo mechanism. A probe/decision regression'
  '#    leaves the tree root-owned and surfaces at steps 3-5 below as EACCES.'
  'if ! /usr/local/bin/heal-workspace-perms.sh; then'
  '  echo "FAIL: the real entrypoint heal unit (heal-workspace-perms.sh) errored (missing, non-executable, or a probe/scan fault); a fix-workspace-perms.sh helper/sudoers regression instead surfaces at the write/commit steps below" >&2'
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
# pull` leaves. Like $assertScript it now drives the GENUINE extracted entrypoint decision
# unit heal-workspace-perms.sh (task 007a) rather than calling fix-workspace-perms.sh
# directly; because this fixture root is node-owned the root-level write probe in the unit
# PASSES, so ONLY 007's nested-uid-0 DETECTION scan can hand the workspace to the helper.
# This case therefore guards that detection scan, not only the helper chown: revert the scan
# and the nested entries stay root-owned, so the post-fix edit/commit fail. The node-owned
# root means the root-level write probe would PASS, so this probes the nested root-owned
# tracked file instead. Same exit contract: 0 passed, 42 masked (node could already write ->
# self-skip), other = genuine failure.
$assertScriptMixed = @(
  'set -u'
  'WS="$1"'
  'NESTED="${WS}/nested.txt"'
  '# Only meaningful as the node agent (uid 1000) - the uid heal-workspace-perms.sh gates its'
  '# nested-uid-0 scan on (it scans only a root whose owner == id -u); hard-FAIL if not, so a'
  '# dropped --user node or an image USER regression cannot make the scan silently no-op.'
  'if [ "$(id -u)" != "1000" ]; then'
  '  echo "FAIL: dir-mount mixed assertion not running as node (uid 1000) - got uid $(id -u)" >&2'
  '  exit 1'
  'fi'
  'if echo masked 2>/dev/null >>"$NESTED"; then'
  '  echo "  skip: node can already write the nested root-owned file (this host masks the native-Linux uid bug)"'
  '  exit 42'
  'fi'
  'echo "  ok: node cannot write the nested root-owned tracked file before the fix (EACCES as expected)"'
  '# 2. Drive the REAL entrypoint decision unit heal-workspace-perms.sh - the exact code'
  '#    entrypoint-core.sh runs. Run as node, NOT via sudo (the unit runs sudo for the inner'
  '#    chown itself). Replaces the former direct sudo fix-workspace-perms.sh call. For THIS'
  '#    mixed case it guards 007 nested-uid-0 DETECTION scan, not only the helper chown: the'
  '#    node-owned root means the root-level write probe PASSES, so ONLY the nested-uid-0 scan'
  '#    adds the workspace to _unwritable and invokes the helper. Revert that scan and the'
  '#    nested uid-0 entries stay root-owned, so the edit/commit below fail with EACCES.'
  'if ! /usr/local/bin/heal-workspace-perms.sh; then'
  '  echo "FAIL: the real entrypoint heal unit (heal-workspace-perms.sh) errored (missing, non-executable, or a probe/scan fault); a 007 nested-uid-0 detection-scan or fix-workspace-perms.sh helper/sudoers regression instead surfaces at the write/commit steps below" >&2'
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

# The sensitive-source guard assertion (the VPS-lockout incident), behaviourally identical to
# the .sh ASSERT_SCRIPT_SENSITIVE. Run AS node against a genuinely root-owned fixture, but with
# POWBOX_WORKSPACE_HOST_PATH set (on the docker run) to a home/system path so the real heal unit
# must REFUSE to chown it and warn, leaving the tree root-owned. Exit contract: 0 = guard
# skipped (tree left root-owned, node still cannot write); 42 = masked; other = failure.
$assertScriptSensitive = @(
  'set -u'
  'WS="$1"'
  'if [ "$(id -u)" != "1000" ]; then'
  '  echo "FAIL: sensitive-skip assertion not running as node (uid 1000) - got uid $(id -u)" >&2'
  '  exit 1'
  'fi'
  '# Ground-truth: node must NOT be able to write the root-owned mount before the heal.'
  'if probe="$(mktemp "${WS}/.powbox-sens-probe.XXXXXX" 2>/dev/null)"; then'
  '  rm -f "$probe" 2>/dev/null || true'
  '  echo "  skip: node can already write the root-owned mount (this host masks the native-Linux uid bug)"'
  '  exit 42'
  'fi'
  'echo "  ok: node cannot write the root-owned mount before the heal (as expected)"'
  '# Drive the REAL heal unit. POWBOX_WORKSPACE_HOST_PATH (set on the docker run) marks the host'
  '# source as a home/system dir, so heal MUST skip the chown and warn (best-effort: exit 0).'
  'errlog="$(mktemp)"'
  'if ! /usr/local/bin/heal-workspace-perms.sh 2>"$errlog"; then'
  '  echo "FAIL: heal-workspace-perms.sh errored (it should skip cleanly and exit 0). stderr:" >&2'
  '  cat "$errlog" >&2'
  '  exit 1'
  'fi'
  'if ! grep -q "system or home directory" "$errlog"; then'
  '  echo "FAIL: heal did not emit the sensitive-source skip warning. stderr was:" >&2'
  '  cat "$errlog" >&2'
  '  exit 1'
  'fi'
  'echo "  ok: heal emitted the sensitive-source skip warning"'
  '# The guard must have PREVENTED the chown: node still cannot write, tree still root-owned.'
  'if probe="$(mktemp "${WS}/.powbox-sens-probe2.XXXXXX" 2>/dev/null)"; then'
  '  rm -f "$probe" 2>/dev/null || true'
  '  echo "FAIL: node can write the mount AFTER heal - the chown was NOT skipped (guard failed)" >&2'
  '  exit 1'
  'fi'
  'owner="$(stat -c %u "$WS" 2>/dev/null || echo "?")"'
  'if [ "$owner" != "0" ]; then'
  '  echo "FAIL: workspace root owned by uid ${owner} after heal, expected still-root (0) - guard failed" >&2'
  '  exit 1'
  'fi'
  'echo "  ok: chown was skipped - node still cannot write and the tree is still root-owned (uid 0)"'
  'exit 0'
) -join "`n"

# The privileged-boundary backstop assertion, behaviourally identical to the .sh
# ASSERT_SCRIPT_FIX_BACKSTOP. Run AS node against a read-only bind of the host /etc: fix runs
# under sudo (env stripped), and with no marker recorded falls back to the /proc/self/mountinfo
# bind source, so it must refuse the sensitive /etc source with NO POWBOX_WORKSPACE_HOST_PATH
# set. Exit contract: 0 = fix refused via the mountinfo fallback; 42 = this host reports a
# non-sensitive /etc source (mount-layout quirk) -> self-skip; other = failure. (The
# complementary true-source path is task 009 Gap A, covered by the fix-true-source case below.)
$assertScriptFixBackstop = @(
  'set -u'
  'WS="$1"'
  '. /usr/local/bin/sensitive-host-path.sh'
  'src="$(powbox_mountinfo_host_src "$WS")"'
  'echo "  info: mountinfo source for $WS resolves to: ${src:-<none>}"'
  'if ! powbox_is_sensitive_host_path "$src"; then'
  '  echo "  skip: this host reports a non-sensitive bind source (${src:-<none>}) for the /etc mount; cannot exercise the mountinfo backstop"'
  '  exit 42'
  'fi'
  'out="$(sudo /usr/local/bin/fix-workspace-perms.sh "$WS" 2>&1)"; rc=$?'
  'printf "%s\n" "$out"'
  'if [ "$rc" = 0 ]; then'
  '  echo "FAIL: fix-workspace-perms.sh exited 0 on a sensitive ($src) mount - it must refuse" >&2'
  '  exit 1'
  'fi'
  'if ! printf "%s" "$out" | grep -q "refusing to chown"; then'
  '  echo "FAIL: fix-workspace-perms.sh exited non-zero but WITHOUT the sensitive-source refusal (an unrelated error, not the guard). Output above." >&2'
  '  exit 1'
  'fi'
  'echo "  ok: fix-workspace-perms.sh refused to chown the sensitive ($src) mount via the mountinfo backstop"'
  'exit 0'
) -join "`n"

# The privileged-boundary TRUE-SOURCE refusal assertion (task 009 Gap A), behaviourally identical
# to the .sh ASSERT_SCRIPT_FIX_TRUESRC. Run AS node against a root-owned fixture whose mountinfo
# source is a NON-sensitive /tmp bind, with a marker recording the SENSITIVE true source
# /home/alice (as on a separate-/home layout). fix (under sudo, env stripped) must refuse via the
# marker file. Exit contract: 0 = fix refused via the recorded true source; 42 = the fixture
# mountinfo source is itself sensitive (mount-layout quirk) -> self-skip; other = failure.
$assertScriptFixTrueSrc = @(
  'set -u'
  'WS="$1"'
  'if [ "$(id -u)" != "1000" ]; then'
  '  echo "FAIL: fix-true-source assertion not running as node (uid 1000) - got uid $(id -u)" >&2'
  '  exit 1'
  'fi'
  '. /usr/local/bin/sensitive-host-path.sh'
  '# Precondition: the fixture mountinfo source must be NON-sensitive, so the OLD mountinfo-only'
  '# backstop would NOT refuse - else this case would pass for the wrong reason.'
  'mi_src="$(powbox_mountinfo_host_src "$WS")"'
  'echo "  info: mountinfo source for $WS resolves to: ${mi_src:-<none>}"'
  'if powbox_is_sensitive_host_path "$mi_src"; then'
  '  echo "  skip: this host reports a sensitive mountinfo source (${mi_src}) for the fixture; cannot isolate the true-source path"'
  '  exit 42'
  'fi'
  '# Record a SENSITIVE true source, then confirm it landed (empty readback => /run/powbox is not'
  '# node-writable in this image).'
  'if ! powbox_record_workspace_source "$WS" "/home/alice"; then'
  '  echo "FAIL: powbox_record_workspace_source returned non-zero writing the marker map" >&2'
  '  exit 1'
  'fi'
  'if [ "$(powbox_marker_host_src "$WS")" != "/home/alice" ]; then'
  '  echo "FAIL: marker map did not record the true source (is /run/powbox node-writable in this image?)" >&2'
  '  exit 1'
  'fi'
  'out="$(sudo /usr/local/bin/fix-workspace-perms.sh "$WS" 2>&1)"; rc=$?'
  'printf "%s\n" "$out"'
  'if [ "$rc" = 0 ]; then'
  '  echo "FAIL: fix-workspace-perms.sh exited 0 on a true-source-sensitive (/home/alice) mount - it must refuse (Gap A regression: it classified on the non-sensitive mountinfo source ${mi_src})" >&2'
  '  exit 1'
  'fi'
  'if ! printf "%s" "$out" | grep -q "refusing to chown"; then'
  '  echo "FAIL: fix exited non-zero but WITHOUT the sensitive-source refusal (an unrelated error). Output above." >&2'
  '  exit 1'
  'fi'
  'if ! printf "%s" "$out" | grep -q "/home/alice"; then'
  '  echo "FAIL: fix refused but did not classify on the recorded true source (/home/alice). Output above." >&2'
  '  exit 1'
  'fi'
  'owner="$(stat -c %u "$WS" 2>/dev/null || echo "?")"'
  'if [ "$owner" != "0" ]; then'
  '  echo "FAIL: workspace root owned by uid ${owner} after the refusal, expected still-root (0) - fix chowned despite refusing?" >&2'
  '  exit 1'
  'fi'
  'echo "  ok: fix refused via the recorded true source (/home/alice) though mountinfo (${mi_src}) is non-sensitive and sudo stripped the env"'
  'exit 0'
) -join "`n"

# The startup-heal TRUE-SOURCE heal assertion (task 009 Gap B), behaviourally identical to the .sh
# ASSERT_SCRIPT_HEAL_TRUESRC. Run AS node against a root-owned fixture with a marker recording the
# SAFE true source /projects (as on a whole-filesystem-mount checkout where mountinfo field 4 is a
# bare `/`), launched with a deliberately SENSITIVE env (/root) to prove the marker is
# authoritative - the heal must HEAL, not skip. Exit contract: 0 = heal claimed the tree for node;
# 42 = masked (node could already write) -> self-skip; other = failure (heal wrongly skipped).
$assertScriptHealTrueSrc = @(
  'set -u'
  'WS="$1"'
  'if [ "$(id -u)" != "1000" ]; then'
  '  echo "FAIL: heal-true-source assertion not running as node (uid 1000) - got uid $(id -u)" >&2'
  '  exit 1'
  'fi'
  'if probe="$(mktemp "${WS}/.powbox-truesrc-probe.XXXXXX" 2>/dev/null)"; then'
  '  rm -f "$probe" 2>/dev/null || true'
  '  echo "  skip: node can already write the root-owned mount (this host masks the native-Linux uid bug)"'
  '  exit 42'
  'fi'
  'echo "  ok: node cannot write the root-owned mount before the heal (as expected)"'
  '. /usr/local/bin/sensitive-host-path.sh'
  'if ! powbox_record_workspace_source "$WS" "/projects"; then'
  '  echo "FAIL: powbox_record_workspace_source returned non-zero writing the marker map" >&2'
  '  exit 1'
  'fi'
  'if [ "$(powbox_marker_host_src "$WS")" != "/projects" ]; then'
  '  echo "FAIL: marker map did not record the true source (is /run/powbox node-writable in this image?)" >&2'
  '  exit 1'
  'fi'
  '# Drive the REAL heal unit. It must NOT skip: the recorded true source (/projects) is'
  '# authoritative over the degenerate mountinfo and the sensitive launcher env below.'
  'errlog="$(mktemp)"'
  'if ! /usr/local/bin/heal-workspace-perms.sh 2>"$errlog"; then'
  '  echo "FAIL: heal-workspace-perms.sh errored (it should heal cleanly and exit 0). stderr:" >&2'
  '  cat "$errlog" >&2'
  '  exit 1'
  'fi'
  'if grep -q "system or home directory" "$errlog"; then'
  '  echo "FAIL: heal SKIPPED the whole-fs-mount checkout - it classified on the degenerate mountinfo / sensitive env instead of the recorded true source (/projects). This is the Gap B regression. stderr:" >&2'
  '  cat "$errlog" >&2'
  '  exit 1'
  'fi'
  'if ! touch "${WS}/smoke-write" 2>/dev/null; then'
  '  echo "FAIL: node still cannot write the tree after the heal - it was wrongly skipped (Gap B regression)" >&2'
  '  exit 1'
  'fi'
  'owner="$(stat -c %u "${WS}/smoke-write" 2>/dev/null || echo "?")"'
  'if [ "$owner" != "1000" ]; then'
  '  echo "FAIL: smoke-write owned by uid ${owner} after the heal, expected node (1000)" >&2'
  '  exit 1'
  'fi'
  'echo "  ok: heal claimed the whole-fs-mount checkout for node via the recorded true source (/projects), despite a sensitive launcher env (/root)"'
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
  # root-level write probe sees a node-owned root and passes, so only 007's entrypoint
  # nested-uid-0 detection + the helper's node-owned-root path heal it. $assertScriptMixed
  # now drives the genuine extracted unit heal-workspace-perms.sh (task 007a), so this case
  # guards that nested-uid-0 detection scan, not only the helper chown. Mirrors
  # case_mixed_ownership in the .sh: root stays node-owned; only nested entries go to root;
  # its own probe + assertion ($assertScriptMixed).
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
  # --user node (matching the all-root run and the .sh): heal-workspace-perms.sh gates its
  # nested-uid-0 scan on a root whose owner == id -u, so the container MUST run as node (uid
  # 1000) or the scan no-ops and the case would fail for the wrong reason.
  docker run --rm --user node -v "${mfixture}:${mount}" --entrypoint /bin/bash $Image -c $assertScriptMixed powbox-dirmount $mount
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

  # === Case: sensitive host source - heal must REFUSE to chown (the VPS-lockout incident) ====
  # A cc/cx accidentally launched from ~ bind-mounts the whole home tree as the "project"; the
  # heal would then recursively chown it to node, breaking sshd StrictModes on ~/.ssh and
  # locking the user out of the host. launch-agent passes POWBOX_WORKSPACE_HOST_PATH and
  # POWBOX_WORKSPACE_DIR, and the heal skips any workspace whose host source is a system/home dir.
  # Reproduce that: a root-owned fixture launched with POWBOX_WORKSPACE_HOST_PATH=/root and
  # POWBOX_WORKSPACE_DIR=<mount> (no marker written here, so the heal's env-for-the-named-mount
  # fallback is what catches it), so the heal must skip the chown and warn, leaving the tree
  # root-owned. Verified in-container and host-side (fixture stays uid 0).
  $sfixture = (& mktemp -d "/tmp/powbox-dirmount-XXXXXX").Trim()
  $fixtures.Add($sfixture)
  & git -C $sfixture init -q
  Set-Content -LiteralPath (Join-Path $sfixture 'README.md') -Value 'powbox dir-mount ownership smoke fixture'
  Invoke-AsRoot @('chown', '-R', 'root:root', $sfixture)
  Write-Host "Case: sensitive host source (POWBOX_WORKSPACE_HOST_PATH=/root) - heal must skip the chown"
  docker run --rm --user node -e POWBOX_WORKSPACE_HOST_PATH=/root -e POWBOX_WORKSPACE_HOST_HOME=/root -e "POWBOX_WORKSPACE_DIR=$mount" -v "${sfixture}:${mount}" --entrypoint /bin/bash $Image -c $assertScriptSensitive powbox-dirmount $mount
  $rc = $LASTEXITCODE
  if ($rc -eq 0) {
    # Host-side: the guard left the tree untouched - still root-owned (uid 0).
    $hostOwner = (Invoke-AsRoot @('stat', '-c', '%u', $sfixture)).Trim()
    if ($hostOwner -ne '0') { Fail "host-side fixture root owned by uid $hostOwner after the run, expected still-root (0) - the guard failed to skip the chown" }
    Write-Host "  ok: host-side fixture is still root-owned (uid 0) - the chown was skipped"
    $passed++
  }
  elseif ($rc -eq 42) { $masked = $true }
  else { Fail "heal did not skip the chown for a sensitive host source (see the FAIL line above)" }

  # === Case: privileged-boundary backstop - fix refuses a sensitive mountinfo source =========
  # fix-workspace-perms.sh runs under sudo (env_reset strips caller env), so with no marker it
  # falls back to the /proc/self/mountinfo bind source and refuses a sensitive one independently
  # of heal. Bind the host /etc READ-ONLY (its real mountinfo source is /etc), so fix must refuse
  # via the fallback with NO sensitive env set. fix refuses before any walk/chown, so /etc is
  # untouched.
  Write-Host "Case: privileged backstop - fix-workspace-perms refuses a sensitive (/etc) mountinfo source"
  docker run --rm --user node -v "/etc:${mount}:ro" --entrypoint /bin/bash $Image -c $assertScriptFixBackstop powbox-dirmount $mount
  $rc = $LASTEXITCODE
  if ($rc -eq 0) { $passed++ }
  elseif ($rc -eq 42) { $masked = $true }
  else { Fail "fix-workspace-perms did not refuse a sensitive /etc mountinfo source (see the FAIL line above)" }

  # === Case: privileged backstop TRUE-SOURCE refusal (task 009 Gap A) ========================
  # A root-owned fixture whose mountinfo source is a non-sensitive /tmp bind, with a marker
  # recording the SENSITIVE true source /home/alice - as on a separate-/home layout where a
  # /home/alice bind reads back from mountinfo as the shallow /alice. fix must refuse via the
  # marker (which survives sudo env_reset). Reverting task 009 makes fix classify on the
  # non-sensitive mountinfo source and NOT refuse -> this case fails.
  $tfixture = (& mktemp -d "/tmp/powbox-dirmount-XXXXXX").Trim()
  $fixtures.Add($tfixture)
  & git -C $tfixture init -q
  Set-Content -LiteralPath (Join-Path $tfixture 'README.md') -Value 'powbox dir-mount ownership smoke fixture'
  Invoke-AsRoot @('chown', '-R', 'root:root', $tfixture)
  Write-Host "Case: privileged backstop TRUE-SOURCE refusal (marker /home/alice vs non-sensitive mountinfo) - fix must refuse"
  docker run --rm --user node -v "${tfixture}:${mount}" --entrypoint /bin/bash $Image -c $assertScriptFixTrueSrc powbox-dirmount $mount
  $rc = $LASTEXITCODE
  if ($rc -eq 0) {
    # Host-side: fix refused before any chown, so the fixture is still root-owned (uid 0).
    $hostOwner = (Invoke-AsRoot @('stat', '-c', '%u', $tfixture)).Trim()
    if ($hostOwner -ne '0') { Fail "host-side fixture root owned by uid $hostOwner after the run, expected still-root (0) - fix chowned a true-source-sensitive mount" }
    Write-Host "  ok: host-side fixture is still root-owned (uid 0) - fix refused via the recorded true source"
    $passed++
  }
  elseif ($rc -eq 42) { $masked = $true }
  else { Fail "fix-workspace-perms did not refuse a true-source-sensitive (marker /home/alice) mount (see the FAIL line above)" }

  # === Case: startup-heal TRUE-SOURCE heal (task 009 Gap B) ==================================
  # A root-owned fixture with a marker recording the SAFE true source /projects (as on a
  # whole-filesystem-mount checkout where mountinfo field 4 is a bare `/`), launched with a
  # deliberately SENSITIVE env (POWBOX_WORKSPACE_HOST_PATH=/root) to prove the marker (true
  # source) is authoritative - the heal must HEAL, not skip. Reverting task 009 makes the heal
  # consult that sensitive env (or the degenerate mountinfo) directly and SKIP -> node cannot
  # write -> this case fails.
  $hfixture = (& mktemp -d "/tmp/powbox-dirmount-XXXXXX").Trim()
  $fixtures.Add($hfixture)
  & git -C $hfixture init -q
  Set-Content -LiteralPath (Join-Path $hfixture 'README.md') -Value 'powbox dir-mount ownership smoke fixture'
  Invoke-AsRoot @('chown', '-R', 'root:root', $hfixture)
  Write-Host "Case: startup-heal TRUE-SOURCE heal (marker /projects vs sensitive env /root) - heal must claim the tree"
  docker run --rm --user node -e POWBOX_WORKSPACE_HOST_PATH=/root -e POWBOX_WORKSPACE_HOST_HOME=/root -e "POWBOX_WORKSPACE_DIR=$mount" -v "${hfixture}:${mount}" --entrypoint /bin/bash $Image -c $assertScriptHealTrueSrc powbox-dirmount $mount
  $rc = $LASTEXITCODE
  if ($rc -eq 0) {
    # Host-side: the heal claimed the tree for node end to end.
    $hostOwner = (Invoke-AsRoot @('stat', '-c', '%u', (Join-Path $hfixture 'smoke-write'))).Trim()
    if ($hostOwner -ne '1000') { Fail "host-side smoke-write owned by uid $hostOwner after the run, expected node (1000) - the heal did not claim the whole-fs-mount checkout" }
    Write-Host "  ok: host-side smoke-write is node-owned (uid 1000) after the run - the heal claimed it via the true source"
    $passed++
  }
  elseif ($rc -eq 42) { $masked = $true }
  else { Fail "heal did not claim a whole-fs-mount checkout via its recorded true source (see the FAIL line above)" }
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
