#!/usr/bin/env bash
set -euo pipefail

# Smoke-test the DURABLE worktree-metadata lifecycle (task 017): in dir-mounted
# mode a linked git worktree — and its per-worktree admin metadata — must SURVIVE a
# container stop/recreate, because the metadata is bound from the persistent
# .worktrees volume over .git/worktrees instead of living in the tmpfs shadow that
# vanishes on recycle. This is the headline acceptance criterion; the hermetic
# scripts/test-wt-orphan-safety.sh only unit-tests the orphan-reaping SAFETY net,
# not the central bind/survive path, so a broken bind, a commondir/gitdir path that
# does not resolve after recreate, or a metadata dir that lands on the host instead
# of the volume would pass every other test and still ship broken.
#
# What it exercises, end to end, against a REAL built agent image:
#   1. Container A: dir-mount a throwaway git repo at /workspace/repo with a NAMED
#      agent-wt-style volume at /workspace/repo/.worktrees, run the SAME privileged
#      helper the entrypoint uses (/usr/local/bin/shadow-mounts.sh) to bind the
#      volume's .gitworktrees subdir over .git/worktrees, then `git worktree add` a
#      linked worktree under .worktrees/<container>/<slug> and leave it DIRTY — a
#      tracked-file modification AND an untracked new file.
#   2. Container A exits: its mount namespace (and the bind) is torn down; only the
#      persistent volume survives.
#   3. Container B: recreate on the SAME volume + repo, re-establish the bind, and
#      assert the recycled worktree is intact — `git status` works (metadata
#      survived), HEAD is on the worktree branch, and BOTH the tracked modification
#      and the untracked file are still present.
#   4. Host-side: the dir-mounted checkout's real .git/worktrees gained NO container
#      registrations — the bind kept every registration inside the volume, so the
#      host's own git metadata is never polluted by the container's worktrees.
#
# Privileges: the durable bind is a `mount --bind`, so the container needs
# CAP_SYS_ADMIN + an unconfined seccomp/apparmor profile — exactly the launch-time
# wiring the launcher supplies via compose.shared.yml and that smoke-test-podman.sh
# replicates on the command line. The agent entrypoint is bypassed (--entrypoint),
# so we invoke shadow-mounts.sh directly the way the entrypoint does.
#
# Self-skips (exit 0, no failure) when it cannot meaningfully run:
#   * the agent image is absent — unless POWBOX_SMOKE_REQUIRE_IMAGE is set, then it
#     fails (mirrors the sibling stages' image gate);
#   * the host/runtime cannot grant the container the mount privilege to establish
#     the durable bind (e.g. a rootless engine that blocks `mount --bind`, or a
#     fallback to tmpfs because the .worktrees mount is not a persistent volume) —
#     the recreate lifecycle then cannot be exercised, so it self-skips rather than
#     reporting a false pass.
#
# When commands/smoke-test.sh runs this it passes POWBOX_SMOKE_SKIP_MARKER so each
# runtime self-skip is surfaced in the umbrella banner instead of counting silently
# toward "all stages ran"; see note_skip below.

IMAGE="${1:-powbox-agent:latest}"

