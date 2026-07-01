#!/usr/bin/env bash
set -euo pipefail

# Smoke-test the native-Linux dir-mount ownership fix (PR #55) and its mixed-ownership
# extension (task 007). Two cases run: an all-root-owned mount (PR #55) and a node-owned
# root that hides nested root-owned files left by a host `sudo git pull` (task 007).
#
# On a NATIVE-LINUX host a bind-mounted repo keeps its host uid/gid. When that is
# root (a repo under /root, or a host running powbox as root) the mount is
# root:root inside the container and the `node` agent (uid 1000) cannot write the
# working tree or .git — every `touch`/`git pull`/`git commit` fails with EACCES
# (`cannot open '.git/FETCH_HEAD': Permission denied`). A subtler variant: a host
# operation that runs as root against a live bind mount (most often `sudo git pull`)
# re-owns to uid 0 only the paths it writes (new .git/objects/*, refs, changed
# working-tree files), leaving the node-owned top dir but nested root-owned files that
# block `git commit` with `insufficient permission for adding an object to repository
# database`. entrypoint-core.sh probes
# write access as node and, for any workspace it cannot write, runs the
# sudo-allowlisted root helper /usr/local/bin/fix-workspace-perms.sh, which chowns
# a root-owned tree to node. Windows/WSL/macOS bind mounts honour node's writes
# regardless of the displayed owner, so the bug — and this guard — is native-Linux
# only. A regression (entrypoint reorder, a dropped sudoers entry, a renamed
# helper) would silently re-break every native-Linux host whose repo is not
# uid-1000-owned; this stage is the automated guard.
#
# BOTH cases drive the GENUINE extracted entrypoint decision unit
# /usr/local/bin/heal-workspace-perms.sh — the byte-for-byte code entrypoint-core.sh runs:
# its node write-probe + nested-uid-0 scan decide whether and with what path/sudo to call
# fix-workspace-perms.sh. So they guard the probe-and-call DECISION path, not only the helper,
# and a regression confined to that decision logic (probe stops detecting the unwritable
# mount, workspace never handed to the helper) is caught here. Because the unit ultimately
# invokes /usr/local/bin/fix-workspace-perms.sh by the exact path + sudo mechanism the
# entrypoint uses, the in-isolation helper + sudoers-wiring coverage is preserved (subsumed),
# not lost. It still does NOT boot the full entrypoint chain — the firewall/gh/shadow setup
# needs the launcher's compose wiring and is out of scope here. The all-root case exercises
# the unit's root-level write probe; the mixed-ownership case (node-owned root + nested uid-0
# entries) exercises the unit's nested-uid-0 DETECTION scan — the production trigger task 007
# added that the root-level probe misses — so reverting ONLY that scan now fails the smoke
# (task 007a).
#
# Two further cases guard the SENSITIVE-SOURCE refusal (the VPS-lockout incident: a `cc`/`cx`
# accidentally run from ~ would bind-mount the whole home tree and the heal would chown it to
# node, breaking sshd StrictModes on ~/.ssh and locking the user out of the host):
#   * sensitive-skip — a root-owned fixture launched with POWBOX_WORKSPACE_HOST_PATH=/root, so
#     the real heal unit must SKIP the chown and warn (tree stays root-owned). Guards the
#     launcher-env path heal consults in production.
#   * fix-mountinfo-backstop — a read-only bind of the host /etc, so fix-workspace-perms.sh
#     (the privileged boundary, run under sudo with env stripped) must refuse via the
#     /proc/self/mountinfo source it derives independently of any caller env. Guards the
#     boundary helper directly, so removing its guard fails the smoke even though heal skips
#     first in production. The pure predicate + mountinfo parser are also unit-tested by
#     scripts/test-sensitive-host-path.sh (no Docker/root/native-Linux needed).
#
# Self-skips (exit 0, no failure) when it cannot meaningfully run:
#   * the agent image is absent — unless POWBOX_SMOKE_REQUIRE_IMAGE is set, then
#     it fails (mirrors smoke-test-selfhosted.sh's guard);
#   * the host is not native Linux (Windows/WSL/macOS) — the bind-mount uid bug
#     does not manifest there, and the GNU tooling below is Linux-only anyway;
#   * it cannot create a genuinely root-owned fixture (no root / no passwordless
#     sudo) — the local-dev case; in CI (task 003) it runs as root for real;
#   * the host masks the native-Linux uid bug (node can already write a root-owned
#     mount — Windows/WSL/macOS FUSE, or a uid-matched host): there is nothing to
#     assert.
#
# When commands/smoke-test.sh runs this as Stage 5 it passes POWBOX_SMOKE_SKIP_MARKER
# so each runtime self-skip is recorded in the umbrella banner rather than counting
# silently toward "all stages ran"; see note_skip below.

