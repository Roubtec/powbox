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
#   5. Host-side (task 053): every mountpoint directory shadow-mounts.sh had to
#      CREATE inherited the ownership of the deepest ancestor that already existed,
#      instead of being left root-owned. This script already runs the real
#      /usr/local/bin/shadow-mounts.sh as root against a real dir-mounted checkout,
#      which is the only place that chown can be exercised for real — the hermetic
#      scripts/test-shadow-mounts-chown.sh covers the decision logic, but not
#      whether a real root-created directory really lands host-owned on a real bind
#      mount. Covered: a SINGLE created component on the ordinary tmpfs path
#      (proj/bin — the .NET artifact shape the chown was written for, whose proj
#      parent already existed), a MULTI-component creation (.claude/worktrees, where
#      two levels are created and the walk has to reach the workspace root), and the
#      SINGLE-component case on the special durable-bind path (.git/worktrees), which
#      takes a different branch through shadow-mounts.sh and so is not redundant.
#      These assertions are deliberately tolerant and are therefore VACUOUS on a
#      squashing filesystem, under a rootless engine, and when the smoke itself runs
#      as root; the latter two are detected and announced. See the block itself.
#
# Privileges: the durable bind is a `mount --bind`, so the container needs
# CAP_SYS_ADMIN + an unconfined seccomp/apparmor profile — exactly the launch-time
# wiring the launcher supplies via compose.shared.yml and that smoke-test-podman.sh
# replicates on the command line. The agent entrypoint is bypassed (--entrypoint),
# so we invoke shadow-mounts.sh directly the way the entrypoint does.
#
# FAIL-CLOSED contract (round-3 review): the whole point of this stage is to guard
# the durable-bind lifecycle, so a regression in that bind must NOT masquerade as a
# skip. Each inner container therefore runs an INDEPENDENT mount-capability preflight
# (a throwaway temp-over-temp `mount --bind` that does NOT touch shadow-mounts.sh /
# bind_git_worktrees) and self-skips (exit 42) ONLY when that preflight proves the
# runtime genuinely cannot bind-mount, or the persistent .worktrees volume is not
# mounted. Once capability is proven, a shadow-mounts.sh failure, a tmpfs fallback, a
# missing mountpoint, or a bind that maps the wrong source is a HARD TEST FAILURE
# (non-42 exit) — the durable-bind regression this stage exists to catch — never a
# skip.
#
# Self-skips (exit 0, no failure) when it cannot meaningfully run:
#   * the agent image is absent — unless POWBOX_SMOKE_REQUIRE_IMAGE is set, then it
#     fails (mirrors the sibling stages' image gate);
#   * the independent preflight proves the host/runtime cannot bind-mount at all
#     (e.g. a rootless engine that blocks `mount --bind` with EPERM), or the
#     persistent .worktrees volume is not mounted — the recreate lifecycle then
#     cannot be exercised, so it self-skips rather than reporting a false pass. A
#     durable bind that fails to materialize AFTER capability is proven is a hard
#     failure, not a skip.
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
# The inner script lives in ONE file that BOTH drivers embed (task 053a): a copy per
# driver is what let the PowerShell mirror ship without the task 053 ownership
# coverage. scripts/smoke-test-worktree-metadata.ps1 reads the same file via
# $PSScriptRoot. See its header for the arg/exit-code contract.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT_FILE="$SCRIPT_DIR/smoke-test-worktree-metadata-container-a.bash"
[ -r "$SETUP_SCRIPT_FILE" ] || fail "the shared Container A script is missing or unreadable: $SETUP_SCRIPT_FILE"
SETUP_SCRIPT="$(cat "$SETUP_SCRIPT_FILE")"

# --- Container B: recreate, re-bind, assert the worktree survived intact ----------
# shellcheck disable=SC2016  # the inner shell expands these, NOT the host
VERIFY_SCRIPT='
set -u
WS="$1"
SLUG="$2"
CONT="$3"
export HOME=/root
git config --global --add safe.directory "*" >/dev/null 2>&1 || true

# Independent mount-capability PREFLIGHT (see Container A): only its failure is a
# legitimate skip. Once it passes, a bind that does not re-materialize on recreate is
# a durable-bind REGRESSION and a HARD FAILURE, never a skip.
pfsrc="$(mktemp -d)"
pfdst="$(mktemp -d)"
if ! mount --bind "$pfsrc" "$pfdst" 2>/dev/null; then
	echo "  skip: runtime cannot perform mount --bind (no CAP_SYS_ADMIN / EPERM) - the recreate lifecycle cannot be exercised here"
	rmdir "$pfdst" "$pfsrc" 2>/dev/null || true
	exit 42
fi
umount "$pfdst" 2>/dev/null || umount -l "$pfdst" 2>/dev/null || true
rmdir "$pfdst" "$pfsrc" 2>/dev/null || true
if ! mountpoint -q "$WS/.worktrees"; then
	echo "  skip: the persistent .worktrees volume is not mounted at $WS/.worktrees - nothing durable to exercise"
	exit 42