# Constant in-container paths. Each case runs its own container, so these never
# collide; the host-side fixture and the named volume are per-run unique.
MOUNT="/workspace/powbox-wtmeta-smoke"
CONTAINER_SLUG="smokecont"
WT_SLUG="durable-task"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Record a runtime self-skip reason for the umbrella banner (a no-op when
# POWBOX_SMOKE_SKIP_MARKER is unset, so direct callers keep the plain
# exit-0-on-skip contract). Mirrors scripts/smoke-test-dirmount.sh.
note_skip() {
	if [ -n "${POWBOX_SMOKE_SKIP_MARKER:-}" ]; then
		printf '%s' "$1" >"$POWBOX_SMOKE_SKIP_MARKER" || true
	fi
}

# The privileged run wiring the durable bind needs: CAP_SYS_ADMIN for mount(2) and
# an unconfined seccomp/apparmor profile so the mount syscall is not blocked. Same
# set smoke-test-podman.sh uses for its mount-capable runs. We run as root so
# shadow-mounts.sh (normally invoked via sudo from the entrypoint) can bind-mount.
RUN_ARGS=(
	--rm
	--user root
	--cap-add SYS_ADMIN
	--security-opt seccomp=unconfined
	--security-opt apparmor=unconfined
)

# --- Container A: establish the durable bind, create a dirty linked worktree ------
# Single-quoted so the host leaves the inner shell's $vars alone; it therefore
# contains no single quotes. Positional args: $1 = the dir-mounted repo, $2 = the
# per-worktree branch/slug, $3 = the container subdir under .worktrees.
# Exit codes: 0 = set up a dirty durable worktree; 42 = self-skip (no mount
# privilege / no durable bind); other = genuine failure.
# shellcheck disable=SC2016  # the inner shell expands these, NOT the host
SETUP_SCRIPT='
set -u
WS="$1"
SLUG="$2"
CONT="$3"
export HOME=/root
# The fixture is created on the host by whoever runs the smoke; inside the
# container we touch it as root, so silence git dubious-ownership on the borrowed
# checkout (a throwaway smoke fixture, safe to trust).
git config --global --add safe.directory "*" >/dev/null 2>&1 || true

# Establish the durable metadata bind exactly as the entrypoint does: bind the
# persistent .worktrees volume s .gitworktrees subdir over .git/worktrees.
smerr="$(mktemp)"
if ! /usr/local/bin/shadow-mounts.sh "$WS/.git/worktrees" 2>"$smerr"; then
	echo "  skip: shadow-mounts.sh could not establish the durable bind (no mount privilege on this runtime?)"
	sed "s/^/    shadow-mounts: /" "$smerr" >&2 || true
	exit 42
fi
if ! mountpoint -q "$WS/.git/worktrees"; then
	echo "  skip: .git/worktrees is not a mountpoint after shadow-mounts.sh (bind not established)"
	exit 42
fi
# A tmpfs here means there was no persistent .worktrees volume to co-locate into —
# the honest fallback, but NOT the durable path this stage exists to exercise.
fstype="$(findmnt -nro FSTYPE -T "$WS/.git/worktrees" 2>/dev/null || true)"
if [ "$fstype" = tmpfs ]; then
	echo "  skip: durable bind fell back to tmpfs (no persistent .worktrees volume mounted)"
	exit 42
fi
echo "  ok: durable .git/worktrees bind established from the persistent .worktrees volume"

WTDIR="$WS/.worktrees/$CONT/$SLUG"
if ! git -C "$WS" worktree add -q "$WTDIR" -b "$SLUG" >/dev/null 2>&1; then
	echo "FAIL: git worktree add failed while creating the linked worktree" >&2
	git -C "$WS" worktree add "$WTDIR" -b "$SLUG" >&2 || true
	exit 1
fi
# The admin metadata must have landed in the durable volume (via the bind), not on
# the host checkout.
if [ ! -e "$WS/.worktrees/.gitworktrees/$SLUG/gitdir" ]; then
	echo "FAIL: worktree metadata did not land in the durable volume (.worktrees/.gitworktrees/$SLUG missing)" >&2
	exit 1
fi
# Leave the worktree DIRTY: a tracked modification AND an untracked new file. The
# fixture commit ships tracked.txt, so appending to it is a tracked change.
echo "durable-change-A" >>"$WTDIR/tracked.txt"
echo "untracked-content-A" >"$WTDIR/UNTRACKED_NEW.txt"
echo "  ok: linked worktree created and left dirty (tracked mod + untracked file)"
exit 0
'

# --- Container B: recreate, re-bind, assert the worktree survived intact ----------
# shellcheck disable=SC2016  # the inner shell expands these, NOT the host
VERIFY_SCRIPT='
set -u
WS="$1"
SLUG="$2"
CONT="$3"
export HOME=/root
git config --global --add safe.directory "*" >/dev/null 2>&1 || true

# Re-establish the durable bind, as the entrypoint would on the recreated container.
smerr="$(mktemp)"
if ! /usr/local/bin/shadow-mounts.sh "$WS/.git/worktrees" 2>"$smerr"; then
	echo "  skip: shadow-mounts.sh could not re-establish the durable bind on recreate"
	sed "s/^/    shadow-mounts: /" "$smerr" >&2 || true
	exit 42
fi
mountpoint -q "$WS/.git/worktrees" || { echo "  skip: durable bind not re-established on recreate"; exit 42; }

WTDIR="$WS/.worktrees/$CONT/$SLUG"
[ -d "$WTDIR" ] || { echo "FAIL: the linked worktree dir did not survive recreation ($WTDIR missing)" >&2; exit 1; }

# 1. Metadata survived: git status works in the recycled worktree, and the admin
#    dir is visible again through the re-established bind.
if ! git -C "$WTDIR" status >/dev/null 2>&1; then
	echo "FAIL: git status failed in the recycled worktree — per-worktree metadata did not survive recreation" >&2
	git -C "$WTDIR" status >&2 2>&1 || true
	exit 1
fi
[ -e "$WS/.git/worktrees/$SLUG/gitdir" ] || { echo "FAIL: .git/worktrees/$SLUG metadata not visible after recreate (bind broken?)" >&2; exit 1; }
echo "  ok: git status works in the recycled worktree; per-worktree metadata survived recreate"

# 2. HEAD is still on the worktree branch.
br="$(git -C "$WTDIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
[ "$br" = "$SLUG" ] || { echo "FAIL: recycled worktree HEAD is $br, expected $SLUG" >&2; exit 1; }

# 3. The tracked modification survived (working-tree file lives in the volume).
status="$(git -C "$WTDIR" status --porcelain 2>/dev/null || true)"
printf "%s\n" "$status" | grep -qE "^.M[[:space:]]+tracked\.txt$" || {
	echo "FAIL: the tracked modification to tracked.txt did not survive recreation. git status --porcelain:" >&2
	printf "%s\n" "$status" >&2
	exit 1
}
grep -q "durable-change-A" "$WTDIR/tracked.txt" || { echo "FAIL: tracked.txt content lost after recreation" >&2; exit 1; }

# 4. The untracked file survived.
printf "%s\n" "$status" | grep -qE "^\?\?[[:space:]]+UNTRACKED_NEW\.txt$" || {
	echo "FAIL: the untracked file UNTRACKED_NEW.txt did not survive recreation. git status --porcelain:" >&2
	printf "%s\n" "$status" >&2
	exit 1
}
[ -f "$WTDIR/UNTRACKED_NEW.txt" ] || { echo "FAIL: UNTRACKED_NEW.txt is gone after recreation" >&2; exit 1; }
grep -q "untracked-content-A" "$WTDIR/UNTRACKED_NEW.txt" || { echo "FAIL: UNTRACKED_NEW.txt content lost after recreation" >&2; exit 1; }

echo "  ok: HEAD on $SLUG; tracked modification + untracked file both survived the container recreate"
exit 0
'

echo "Worktree durable-metadata smoke test (image: $IMAGE)"

# --- image gate (mirrors smoke-test-dirmount.sh) ------------------------------
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	if [ -n "${POWBOX_SMOKE_REQUIRE_IMAGE:-}" ]; then
		echo "FAIL: image '$IMAGE' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set — the durable-metadata stage requires the image." >&2
		exit 1
	fi
	note_skip "image '$IMAGE' not found"
	echo "Worktree durable-metadata stage skipped: image '$IMAGE' not found (build it to exercise the recreate lifecycle)."
	exit 0
fi

# --- fixture + volume lifecycle -----------------------------------------------
FIXTURE=""
WTVOL="powbox-smoke-wtmeta-$$"
cleanup() {
	# The container (root) may have left an empty, root-owned .git/worktrees /
	# .worktrees mountpoint dir inside the fixture; a plain rm removes them (their
	# invoker-owned parent grants the unlink). Best-effort either way.
	[ -n "$FIXTURE" ] && rm -rf "$FIXTURE" 2>/dev/null
	docker volume rm -f "$WTVOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/powbox-wtmeta-XXXXXX")"
git -C "$FIXTURE" init -q
printf 'base tracked content\n' >"$FIXTURE/tracked.txt"
git -C "$FIXTURE" -c user.email=smoke@powbox.local -c user.name="powbox smoke" add -A
git -C "$FIXTURE" -c user.email=smoke@powbox.local -c user.name="powbox smoke" commit -qm "init"

docker volume create "$WTVOL" >/dev/null

# --- Container A ---------------------------------------------------------------
echo "Container A — establish durable bind + create a dirty linked worktree"
set +e
docker run "${RUN_ARGS[@]}" \
	-v "${FIXTURE}:${MOUNT}" \
	-v "${WTVOL}:${MOUNT}/.worktrees" \
	--entrypoint /bin/bash "$IMAGE" -c "$SETUP_SCRIPT" powbox-wtmeta "$MOUNT" "$WT_SLUG" "$CONTAINER_SLUG"
rc=$?
set -e
case "$rc" in
0) : ;;
42)
	note_skip "runtime cannot grant the mount privilege for the durable .git/worktrees bind"
	echo "Worktree durable-metadata stage skipped: could not establish the durable bind (see the skip line above). The recreate lifecycle runs for real on a native-Linux CI runner."
	exit 0
	;;