IMAGE="${1:-powbox-agent:latest}"

# A constant in-container mount point. Each case runs its own --rm container, so
# the path never collides; the host-side fixture dir is always a unique mktemp.
MOUNT="/workspace/powbox-dirmount-smoke"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Record a runtime self-skip reason for the umbrella banner. The stage still
# exits 0 on a self-skip, so commands/smoke-test.sh cannot tell a real pass from a
# skip by exit code alone; it passes POWBOX_SMOKE_SKIP_MARKER and we write the
# reason there. A no-op when unset, so direct callers and CI keep the plain
# exit-0-on-skip contract.
note_skip() {
	if [ -n "${POWBOX_SMOKE_SKIP_MARKER:-}" ]; then
		printf '%s' "$1" >"$POWBOX_SMOKE_SKIP_MARKER" || true
	fi
}

# --- root-capability detection ------------------------------------------------
# Creating a genuinely root-owned fixture needs root. Already-root needs no
# prefix; otherwise general passwordless sudo (a CI runner) works. powbox's own
# dev container scopes node's sudo to a few allowlisted helpers, so `sudo -n true`
# is denied there and the stage self-skips instead of failing.
ROOT_PREFIX=()
CAN_ROOT=0
if [ "$(id -u)" -eq 0 ]; then
	CAN_ROOT=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
	ROOT_PREFIX=(sudo)
	CAN_ROOT=1
fi

as_root() {
	if [ "${#ROOT_PREFIX[@]}" -gt 0 ]; then
		"${ROOT_PREFIX[@]}" "$@"
	else
		"$@"
	fi
}

# --- fixture lifecycle --------------------------------------------------------
# Track every fixture so the trap can remove them — including root-owned trees,
# which need root to unlink.
FIXTURES=()
cleanup() {
	local f
	for f in "${FIXTURES[@]:-}"; do
		[ -n "$f" ] || continue
		as_root rm -rf "$f" 2>/dev/null || true
	done
}
trap cleanup EXIT

# make_git_fixture — create a fresh, host-node-owned throwaway git repo and echo
# its path. The CALLER mutates ownership for its case. Factored so task 007 can
# build its mixed-ownership fixture from the same base (see the extension seam).
make_git_fixture() {
	local d
	d="$(mktemp -d "${TMPDIR:-/tmp}/powbox-dirmount-XXXXXX")"
	git -C "$d" init -q
	printf 'powbox dir-mount ownership smoke fixture\n' >"$d/README.md"
	printf '%s' "$d"
}

# The in-container assertion, run AS node — pinned with `--user node` on the
# docker run below (run_dirmount_case), not merely the image's default user, so a
# USER regression in the image cannot quietly run this as root and mask the bug.
# Single-quoted so the host leaves the inner shell alone; it takes the mount path
# as $1 and signals back via exit code:
#   0  — passed (node can write + git-commit after the fix; tree is node-owned)
#   42 — masked (node could already write the root-owned mount → self-skip)
#   1  — genuine failure (the fix did not make the tree writable by node)
# shellcheck disable=SC2016  # the inner shell expands these, NOT the host
ASSERT_SCRIPT='
set -u
WS="$1"
# 0. This stage is only meaningful AS the node agent (uid 1000) — the user that
#    hits EACCES on a root-owned mount. `--user node` pins it on the docker run,
#    but assert it here too so a dropped flag or an image USER regression hard-FAILS
#    instead of letting the pre-fix probe below succeed and mis-report a masked skip.
if [ "$(id -u)" != "1000" ]; then
	echo "FAIL: dir-mount assertion not running as node (uid 1000) — got uid $(id -u)" >&2
	exit 1
fi
# 1. Ground-truth write probe as node BEFORE the fix (mirrors entrypoint-core.sh:
#    a real create, not [ -w ], because mode bits can disagree with the FS). On
#    native Linux a root-owned bind mount is genuinely unwritable; a platform that
#    masks the uid bug lets this succeed — nothing to assert, so self-skip (42).
if probe="$(mktemp "${WS}/.powbox-dirmount-probe.XXXXXX" 2>/dev/null)"; then
	rm -f "$probe" 2>/dev/null || true
	echo "  skip: node can already write the root-owned mount (this host masks the native-Linux uid bug)"
	exit 42
