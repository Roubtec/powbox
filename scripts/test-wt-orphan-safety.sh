#!/usr/bin/env bash
# Unit + integration tests for safe worktree-orphan handling (task 017).
#
# Focus: with DURABLE worktree metadata, a recycled worktree is reused; a dir
# that is NOT a live worktree (partial create, or a pre-durable-metadata dir
# whose tmpfs .git/worktrees was lost) must be reaped SAFELY — empty dirs
# deleted, NON-EMPTY dirs preserved (moved to a quarantine dir), never rm -rf'd.
# This guards the acceptance criterion that the sole surviving copy of dirty
# work is never deleted just because its git metadata disappeared.
#
# Covers:
#   * wt-common.sh wt_reap_orphan_dir directly (empty -> pruned, non-empty ->
#     quarantined with contents preserved). wt-bootstrap's prune loop uses this
#     exact function, so its safety is covered here without the mountpoint checks
#     wt-bootstrap needs (those require a real image + volumes — see the smoke).
#   * wt-enter and wt-remove end-to-end against a real temp git repo, with a
#     dead-metadata orphan simulated by deleting .git/worktrees/<slug>.
#
# Runs directly against the repo copies — no image build needed. Requires bash
# and git on PATH (present in the agent image).
#
# The smoke harness re-runs this against the BAKED helpers by pointing the three
# override vars at /usr/local/bin (matching how test-sensitive-host-path.sh is
# smoke-driven): POWBOX_WT_COMMON / POWBOX_WT_ENTER / POWBOX_WT_REMOVE. wt-enter
# and wt-remove locate wt-common.sh via their own sibling dir, so pointing them at
# the baked binaries automatically exercises the baked wt-common too.
#
# Usage: scripts/test-wt-orphan-safety.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SHARED="$SCRIPT_DIR/../docker/shared"
WT_COMMON="${POWBOX_WT_COMMON:-$SHARED/wt-common.sh}"
WT_ENTER="${POWBOX_WT_ENTER:-$SHARED/wt-enter}"
WT_REMOVE="${POWBOX_WT_REMOVE:-$SHARED/wt-remove}"

for f in "$WT_COMMON" "$WT_ENTER" "$WT_REMOVE"; do
	[ -f "$f" ] || {
		echo "FATAL: missing $f" >&2
		exit 1
	}
done

pass=0
fail=0
ok() {
	pass=$((pass + 1))
	echo "ok - $1"
}
no() {
	fail=$((fail + 1))
	echo "NOT OK - $1" >&2
}

WORK_ROOT="$(mktemp -d)"
trap 'rm -rf "$WORK_ROOT"' EXIT

export CONTAINER_NAME="testcont"

# ---------------------------------------------------------------------------
# Unit: wt_reap_orphan_dir
# ---------------------------------------------------------------------------
# shellcheck source=docker/shared/wt-common.sh
. "$WT_COMMON"

# Empty dir -> pruned (deleted).
u1="$WORK_ROOT/u1/.worktrees/$CONTAINER_NAME/empty"
mkdir -p "$u1"
out="$(wt_reap_orphan_dir "$u1")"
if [ "$out" = "pruned" ] && [ ! -e "$u1" ]; then
	ok "empty orphan is pruned and removed"
else
	no "empty orphan: out='$out' exists=$([ -e "$u1" ] && echo yes || echo no)"
fi

# Non-empty dir -> quarantined; contents preserved; original gone.
u2root="$WORK_ROOT/u2"
u2="$u2root/.worktrees/$CONTAINER_NAME/dirty"
mkdir -p "$u2"
echo "precious uncommitted work" >"$u2/UNSAVED.txt"
out="$(wt_reap_orphan_dir "$u2")"
dest="${out#quarantined:}"
dest_ok=false
case "$dest" in "$u2root/.worktrees/.orphaned/$CONTAINER_NAME/dirty."*) dest_ok=true ;; esac
case "$out" in
quarantined:*)
	if [ ! -e "$u2" ] &&
		[ -f "$dest/UNSAVED.txt" ] &&
		[ "$(cat "$dest/UNSAVED.txt")" = "precious uncommitted work" ] &&
		[ "$dest_ok" = true ]; then
		ok "non-empty orphan is quarantined with contents preserved"
	else
		no "non-empty orphan quarantine mismatch: dest='$dest'"
	fi
	;;
*)
	no "non-empty orphan not quarantined: out='$out'"
	;;
esac

# ---------------------------------------------------------------------------
# Integration helpers
# ---------------------------------------------------------------------------
git_quiet() { git -c init.defaultBranch=main -c user.email=t@t -c user.name=t "$@"; }