fi

# Re-establish the durable bind, as the entrypoint would on the recreated container.
# Capability is proven, so any failure here is a REGRESSION (hard failure, NOT skip).
smerr="$(mktemp)"
if ! /usr/local/bin/shadow-mounts.sh "$WS/.git/worktrees" 2>"$smerr"; then
	echo "FAIL: shadow-mounts.sh failed to re-establish the durable bind on recreate despite mount capability - durable-bind REGRESSION" >&2
	sed "s/^/    shadow-mounts: /" "$smerr" >&2 || true
	exit 1
fi
if ! mountpoint -q "$WS/.git/worktrees"; then
	echo "FAIL: durable bind not re-established on recreate (.git/worktrees is not a mountpoint) - REGRESSION" >&2
	exit 1
fi
fstype="$(findmnt -nro FSTYPE -T "$WS/.git/worktrees" 2>/dev/null || true)"
if [ "$fstype" = tmpfs ]; then
	echo "FAIL: durable bind fell back to tmpfs on recreate despite the persistent .worktrees volume being present - REGRESSION" >&2
	exit 1
fi
# Symmetrical with Container A (defense in depth): prove the RE-established bind maps
# .git/worktrees onto the volume .gitworktrees dir (not merely onto some non-tmpfs
# fs). A fresh sentinel written on the volume side must be visible through
# .git/worktrees; a mismatch means the recreate bind points at the wrong source, so
# the recreate side also fails closed on bind-source, never a skip.
probe=".bindprobe.$$"
if ! : >"$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null; then
	echo "FAIL: cannot write into the volume .gitworktrees dir to verify the recreate bind (REGRESSION)" >&2
	exit 1
fi
if [ ! -e "$WS/.git/worktrees/$probe" ]; then
	rm -f "$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null || true
	echo "FAIL: .git/worktrees does not reflect the volume .gitworktrees dir on recreate - bind maps the wrong source (REGRESSION)" >&2
	exit 1
fi
rm -f "$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null || true
echo "  ok: recreate .git/worktrees bind maps the persistent .worktrees volume (verified maps .gitworktrees)"

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
	# The container may have left empty mountpoint dirs inside the fixture:
	# proj/bin, .claude/worktrees and .git/worktrees (created by shadow-mounts.sh,
	# and — per the ownership assertions below — expected to be invoker-owned) plus
	# .worktrees (created root-owned by the container ENGINE for the named volume).
	# A plain rm clears them when their PARENT is invoker-owned, which is what grants
	# the unlink — true for .git/worktrees and proj/bin (their parents pre-existed on
	# the host) and for .worktrees. It is NOT guaranteed for .claude/worktrees: the
	# .claude parent is itself container-created, so in exactly the regression case
	# these assertions exist to catch (the chown gone, both levels left root-owned)
	# the rm cannot unlink it and the fixture tmpdir leaks. Cosmetic only — a rootful
	# rmdir is not worth invoking here, the run has already FAILED loudly by then, and
	# the leak is a bounded empty dir under TMPDIR. Best-effort regardless: errors are
	# swallowed so cleanup never masks the real failure.
	[ -n "$FIXTURE" ] && rm -rf "$FIXTURE" 2>/dev/null
	docker volume rm -f "$WTVOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/powbox-wtmeta-XXXXXX")"
git -C "$FIXTURE" init -q
printf 'base tracked content\n' >"$FIXTURE/tracked.txt"
# A stand-in project directory for the mountpoint-ownership coverage (task 053):
# it is created HERE, by the invoking host user, so when Container A shadows
# proj/bin the only NEW component is bin and its deepest existing ancestor is this
# invoker-owned proj. That is the .NET artifact shape the chown exists for.
mkdir -p "$FIXTURE/proj"
printf 'stand-in for a project whose bin/ is shadowed\n' >"$FIXTURE/proj/project.marker"
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