fi
echo "  ok: node cannot write the root-owned mount before the fix (genuinely root-owned, EACCES as expected)"
# 2. Drive the REAL entrypoint decision unit — heal-workspace-perms.sh, the EXACT code
#    entrypoint-core.sh runs. Its node write-probe + nested-uid-0 scan DECIDE whether and with
#    what path/sudo to call fix-workspace-perms.sh; run it as node (NOT via sudo — the unit
#    runs sudo for the inner chown by itself). This deliberately REPLACES (does not drop) the
#    former direct sudo fix-workspace-perms.sh call: the unit ultimately invokes that helper
#    by the same allowlisted path/sudo mechanism, so the sudoers wiring + helper path are still
#    exercised — the in-isolation helper coverage is PRESERVED, subsumed by this path. Driving
#    the unit ADDITIONALLY guards the probe/decision logic: a regression there (the probe stops
#    seeing the unwritable mount, the workspace is never added to _unwritable, the helper is
#    never invoked or invoked with a wrong path) leaves the tree root-owned and surfaces at
#    steps 3-5 below as EACCES — distinguishing a probe/decision regression from a bare
#    helper/sudoers regression. The unit is best-effort (warns and exits 0 on an inner chown
#    failure), so a non-zero exit HERE means the unit itself is missing/non-executable/erroring.
if ! /usr/local/bin/heal-workspace-perms.sh; then
	echo "FAIL: the real entrypoint heal unit (heal-workspace-perms.sh) errored — missing, non-executable, or a probe/scan fault; a fix-workspace-perms.sh helper/sudoers regression instead surfaces at the write/commit steps below" >&2
	exit 1
fi
# 3. node can now create a file in the working tree.
if ! touch "${WS}/smoke-write" 2>/dev/null; then
	echo "FAIL: node still cannot write the tree after the fix (cannot open: Permission denied)" >&2
	exit 1
fi
# 3b. ... and node can MODIFY a PRE-EXISTING working-tree file, not just create new
#     ones. The fixture ships a root-owned README.md; a regression that chowns only
#     the workspace root + .git while leaving existing files root-owned would pass
#     steps 3-4 (new file + .git) yet still leave the mounted repo contents
#     uneditable, so guard the working-tree contents explicitly.
if ! printf "smoke edit\n" >>"${WS}/README.md" 2>/dev/null; then
	echo "FAIL: node cannot modify the pre-existing root-owned README.md after the fix (working-tree contents still not writable)" >&2
	exit 1
fi
# 4. ... and a git write succeeds — the root-owned .git is the thing that broke
#    first (cannot open .git/FETCH_HEAD). --allow-empty needs no prior commit.
if ! git -C "$WS" -c user.email=smoke@powbox.local -c user.name="powbox smoke" \
	commit --allow-empty -m "powbox dirmount smoke" >/dev/null 2>&1; then
	echo "FAIL: node git commit failed after the fix (.git still not writable by node?)" >&2
	exit 1
fi
# 5. the helper actually claimed the tree for node (uid 1000), end to end — both the
#    newly-created file and the pre-existing one.
for f in smoke-write README.md; do
	owner="$(stat -c %u "${WS}/${f}" 2>/dev/null || echo "?")"
	if [ "$owner" != "1000" ]; then
		echo "FAIL: ${f} owned by uid ${owner} after the fix, expected node (1000)" >&2
		exit 1
	fi
done
echo "  ok: node can touch + modify existing files + git-commit after the fix, and the tree is node-owned (uid 1000)"
exit 0
'

