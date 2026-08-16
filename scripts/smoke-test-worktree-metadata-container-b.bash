#!/usr/bin/env bash
# Container B of the durable worktree-metadata smoke stage: recreate on the SAME
# .worktrees volume and repo, re-establish the durable .git/worktrees bind, and assert
# the linked worktree survived the container recycle intact.
#
# This file is SOURCE TEXT, not a program to run. Both drivers of the stage --
# scripts/smoke-test-worktree-metadata.sh and its PowerShell mirror
# scripts/smoke-test-worktree-metadata.ps1 -- read it verbatim and hand it to
# `docker run ... --entrypoint /bin/bash <image> -c "<this file>" powbox-wtmeta ...`,
# so it always runs INSIDE the throwaway container, never on the host. It lives in
# ONE file for the same reason its Container A sibling does (task 053a): a copy per
# driver is what let the PowerShell mirror miss the task 053 ownership coverage for a
# release, and the two Container B copies had already started drifting apart in
# comments and punctuation when task 053b merged them.
# The shebang is consequently never honoured. It is here so shellcheck reads this as
# bash -- Tier 0 lints non-`.sh` tracked files by matching their shebang -- and it
# costs nothing, since `bash -c` treats it as a comment. The file is deliberately NOT
# executable: running it on a host would point shadow-mounts.sh at host paths.
#
# Contract with BOTH drivers (change it in both):
#   * positional args: $1 = the dir-mounted repo, $2 = the per-worktree branch/slug,
#     $3 = the container subdir under .worktrees;
#   * Container A must already have run against the same repo + .worktrees volume, so
#     the dirty linked worktree this asserts on exists to be recycled;
#   * exit codes: 0 = the recycled worktree survived intact; 42 = self-skip, emitted
#     ONLY by the independent capability preflight (no bind-mount capability / no
#     persistent .worktrees volume); any OTHER non-zero = genuine failure, INCLUDING
#     a durable-bind regression detected after the preflight proved the runtime can
#     mount;
#   * LF line endings only: a CR survives into the `bash -c` payload and breaks it.
#     .gitattributes pins LF, and the PowerShell driver strips CRLF defensively in
#     case a checkout mangles it anyway.

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