# make_repo <name> -> echoes ROOT of a fresh repo with one commit.
make_repo() {
	local root="$WORK_ROOT/$1"
	mkdir -p "$root"
	git_quiet -C "$root" init -q
	echo seed >"$root/seed.txt"
	git_quiet -C "$root" add -A
	git_quiet -C "$root" commit -qm init
	echo "$root"
}

# break_metadata <root> <slug> — simulate a recycle that lost tmpfs .git/worktrees
# metadata: delete the admin dir so the working tree's .git pointer dangles.
break_metadata() {
	rm -rf "$1/.git/worktrees/$2"
}

# ---------------------------------------------------------------------------
# Integration: wt-enter reuses a LIVE worktree (durable-metadata happy path)
# ---------------------------------------------------------------------------
R1="$(make_repo r1)"
WB1="$R1/.worktrees/$CONTAINER_NAME"
git_quiet -C "$R1" worktree add -q "$WB1/task-a" -b task-a >/dev/null 2>&1
if out="$(cd "$R1" && bash "$WT_ENTER" task-a task-a 2>/dev/null)" && [ "$out" = "$WB1/task-a" ]; then
	ok "wt-enter reuses a live worktree (durable metadata survives)"
else
	no "wt-enter did not reuse live worktree: out='${out:-}'"
fi

# ---------------------------------------------------------------------------
# Integration: wt-enter preserves a dead-metadata dirty orphan, recreates fresh
# ---------------------------------------------------------------------------
R2="$(make_repo r2)"
WB2="$R2/.worktrees/$CONTAINER_NAME"
git_quiet -C "$R2" worktree add -q "$WB2/task-b" -b task-b >/dev/null 2>&1
echo "dirty work" >"$WB2/task-b/UNSAVED.txt"
break_metadata "$R2" task-b
# Orphan confirmed (git no longer recognises it):
if git -C "$WB2/task-b" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	no "precondition: task-b should be a dead-metadata orphan but git still recognises it"
else
	if out="$(cd "$R2" && bash "$WT_ENTER" task-b task-b 2>/dev/null)" &&
		[ "$out" = "$WB2/task-b" ] &&
		git -C "$WB2/task-b" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		# The recreated worktree is fresh (no UNSAVED.txt), and the dirty work was
		# preserved under the quarantine dir rather than deleted.
		q="$(find "$R2/.worktrees/.orphaned/$CONTAINER_NAME" -name UNSAVED.txt -type f 2>/dev/null | head -1)"
		if [ -n "$q" ] && [ "$(cat "$q")" = "dirty work" ] && [ ! -f "$WB2/task-b/UNSAVED.txt" ]; then
			ok "wt-enter quarantines dead-metadata dirty orphan and recreates fresh"
		else
			no "wt-enter: dirty work not preserved in quarantine (q='${q:-}')"
		fi
	else
		no "wt-enter did not recreate task-b: out='${out:-}'"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: wt-remove preserves a dead-metadata dirty orphan (never rm -rf)
# ---------------------------------------------------------------------------
R3="$(make_repo r3)"
WB3="$R3/.worktrees/$CONTAINER_NAME"
git_quiet -C "$R3" worktree add -q "$WB3/task-c" -b task-c >/dev/null 2>&1
echo "dirty work c" >"$WB3/task-c/UNSAVED.txt"
break_metadata "$R3" task-c
if (cd "$R3" && bash "$WT_REMOVE" task-c >/dev/null 2>&1); then
	q="$(find "$R3/.worktrees/.orphaned/$CONTAINER_NAME" -name UNSAVED.txt -type f 2>/dev/null | head -1)"
	if [ ! -e "$WB3/task-c" ] && [ -n "$q" ] && [ "$(cat "$q")" = "dirty work c" ]; then
		ok "wt-remove quarantines a dead-metadata dirty orphan instead of deleting it"
	else
		no "wt-remove: orphan not safely preserved (q='${q:-}', still=$([ -e "$WB3/task-c" ] && echo yes || echo no))"
	fi
else
	no "wt-remove failed on a dead-metadata orphan"
fi

# ---------------------------------------------------------------------------
# Integration: wt-remove on an already-absent slug is a clean no-op (idempotent).
# (The empty-dir prune branch of wt_reap_orphan_dir is exercised at the unit
# level above; a truly empty leftover dir with no dangling .git is seen by git as
# part of the PARENT work tree, so it never reaches the reap path.)
# ---------------------------------------------------------------------------
R4="$(make_repo r4)"
if (cd "$R4" && bash "$WT_REMOVE" never-existed >/dev/null 2>&1) &&
	[ ! -d "$R4/.worktrees/.orphaned" ]; then
	ok "wt-remove on an absent slug is a clean no-op"
else
	no "wt-remove on an absent slug did not succeed cleanly"
fi

echo
echo "wt-orphan-safety: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