# The mixed-ownership in-container assertion (task 007), run AS node against a fixture
# whose ROOT is node-owned but which hides nested root-owned entries (a tracked
# working-tree file + a .git/objects/<xx> shard), simulating a host `sudo git pull`.
# Like ASSERT_SCRIPT it now drives the GENUINE extracted entrypoint decision unit
# heal-workspace-perms.sh (task 007a) rather than calling fix-workspace-perms.sh directly,
# and because this fixture root is node-owned the root-level write probe in the unit PASSES —
# so ONLY 007's nested-uid-0 DETECTION scan can add the workspace to _unwritable and hand it
# to the helper. This case therefore guards that detection scan, not only the helper chown:
# revert the scan and the nested entries stay root-owned, so the post-fix edit/commit below
# fail. (007a follow-up from PR #63 review codex P2 r3445242133.)
# Same exit-code contract as ASSERT_SCRIPT (0 passed / 42 masked / other failure). The
# node-owned root means the root-level write probe ASSERT_SCRIPT uses would PASS here, so
# this instead probes the nested root-owned tracked file — the exact thing the mixed case
# breaks (and which a host masking the uid bug would still let node write).
# shellcheck disable=SC2016  # the inner shell expands these, NOT the host
ASSERT_SCRIPT_MIXED='
set -u
WS="$1"
NESTED="${WS}/nested.txt"
# 0. This stage is only meaningful AS the node agent (uid 1000) — the user that hits EACCES
#    on a root-owned mount, and (critically here) the uid heal-workspace-perms.sh gates its
#    nested-uid-0 scan on: it scans only a root whose owner == id -u. `--user node` pins it on
#    the docker run, but assert it here too so a dropped flag or an image USER regression
#    hard-FAILS instead of letting that scan silently no-op (the node-owned-root gate would
#    not match a uid != 1000 root) and mis-report a masked skip below.
if [ "$(id -u)" != "1000" ]; then
	echo "FAIL: dir-mount mixed assertion not running as node (uid 1000) — got uid $(id -u)" >&2
	exit 1
fi
# 1. Ground-truth write probe as node BEFORE the fix: node must be UNABLE to write the
#    nested root-owned tracked file (uid 0, mode 644). A platform that masks the
#    native-Linux uid bug lets node write it regardless of owner -> nothing to assert,
#    self-skip (42).
if echo masked 2>/dev/null >>"$NESTED"; then
	echo "  skip: node can already write the nested root-owned file (this host masks the native-Linux uid bug)"
	exit 42
fi
echo "  ok: node cannot write the nested root-owned tracked file before the fix (EACCES as expected)"
# 2. Drive the REAL entrypoint decision unit — heal-workspace-perms.sh, the EXACT code
#    entrypoint-core.sh runs; run it as node (NOT via sudo — the unit runs sudo for the inner
#    chown itself). This REPLACES the former direct sudo fix-workspace-perms.sh call. For THIS
#    mixed case it now guards 007 nested-uid-0 DETECTION scan, not only the helper chown: the
#    fixture root is node-owned, so the root-level write probe in the unit PASSES — ONLY the
#    nested-uid-0 scan (find -uid 0, gated on a node-owned root) adds the workspace to
#    _unwritable and invokes the helper. Revert that scan and the unit never calls the helper,
#    the nested uid-0 entries stay root-owned, and the post-fix edit/commit at steps 3-4 fail
#    with EACCES. The unit is best-effort (warns and exits 0 on an inner chown failure), so a
#    non-zero exit HERE means the unit itself is missing/non-executable/erroring; a
#    detection-scan or helper/sudoers regression instead surfaces at the write/commit steps
#    below.
if ! /usr/local/bin/heal-workspace-perms.sh; then
	echo "FAIL: the real entrypoint heal unit (heal-workspace-perms.sh) errored — missing, non-executable, or a probe/scan fault; a 007 nested-uid-0 detection-scan or fix-workspace-perms.sh helper/sudoers regression instead surfaces at the write/commit steps below" >&2
	exit 1
fi
# 3. node can now edit the formerly root-owned tracked file.
if ! echo healed >>"$NESTED" 2>/dev/null; then
	echo "FAIL: node still cannot write the nested file after the fix (nested root-owned entry not re-owned)" >&2
	exit 1
fi
# 4. ... and a REAL git write succeeds: commit -a writes new loose objects, the exact
#    operation the root-owned .git/objects/<xx> shard broke (insufficient permission for
#    adding an object to repository database). --allow-empty would NOT exercise that, so
#    commit the edit from step 3.
if ! git -C "$WS" -c user.email=smoke@powbox.local -c user.name="powbox smoke" \
	commit -aqm "powbox dirmount mixed smoke" >/dev/null 2>&1; then
	echo "FAIL: node git commit failed after the fix (.git/objects shard still root-owned?)" >&2
	exit 1
