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
#      mount. Covered: a SINGLE created component (.git/worktrees, whose .git parent
#      already existed) and a MULTI-component creation (.claude/worktrees, where two
#      levels are created and the walk has to reach the workspace root).
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
# Single-quoted so the host leaves the inner shell's $vars alone; it therefore
# contains no single quotes. Positional args: $1 = the dir-mounted repo, $2 = the
# per-worktree branch/slug, $3 = the container subdir under .worktrees.
# Exit codes: 0 = set up a dirty durable worktree; 42 = self-skip, emitted ONLY by
# the independent capability preflight (no bind-mount capability / no persistent
# .worktrees volume); any OTHER non-zero = genuine failure, INCLUDING a durable-bind
# regression detected after the preflight proved the runtime can mount.
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

# Independent mount-capability PREFLIGHT (does NOT touch shadow-mounts.sh /
# bind_git_worktrees): a throwaway temp-over-temp mount --bind with the same cap
# wiring. ONLY its failure is a legitimate "cannot test here" skip (exit 42), so a
# regression in the durable bind can no longer masquerade as a missing capability.
pfsrc="$(mktemp -d)"
pfdst="$(mktemp -d)"
if ! mount --bind "$pfsrc" "$pfdst" 2>/dev/null; then
	echo "  skip: runtime cannot perform mount --bind (no CAP_SYS_ADMIN / EPERM) - the durable-bind lifecycle cannot be exercised here"
	rmdir "$pfdst" "$pfsrc" 2>/dev/null || true
	exit 42
fi
umount "$pfdst" 2>/dev/null || umount -l "$pfdst" 2>/dev/null || true
rmdir "$pfdst" "$pfsrc" 2>/dev/null || true
# The persistent .worktrees volume must genuinely be mounted; otherwise there is
# nothing durable to co-locate into (a legit skip). The outer driver always mounts it.
if ! mountpoint -q "$WS/.worktrees"; then
	echo "  skip: the persistent .worktrees volume is not mounted at $WS/.worktrees - nothing durable to exercise"
	exit 42
fi
echo "  ok: mount capability confirmed and the persistent .worktrees volume is present (preflight)"

# Capability + volume are established. From HERE any failure to materialize the
# durable bind is a REGRESSION and a HARD FAILURE (exit 1, NOT a skip) - the case this
# stage exists to catch. Establish the bind exactly as the entrypoint does: bind the
# .gitworktrees subdir of the persistent .worktrees volume over .git/worktrees.
smerr="$(mktemp)"
if ! /usr/local/bin/shadow-mounts.sh "$WS/.git/worktrees" 2>"$smerr"; then
	echo "FAIL: shadow-mounts.sh failed to establish the durable bind despite mount capability being present - durable-bind REGRESSION" >&2
	sed "s/^/    shadow-mounts: /" "$smerr" >&2 || true
	exit 1
fi
if ! mountpoint -q "$WS/.git/worktrees"; then
	echo "FAIL: .git/worktrees is not a mountpoint after shadow-mounts.sh - the durable bind did not materialize (REGRESSION)" >&2
	exit 1
fi
# A tmpfs here means shadow-mounts.sh fell back instead of binding the persistent
# volume - a regression now that capability + volume are both proven present.
fstype="$(findmnt -nro FSTYPE -T "$WS/.git/worktrees" 2>/dev/null || true)"
if [ "$fstype" = tmpfs ]; then
	echo "FAIL: durable bind fell back to tmpfs despite the persistent .worktrees volume being present - durable-bind REGRESSION" >&2
	exit 1
fi
# Prove the bind maps .git/worktrees onto the volume .gitworktrees dir (not merely
# onto some non-tmpfs fs): a sentinel written on the volume side must be visible
# through .git/worktrees; a mismatch means the bind points at the wrong source.
probe=".bindprobe.$$"
if ! : >"$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null; then
	echo "FAIL: cannot write into the volume .gitworktrees dir to verify the durable bind (REGRESSION)" >&2
	exit 1
fi
if [ ! -e "$WS/.git/worktrees/$probe" ]; then
	rm -f "$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null || true
	echo "FAIL: .git/worktrees does not reflect the volume .gitworktrees dir - durable bind maps the wrong source (REGRESSION)" >&2
	exit 1
