#!/usr/bin/env bash
set -euo pipefail

# Smoke-test the native-Linux dir-mount ownership fix (PR #55).
#
# On a NATIVE-LINUX host a bind-mounted repo keeps its host uid/gid. When that is
# root (a repo under /root, or a host running powbox as root) the mount is
# root:root inside the container and the `node` agent (uid 1000) cannot write the
# working tree or .git — every `touch`/`git pull`/`git commit` fails with EACCES
# (`cannot open '.git/FETCH_HEAD': Permission denied`). entrypoint-core.sh probes
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
#   * it cannot create a genuinely root-owned fixture (no root / no passwordless
#     sudo) — the local-dev case; in CI (task 003) it runs as root for real;
#   * the host masks the native-Linux uid bug (node can already write a root-owned
#     mount — Windows/WSL/macOS FUSE, or a uid-matched host): there is nothing to
#     assert.

IMAGE="${1:-powbox-agent:latest}"

# A constant in-container mount point. Each case runs its own --rm container, so
# the path never collides; the host-side fixture dir is always a unique mktemp.
MOUNT="/workspace/powbox-dirmount-smoke"

fail() {
	echo "FAIL: $*" >&2
	exit 1
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
# 4. ... and a git write succeeds — the root-owned .git is the thing that broke
#    first (cannot open .git/FETCH_HEAD). --allow-empty needs no prior commit.
if ! git -C "$WS" -c user.email=smoke@powbox.local -c user.name="powbox smoke" \
	commit --allow-empty -m "powbox dirmount smoke" >/dev/null 2>&1; then
	echo "FAIL: node git commit failed after the fix (.git still not writable by node?)" >&2
	exit 1
fi
# 5. the helper actually claimed the tree for node (uid 1000), end to end.
owner="$(stat -c %u "${WS}/smoke-write" 2>/dev/null || echo "?")"
if [ "$owner" != "1000" ]; then
	echo "FAIL: smoke-write owned by uid ${owner} after the fix, expected node (1000)" >&2
	exit 1
fi
echo "  ok: node can touch + git-commit after the fix, and the tree is node-owned (uid 1000)"
exit 0
'

PASSED_CASES=0
MASKED=0

# run_dirmount_case — run ASSERT_SCRIPT against $fixture and map its exit code.
# Streams the in-container ok/FAIL/skip lines live. Sets MASKED on a self-skip.
run_dirmount_case() {
	local fixture="$1"
	set +e
	docker run --rm \
		--user node \
		-v "${fixture}:${MOUNT}" \
		--entrypoint /bin/bash "$IMAGE" -c "$ASSERT_SCRIPT" powbox-dirmount "$MOUNT"
	local rc=$?
	set -e
	case "$rc" in
	0)
		# Host-side: the helper claimed the tree for node end to end. stat as root
		# — the chowned fixture (mktemp -d is mode 700) may not be traversable by a
		# non-owner sudo caller.
		local host_owner
		host_owner="$(as_root stat -c %u "${fixture}/smoke-write" 2>/dev/null || echo '?')"
		[ "$host_owner" = "1000" ] ||
			fail "host-side smoke-write owned by uid ${host_owner}, expected node (1000)"
		echo "  ok: host-side file is node-owned (uid 1000) after the run"
		PASSED_CASES=$((PASSED_CASES + 1))
		;;
	42)
		MASKED=1
		;;
	*)
		fail "node could not write the dir-mounted tree after the entrypoint fix (see the FAIL line above)"
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

# ── Task 007 extension seam ───────────────────────────────────────────────────
# Task 007 adds a SECOND case here — "mixed-ownership": a node-owned repo ROOT
# with nested root-owned files (a tracked file plus a .git/objects/<xx> dir
# chowned to root, simulating a host `sudo git pull`). It reuses make_git_fixture
# / as_root / run_dirmount_case below, but mutates ownership differently (leave the
# root node-owned; chown only the nested entries to root) and needs its own
# self-heal step + assertion. It is RED until 007's self-heal logic lands — 005's
# root-level write probe sees a node-owned root, writes succeed, and the nested
# root-owned files are missed — so it is deliberately NOT wired here. Task 007 owns
# delivering and gating that case. DO NOT enable the mixed-ownership case as 005.
# (Add e.g. a case_mixed_ownership function alongside case_all_root and invoke it
# from the run section below.)

echo "Dir-mount ownership smoke test (image: $IMAGE)"

# --- image gate (copied from smoke-test-selfhosted.sh) ------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	if [ -n "${POWBOX_SMOKE_REQUIRE_IMAGE:-}" ]; then
		echo "FAIL: image '$IMAGE' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set — the dir-mount ownership stage requires the image." >&2
		exit 1
	fi
	echo "Dir-mount stage skipped: image '$IMAGE' not found (build it to exercise the entrypoint chown path)."
	exit 0
fi

# --- root-capability gate -----------------------------------------------------
if [ "$CAN_ROOT" -ne 1 ]; then
	echo "Dir-mount stage skipped: cannot create a root-owned fixture here (need root or passwordless sudo, e.g. a CI runner)."
	echo "  Locally this is expected — the native-Linux root-owned-mount bug only reproduces where a root-owned path can be made. In CI (task 003) this stage runs for real."
	exit 0
fi

case_all_root

if [ "$MASKED" -eq 1 ]; then
	echo "Dir-mount stage skipped: this host masks the native-Linux bind-mount uid bug (node could already write the root-owned mount). Nothing to assert."
	exit 0
fi

echo "Dir-mount ownership smoke test passed (${PASSED_CASES} case(s))."