fi
# 5. no uid-0 entry survives anywhere in the tree (nested file + shard both re-owned).
remaining="$(find "$WS" -uid 0 -print -quit 2>/dev/null || true)"
if [ -n "$remaining" ]; then
	echo "FAIL: a root-owned entry survived the fix: $remaining" >&2
	exit 1
fi
echo "  ok: nested root-owned file + .git/objects shard re-owned to node; edit + git-commit succeed"
exit 0
'

# The sensitive-source guard assertion (the VPS-lockout incident), run AS node against a
# genuinely root-owned fixture, but with POWBOX_WORKSPACE_HOST_PATH set (on the docker run)
# to a HOME/SYSTEM path so the real heal unit must REFUSE to chown it. This exercises the
# production guard path: launch-agent passes that env, and heal-workspace-perms.sh skips any
# workspace whose host source is sensitive — so an accidental `cc`/`cx` from ~ never re-owns
# the home tree to node (which would break sshd StrictModes on ~/.ssh and lock the user out).
# The fixture bind itself is innocuous (mountinfo field4 = /tmp/...); the env is the signal,
# exactly as in production. Exit-code contract: 0 = guard correctly skipped (tree left
# root-owned, node still cannot write); 42 = masked (node could already write → cannot test);
# other = failure (the chown was NOT skipped, or the warning was missing).
# shellcheck disable=SC2016  # the inner shell expands these, NOT the host
ASSERT_SCRIPT_SENSITIVE='
set -u
WS="$1"
if [ "$(id -u)" != "1000" ]; then
	echo "FAIL: sensitive-skip assertion not running as node (uid 1000) — got uid $(id -u)" >&2
	exit 1
fi
# Ground-truth: node must NOT be able to write the root-owned mount before the heal. A host
# that masks the native-Linux uid bug lets node write it → nothing to assert, self-skip (42).
if probe="$(mktemp "${WS}/.powbox-sens-probe.XXXXXX" 2>/dev/null)"; then
	rm -f "$probe" 2>/dev/null || true
	echo "  skip: node can already write the root-owned mount (this host masks the native-Linux uid bug)"
	exit 42
fi
echo "  ok: node cannot write the root-owned mount before the heal (as expected)"
# Drive the REAL heal unit. POWBOX_WORKSPACE_HOST_PATH (set on the docker run) marks the host
# source as a home/system dir, so heal MUST skip the chown and warn. heal is best-effort
# (exit 0 even when it skips), so a non-zero exit means it errored.
errlog="$(mktemp)"
if ! /usr/local/bin/heal-workspace-perms.sh 2>"$errlog"; then
	echo "FAIL: heal-workspace-perms.sh errored (it should skip cleanly and exit 0). stderr:" >&2
	cat "$errlog" >&2
	exit 1
fi
if ! grep -q "system or home directory" "$errlog"; then
	echo "FAIL: heal did not emit the sensitive-source skip warning. stderr was:" >&2
	cat "$errlog" >&2
	exit 1
fi
echo "  ok: heal emitted the sensitive-source skip warning"
# The guard must have PREVENTED the chown: node still cannot write, and the tree is still
# root-owned. (A regression that ignored the guard would have chowned it to node.)
if probe="$(mktemp "${WS}/.powbox-sens-probe2.XXXXXX" 2>/dev/null)"; then
	rm -f "$probe" 2>/dev/null || true
	echo "FAIL: node can write the mount AFTER heal — the chown was NOT skipped (guard failed)" >&2
	exit 1
fi
owner="$(stat -c %u "$WS" 2>/dev/null || echo "?")"
if [ "$owner" != "0" ]; then
	echo "FAIL: workspace root owned by uid ${owner} after heal, expected still-root (0) — guard failed" >&2
	exit 1
fi
echo "  ok: chown was skipped — node still cannot write and the tree is still root-owned (uid 0)"
exit 0
'