# --- Host-side: created mountpoints inherited the tree's ownership (task 053) ---
# shadow-mounts.sh only ever runs via sudo, so a mountpoint it has to CREATE is
# created by ROOT. On a native-Linux bind mount that directory OUTLIVES the
# container once the tmpfs/bind goes away, and if it is left root-owned mode-755
# the host user can afterwards neither populate nor remove it (e.g. a later host
# `dotnet build` writing into bin/obj). Every created component must therefore
# inherit the uid:gid of the deepest ancestor that already existed.
#
# The assertion runs HERE — on the host, after Container A exited — rather than
# inside the container: the container's mount namespace died with it, so the
# tmpfs/bind is no longer stacked on top and a plain stat sees the UNDERLYING
# directory. That keeps the inner script's flow untouched (no unmount-and-restat
# dance) and it measures exactly the real-world consequence the chown exists to
# prevent. The intermediate `.claude` — created but never a mountpoint — is
# asserted inside Container A instead, where no unmount is needed either.
#
# Covered: proj/bin (ONE created component on the ORDINARY tmpfs path — the .NET
# artifact shape the chown was written for, its proj parent created by the host
# invoker above), .claude/worktrees (TWO created components), and .git/worktrees
# (ONE created component, but on the special durable-BIND branch, which reaches the
# mount through bind_git_worktrees instead of the tmpfs line — a different path
# through the script, so not a duplicate of the proj/bin case). NOT .worktrees —
# that mountpoint is created by the container ENGINE for the named volume, never by
# shadow-mounts.sh, so it is legitimately root-owned and is not evidence of anything.
#
# Tolerance: each assertion is EQUALITY with the deepest pre-existing ancestor,
# never "== $(id -u)". On a filesystem where chown is a no-op (a Windows/FUSE bind
# mount) every path reports the same squashed owner, so this passes instead of
# failing spuriously; on a native-Linux mount a missing chown leaves the directory
# root-owned while its ancestor is not, and the assertion fires. Equality also
# subsumes the weaker "must not be root" form whenever the tree's owner is not
# root.
#
# That tolerance has a price, so state the vacuity conditions out loud — all three
# are cases where these checks CANNOT fail and a green run proves nothing:
#   * a squashing filesystem (Windows/FUSE) — every path reports one owner;
#   * a ROOTLESS engine — the container's root maps to the invoker, so even an
#     unchowned directory lands invoker-owned;
#   * the smoke itself run as ROOT on the host — the whole fixture is then
#     root-owned, so ancestor and mountpoint are both root with or without the chown.
# The last two are detected below and announced; the first cannot be probed
# portably. Real teeth come from an unprivileged host user on a rootful Linux
# engine — the native-Linux CI runner, and a stock Linux desktop install.

# GNU (`-c`) vs BSD/macOS (`-f`) stat: a host smoke run may be on either.
owner_of() {
	stat -c '%u:%g' "$1" 2>/dev/null || stat -f '%u:%g' "$1" 2>/dev/null
}

assert_created_mountpoint_owner() {
	local dir="$1" ancestor="$2" label="$3" got want
	[ -e "$dir" ] || fail "mountpoint ownership ($label): shadow-mounts.sh should have created '$dir', but it is absent on the host after the container exited"
	got="$(owner_of "$dir")" || fail "mountpoint ownership ($label): cannot stat '$dir'"
	want="$(owner_of "$ancestor")" || fail "mountpoint ownership ($label): cannot stat '$ancestor'"
	[ "$got" = "$want" ] || fail "mountpoint ownership ($label): '$dir' is owned by $got but its deepest pre-existing ancestor '$ancestor' is owned by $want — the created mountpoint did NOT inherit the tree's ownership. The shadow-mounts.sh mountpoint chown has regressed; on a native-Linux bind mount the host user is left unable to populate or remove that directory."
	echo "  ok: mountpoint ownership ($label) — <fixture>${dir#"$FIXTURE"} inherited $got from its pre-existing ancestor <fixture>${ancestor#"$FIXTURE"}"
}

if ! owner_of "$FIXTURE" >/dev/null 2>&1; then
	# note_skip, not a bare echo: this is a genuine no-coverage case, so it belongs in
	# the umbrella banner rather than scrolling past in the log — the same idiom the
	# runtime self-skips above use. It is a PARTIAL skip (the rest of the stage still
	# runs), and a later whole-stage note_skip legitimately overwrites it, that being
	# the more severe outcome. Practically unreachable — every supported host has GNU
	# or BSD stat — but silence here would be indistinguishable from a real pass.
	note_skip "mountpoint-ownership assertions skipped: this host's stat supports neither 'stat -c' nor 'stat -f'"
	echo "  note: skipping the mountpoint-ownership assertions — this host's stat supports neither 'stat -c' nor 'stat -f'."
else
	# Say out loud when the assertions below cannot fail (see the vacuity conditions
	# above). Both notes are purely informational: never a skip, never a failure — the
	# engine may not answer, and a vacuous pass is still a pass.
	if docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
		echo "  note: this container engine is ROOTLESS — the mountpoint-ownership assertions below are satisfied vacuously (the container's root maps to you, so an unchowned directory would still look invoker-owned). Real coverage comes from a rootful engine, e.g. the native-Linux CI runner."
	fi
	if [ "$(id -u)" = 0 ]; then
		echo "  note: this smoke is running as ROOT on the host — the whole fixture is root-owned, so the mountpoint-ownership assertions below are satisfied vacuously (ancestor and mountpoint are both root with or without the chown). Real coverage comes from an unprivileged host user."
	fi
	assert_created_mountpoint_owner "$FIXTURE/proj/bin" "$FIXTURE/proj" "single created component, tmpfs path"
	assert_created_mountpoint_owner "$FIXTURE/.claude/worktrees" "$FIXTURE" "multi-component creation"
	assert_created_mountpoint_owner "$FIXTURE/.git/worktrees" "$FIXTURE/.git" "single created component, durable-bind path"
fi

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