fi
rm -f "$WS/.worktrees/.gitworktrees/$probe" 2>/dev/null || true
echo "  ok: durable .git/worktrees bind established from the persistent .worktrees volume (verified maps .gitworktrees)"

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

# Mountpoint-ownership coverage (task 053), MULTI-component case. $WS/.git/worktrees
# above created ONE component (its .git parent already existed); this target has to
# create TWO ($WS/.claude and $WS/.claude/worktrees), so shadow-mounts.sh must walk
# up past both to $WS and hand that owner to each. It is also a real powbox shadow:
# .claude/worktrees is the harness worktree root the entrypoint tmpfs-shadows.
# Mount capability is already proven above, so a failure here is a hard failure.
if ! /usr/local/bin/shadow-mounts.sh "$WS/.claude/worktrees" 2>"$smerr"; then
	echo "FAIL: shadow-mounts.sh failed on the multi-component target $WS/.claude/worktrees despite mount capability being present" >&2
	sed "s/^/    shadow-mounts: /" "$smerr" >&2 || true
	exit 1
fi
if ! mountpoint -q "$WS/.claude/worktrees"; then
	echo "FAIL: $WS/.claude/worktrees is not a mountpoint after shadow-mounts.sh - the multi-component shadow did not materialize" >&2
	exit 1
fi
# The INTERMEDIATE $WS/.claude was created but is not itself a mountpoint, so its
# ownership is readable right here with no unmount needed. The two mountpoints
# themselves are asserted on the host once this container exits (see below).
own="$(stat -c %u:%g "$WS/.claude" 2>/dev/null || echo "?")"
parent="$(stat -c %u:%g "$WS" 2>/dev/null || echo "??")"
if [ "$own" != "$parent" ]; then
	echo "FAIL: the created intermediate directory $WS/.claude is owned by $own but its pre-existing parent $WS is owned by $parent - the shadow-mounts.sh mountpoint chown REGRESSED" >&2
	exit 1
fi
echo "  ok: multi-component shadow created; the intermediate .claude inherited the tree owner ($own)"
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
	# .git/worktrees and .claude/worktrees (created by shadow-mounts.sh, and — per
	# the ownership assertions below — expected to be invoker-owned) plus
	# .worktrees (created root-owned by the container ENGINE for the named volume).
	# A plain rm removes them either way, since their invoker-owned parent grants
	# the unlink. Best-effort regardless.
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
# Covered: .git/worktrees (ONE created component, its .git parent pre-existed) and
# .claude/worktrees (TWO created components). NOT .worktrees — that mountpoint is
# created by the container ENGINE for the named volume, never by shadow-mounts.sh,
# so it is legitimately root-owned and is not evidence of anything.
#
# Tolerance: each assertion is EQUALITY with the deepest pre-existing ancestor,
# never "== $(id -u)". On a filesystem where chown is a no-op (a Windows/FUSE bind
# mount) every path reports the same squashed owner, so this passes instead of
# failing spuriously; on a native-Linux mount a missing chown leaves the directory
# root-owned while its ancestor is not, and the assertion fires. Equality also
# subsumes the weaker "must not be root" form whenever the tree's owner is not
# root. Under a ROOTLESS engine the whole tree maps to the invoker either way, so
# the check is satisfied but vacuous — the native-Linux CI runner (rootful Docker)
# is where it has teeth.

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
	echo "  ok: mountpoint ownership ($label) — <fixture>/${dir#"$FIXTURE"/} inherited $got from its pre-existing ancestor <fixture>/${ancestor#"$FIXTURE"/}"
}

if ! owner_of "$FIXTURE" >/dev/null 2>&1; then
	echo "  note: skipping the mountpoint-ownership assertions — this host's stat supports neither 'stat -c' nor 'stat -f'."
else
	assert_created_mountpoint_owner "$FIXTURE/.git/worktrees" "$FIXTURE/.git" "single created component"
	assert_created_mountpoint_owner "$FIXTURE/.claude/worktrees" "$FIXTURE" "multi-component creation"
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