# The privileged-boundary backstop assertion, run AS node against a read-only bind of the
# host /etc. fix-workspace-perms.sh runs under sudo (env stripped by env_reset), so it cannot
# trust a caller env var; it instead derives the bind source from /proc/self/mountinfo (which
# node cannot forge) and refuses a sensitive one. Here the REAL source IS sensitive (/etc), so
# fix must refuse even with no POWBOX_WORKSPACE_HOST_PATH set — exercising the mountinfo backstop on
# a direct invocation with a sensitive workspace, not only via heal (best-effort: on a separate-mount
# layout the source can resolve non-sensitive and this case self-skips below — feeding the true
# source, with mountinfo as fallback, is tracked in tasks/009). Exit-code
# contract: 0 = fix refused via the mountinfo backstop; 42 = this host reports a non-sensitive
# bind source for /etc (a mount-layout quirk; cannot exercise the path) → self-skip; other =
# failure (fix did NOT refuse, or failed for an unrelated reason).
# shellcheck disable=SC2016  # the inner shell expands these, NOT the host
ASSERT_SCRIPT_FIX_BACKSTOP='
set -u
WS="$1"
. /usr/local/bin/sensitive-host-path.sh
src="$(powbox_mountinfo_host_src "$WS")"
echo "  info: mountinfo source for $WS resolves to: ${src:-<none>}"
if ! powbox_is_sensitive_host_path "$src"; then
	echo "  skip: this host reports a non-sensitive bind source (${src:-<none>}) for the /etc mount; cannot exercise the mountinfo backstop"
	exit 42
fi
out="$(sudo /usr/local/bin/fix-workspace-perms.sh "$WS" 2>&1)"; rc=$?
printf "%s\n" "$out"
if [ "$rc" = 0 ]; then
	echo "FAIL: fix-workspace-perms.sh exited 0 on a sensitive ($src) mount — it must refuse" >&2
	exit 1
fi
if ! printf "%s" "$out" | grep -q "refusing to chown"; then
	echo "FAIL: fix-workspace-perms.sh exited non-zero but WITHOUT the sensitive-source refusal (an unrelated error, not the guard). Output above." >&2
	exit 1
fi
echo "  ok: fix-workspace-perms.sh refused to chown the sensitive ($src) mount via the mountinfo backstop"
exit 0
'

PASSED_CASES=0
MASKED=0

# run_dirmount_case — run an assertion script against $fixture and map its exit code.
# Streams the in-container ok/FAIL/skip lines live. Sets MASKED on a self-skip. The
# assert script ($2, default ASSERT_SCRIPT) and the host-side file whose post-run owner
# is verified ($3, default smoke-write) are parameterized so task 007's mixed-ownership
# case reuses this same plumbing with its own ASSERT_SCRIPT_MIXED / nested.txt.
run_dirmount_case() {
	local fixture="$1"
	local assert="${2:-$ASSERT_SCRIPT}"
	local host_check_file="${3:-smoke-write}"
	set +e
	docker run --rm \
		--user node \
		-v "${fixture}:${MOUNT}" \
		--entrypoint /bin/bash "$IMAGE" -c "$assert" powbox-dirmount "$MOUNT"
	local rc=$?
	set -e
	case "$rc" in
	0)
		# Host-side: the helper claimed the tree for node end to end. stat as root
		# — the chowned fixture (mktemp -d is mode 700) may not be traversable by a
		# non-owner sudo caller.
		local host_owner
		host_owner="$(as_root stat -c %u "${fixture}/${host_check_file}" 2>/dev/null || echo '?')"
		[ "$host_owner" = "1000" ] ||
			fail "host-side ${host_check_file} owned by uid ${host_owner}, expected node (1000)"
		echo "  ok: host-side ${host_check_file} is node-owned (uid 1000) after the run"
		PASSED_CASES=$((PASSED_CASES + 1))
		;;
	42)
		MASKED=1
		;;
	*)
		fail "node could not write the dir-mounted tree after the fix-workspace-perms.sh fix (see the FAIL line above)"
		;;
	esac
}

# === Case: all-root-owned mount ===============================================
# The reported and overwhelmingly common case: a repo under /root, so the WHOLE
# tree is root:root inside the container and node cannot write any of it. This is
# 005's acceptance case and ships green on its own.
case_all_root() {
	local fixture
	fixture="$(make_git_fixture)"
	FIXTURES+=("$fixture")
	as_root chown -R root:root "$fixture"
	echo "Case: all-root-owned mount (a repo under /root; root:root inside the container)"
	run_dirmount_case "$fixture"
}