*) fail "Container A could not set up the durable worktree (see the FAIL line above)" ;;
esac

# --- Container B (the recreate) ------------------------------------------------
echo "Container B — recreate on the SAME .worktrees volume + repo, assert survival"
set +e
docker run "${RUN_ARGS[@]}" \
	-v "${FIXTURE}:${MOUNT}" \
	-v "${WTVOL}:${MOUNT}/.worktrees" \
	--entrypoint /bin/bash "$IMAGE" -c "$VERIFY_SCRIPT" powbox-wtmeta "$MOUNT" "$WT_SLUG" "$CONTAINER_SLUG"
rc=$?
set -e
case "$rc" in
0) : ;;
42)
	note_skip "runtime cannot grant the mount privilege for the durable .git/worktrees bind"
	echo "Worktree durable-metadata stage skipped: could not re-establish the durable bind on recreate (see the skip line above)."
	exit 0
	;;
*) fail "the recycled worktree did not survive the container recreate (see the FAIL line above)" ;;
esac

# --- Host-side: no registration leaked onto the dir-mounted checkout -----------
# Inside the container the bind shadowed .git/worktrees, so every registration went
# into the volume. On the host, shadow-mounts.sh mkdir'd the mountpoint before
# binding, so an EMPTY .git/worktrees may exist — but it must hold NO worktree
# registration (no <slug> subdir), proving the container never polluted the host's
# own git metadata.
host_wt="$FIXTURE/.git/worktrees"
if [ -d "$host_wt" ]; then
	leaked="$(find "$host_wt" -mindepth 1 -maxdepth 1 2>/dev/null || true)"
	[ -z "$leaked" ] || fail "the dir-mounted checkout's .git/worktrees leaked container registrations: $leaked"
fi
echo "  ok: the host checkout's .git/worktrees gained no container registrations"

echo "Worktree durable-metadata smoke test passed (recreate lifecycle verified)."
