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
# Like scripts/smoke-test-selfhosted.sh's Stage B, this validates the baked helper
# + its sudoers wiring in isolation (it invokes /usr/local/bin/fix-workspace-perms.sh
# by the exact path and sudo mechanism entrypoint-core.sh uses), not the full
# entrypoint chain — the firewall/gh/shadow setup needs the launcher's compose
# wiring and is out of scope here.
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
# 2. The entrypoint-equivalent fix: the sudo-allowlisted root helper, invoked by
#    the exact path entrypoint-core.sh uses. A dropped sudoers entry or a renamed
#    helper fails here.
if ! sudo /usr/local/bin/fix-workspace-perms.sh "$WS"; then
	echo "FAIL: sudo fix-workspace-perms.sh failed (dropped sudoers entry or renamed/missing helper?)" >&2
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
# Same exit-code contract as ASSERT_SCRIPT (0 passed / 42 masked / other failure). The
# node-owned root means the root-level write probe ASSERT_SCRIPT uses would PASS here, so
# this instead probes the nested root-owned tracked file — the exact thing the mixed case
# breaks (and which a host masking the uid bug would still let node write).
# shellcheck disable=SC2016  # the inner shell expands these, NOT the host
ASSERT_SCRIPT_MIXED='
set -u
WS="$1"
NESTED="${WS}/nested.txt"
# 1. Ground-truth write probe as node BEFORE the fix: node must be UNABLE to write the
#    nested root-owned tracked file (uid 0, mode 644). A platform that masks the
#    native-Linux uid bug lets node write it regardless of owner -> nothing to assert,
#    self-skip (42).
if echo masked 2>/dev/null >>"$NESTED"; then
	echo "  skip: node can already write the nested root-owned file (this host masks the native-Linux uid bug)"
	exit 42
fi
echo "  ok: node cannot write the nested root-owned tracked file before the fix (EACCES as expected)"
# 2. The entrypoint-equivalent fix on a NODE-owned root, by the exact path/sudo mechanism
#    entrypoint-core.sh uses. Pre-007 the helper refuses a non-root root and exits non-zero
#    (the revert signal); post-007 it re-owns just the nested uid-0 entries.
if ! sudo /usr/local/bin/fix-workspace-perms.sh "$WS"; then
	echo "FAIL: sudo fix-workspace-perms.sh did not self-heal the node-owned root with nested root-owned files (007 helper node-owned-root path reverted, or dropped sudoers entry?)" >&2
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
# missed; this case is RED until 007's entrypoint nested-uid-0 detection + the
# helper's node-owned-root path land. It reuses make_git_fixture / as_root /
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

if [ "$MASKED" -eq 1 ]; then
	note_skip "host masks the native-Linux uid bug (node could already write the root-owned mount)"
	echo "Dir-mount stage skipped: this host masks the native-Linux bind-mount uid bug (node could already write the root-owned mount). Nothing to assert."
	exit 0
fi

echo "Dir-mount ownership smoke test passed (${PASSED_CASES} case(s))."