# === Case: mixed-ownership mount (task 007) ===================================
# The case 005 left as a seam: a node-owned repo ROOT that hides nested root-owned
# files — a tracked working-tree file plus a .git/objects/<xx> shard dir chowned to
# root — exactly what a host `sudo git pull` against a live bind mount leaves behind
# (it re-owns to uid 0 the paths it writes, but not the top dir). 005's root-level
# write probe sees a node-owned root and passes, so the nested root-owned files are
# missed; only 007's entrypoint nested-uid-0 detection + the helper's node-owned-root
# path heal it. ASSERT_SCRIPT_MIXED now drives the genuine extracted unit
# heal-workspace-perms.sh (task 007a), so this case guards that nested-uid-0 detection
# scan, not only the helper chown. It reuses make_git_fixture / as_root /
# run_dirmount_case, mutating ownership differently (root stays node; only nested
# entries go to root) with its own probe + assertion (ASSERT_SCRIPT_MIXED).
case_mixed_ownership() {
	local fixture shard
	fixture="$(make_git_fixture)"
	FIXTURES+=("$fixture")
	# Build real history so .git/objects holds shard dirs, plus a tracked working-tree
	# file we can later root-own. Commit with an inline identity (the fixture has none).
	git -C "$fixture" -c user.email=smoke@powbox.local -c user.name="powbox smoke" add -A
	git -C "$fixture" -c user.email=smoke@powbox.local -c user.name="powbox smoke" commit -q -m "initial"
	printf 'tracked nested file\n' >"$fixture/nested.txt"
	git -C "$fixture" -c user.email=smoke@powbox.local -c user.name="powbox smoke" add nested.txt
	git -C "$fixture" -c user.email=smoke@powbox.local -c user.name="powbox smoke" commit -q -m "add nested file"
	# Locate the .git/objects/<xx> shard to root-own BEFORE chowning the tree to node:
	# mktemp -d gives a mode-700 root owned by the invoking user, so once `chown -R
	# 1000:1000` runs, a passwordless-sudo runner whose uid is not 1000 could no longer
	# traverse it — the unprivileged find below would see nothing and the case would
	# fail before exercising the helper. The captured path stays valid across the chown.
	shard="$(find "$fixture/.git/objects" -mindepth 1 -maxdepth 1 -type d -name '??' | head -n1)"
	[ -n "$shard" ] || fail "mixed-ownership fixture has no .git/objects/<xx> shard dir to root-own"
	# Force the exact mixed-ownership shape regardless of who runs the stage (root in
	# CI, else a passwordless-sudo runner): node-owned ROOT, with root-owned ONLY the
	# paths a host `sudo git pull` rewrites. chown the whole tree to node (uid 1000)
	# first so the root and every other entry is node-owned, then plant the nested
	# root-owned ones — a tracked file and one .git/objects/<xx> shard (+ its objects).
	as_root chown -R 1000:1000 "$fixture"
	as_root chown 0:0 "$fixture/nested.txt"
	as_root chown -R 0:0 "$shard"
	echo "Case: mixed-ownership mount (node-owned root + nested root-owned tracked file & .git/objects/<xx> shard, as from a host 'sudo git pull')"
	run_dirmount_case "$fixture" "$ASSERT_SCRIPT_MIXED" "nested.txt"
}

# === Case: sensitive host source — heal must REFUSE to chown (the VPS-lockout incident) ===
# A `cc`/`cx` accidentally launched from ~ bind-mounts the whole home tree as the "project";
# the heal would then recursively chown it to node, breaking sshd StrictModes on ~/.ssh and
# locking the user out of the host. launch-agent now passes POWBOX_WORKSPACE_HOST_PATH and the
# heal skips any workspace whose host source is a system/home dir. This case reproduces that:
# a genuinely root-owned fixture, but launched with POWBOX_WORKSPACE_HOST_PATH=/root, so the
# real heal unit must skip the chown and warn — leaving the tree root-owned. Verified BOTH
# in-container (ASSERT_SCRIPT_SENSITIVE) and host-side (the fixture stays uid 0 afterwards).
case_sensitive_skip() {
	local fixture
	fixture="$(make_git_fixture)"
	FIXTURES+=("$fixture")
	as_root chown -R root:root "$fixture"
	echo "Case: sensitive host source (POWBOX_WORKSPACE_HOST_PATH=/root) — heal must skip the chown"
	set +e
	docker run --rm \
		--user node \
		-e POWBOX_WORKSPACE_HOST_PATH=/root \
		-e POWBOX_WORKSPACE_HOST_HOME=/root \
		-v "${fixture}:${MOUNT}" \
		--entrypoint /bin/bash "$IMAGE" -c "$ASSERT_SCRIPT_SENSITIVE" powbox-dirmount "$MOUNT"
	local rc=$?
	set -e
	case "$rc" in
	0)
		# Host-side: the guard left the tree untouched — still root-owned (uid 0). stat as
		# root since the root-owned mktemp dir (mode 700) may not be traversable otherwise.
		local host_owner
		host_owner="$(as_root stat -c %u "$fixture" 2>/dev/null || echo '?')"
		[ "$host_owner" = "0" ] ||
			fail "host-side fixture root owned by uid ${host_owner} after the run, expected still-root (0) — the guard failed to skip the chown"
		echo "  ok: host-side fixture is still root-owned (uid 0) — the chown was skipped"
		PASSED_CASES=$((PASSED_CASES + 1))
		;;
	42)
		MASKED=1
		;;
	*)
		fail "heal did not skip the chown for a sensitive host source (see the FAIL line above)"
		;;
	esac
}

# === Case: privileged-boundary backstop — fix refuses a sensitive mountinfo source ============
# fix-workspace-perms.sh runs under sudo (env_reset strips caller env), so it re-derives the
# bind source from /proc/self/mountinfo and refuses a sensitive one INDEPENDENTLY of heal. To
# exercise that, bind the host /etc (root-owned, present everywhere) READ-ONLY: its real
# mountinfo source is /etc, so fix must refuse via the backstop with NO sensitive env set. fix
# refuses before any walk/chown, so the read-only /etc is never touched.
case_fix_mountinfo_backstop() {
	echo "Case: privileged backstop — fix-workspace-perms refuses a sensitive (/etc) mountinfo source"
	set +e
	docker run --rm \
		--user node \
		-v "/etc:${MOUNT}:ro" \
		--entrypoint /bin/bash "$IMAGE" -c "$ASSERT_SCRIPT_FIX_BACKSTOP" powbox-dirmount "$MOUNT"
	local rc=$?
	set -e
	case "$rc" in
	0) PASSED_CASES=$((PASSED_CASES + 1)) ;;
	42) MASKED=1 ;;
	*) fail "fix-workspace-perms did not refuse a sensitive /etc mountinfo source (see the FAIL line above)" ;;
	esac
}

echo "Dir-mount ownership smoke test (image: $IMAGE)"

# --- image gate (copied from smoke-test-selfhosted.sh) ------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	if [ -n "${POWBOX_SMOKE_REQUIRE_IMAGE:-}" ]; then
		echo "FAIL: image '$IMAGE' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set — the dir-mount ownership stage requires the image." >&2
		exit 1
	fi
	note_skip "image '$IMAGE' not found"
	echo "Dir-mount stage skipped: image '$IMAGE' not found (build it to exercise the fix-workspace-perms.sh chown path)."
	exit 0
fi

# --- native-Linux gate --------------------------------------------------------
# The bug only manifests on a native-Linux bind mount; Windows/WSL/macOS mounts
# honour node's writes regardless of the displayed owner, and the GNU tooling used
# below (stat -c, chown, mktemp) is Linux-only anyway. Mirrors the .ps1's $IsLinux
# gate so a non-Linux host with root/passwordless sudo (e.g. a macOS CI runner)
# self-skips here instead of hard-failing where the bug cannot reproduce.
if [ "$(uname -s)" != "Linux" ]; then
	note_skip "host is not native Linux ($(uname -s))"
	echo "Dir-mount stage skipped: the native-Linux bind-mount uid bug does not manifest on this OS ($(uname -s) bind mounts honour node's writes)."
	exit 0
fi

# --- root-capability gate -----------------------------------------------------
if [ "$CAN_ROOT" -ne 1 ]; then
	note_skip "no root / passwordless sudo to build a root-owned fixture"
	echo "Dir-mount stage skipped: cannot create a root-owned fixture here (need root or passwordless sudo, e.g. a CI runner)."
	echo "  Locally this is expected — the native-Linux root-owned-mount bug only reproduces where a root-owned path can be made. In CI (task 003) this stage runs for real."
	exit 0
fi

case_all_root
case_mixed_ownership
case_sensitive_skip
case_fix_mountinfo_backstop

if [ "$MASKED" -eq 1 ]; then
	note_skip "host masks the native-Linux uid bug (node could already write the root-owned mount)"
	echo "Dir-mount stage skipped: this host masks the native-Linux bind-mount uid bug (node could already write the root-owned mount). Nothing to assert."
	exit 0
fi

echo "Dir-mount ownership smoke test passed (${PASSED_CASES} case(s))."
