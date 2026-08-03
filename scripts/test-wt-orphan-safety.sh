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
#   * wt-enter's branch-conflict diagnosis (task 039): when <branch> is already
#     checked out, the error must name the blocking worktree — and say plainly
#     when that blocker is the SHARED primary checkout, the case agents keep
#     misreading as a stale worktree — while stdout stays empty on failure. The
#     blocker is also named when an interrupted rebase or a bisect leaves the
#     holding worktree reporting as `detached`, and the remedy offered must not
#     destroy work: wt-remove only where it applies, "finish or abort it" where
#     an operation is in flight. The diagnosis stays SILENT when the blocker git
#     names is wt-enter's own destination, so git's prune/remove advice stands.
#   * wt-common.sh wt_branch_held_by_operation and wt_operation_in_flight against
#     fabricated operation state, pinned to what real git does with the same
#     state.
#   * wt-common.sh wt_worktree_for_branch reporting the blocker and its operation
#     state (none / in-flight / unknown) from ONE scan, so wt-enter never
#     re-probes to choose a remedy — and never answers an UNVERIFIED state with a
#     remedy that deletes the worktree.
#
# WHY each expectation is what it is (git's own precedence, its object-id
# parsing, its bare stat()) is documented once, in docker/shared/wt-common.sh.
# This file pins the OUTCOMES and deliberately does not restate the rationale.
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
# Unit: wt_branch_held_by_operation must read a DETACHED worktree's operation
# state the way GIT reads it, because git is what decides whether the branch may
# be checked out again. Each case states the fabricated state and what real git
# does with it (ALLOWS / REFUSES a second checkout of the same branch); the
# reasoning is in wt-common.sh.
# ---------------------------------------------------------------------------
RU="$(make_repo ru)"
git_quiet -C "$RU" branch foo
git_quiet -C "$RU" worktree add -q --detach "$RU/w" >/dev/null 2>&1
GDU="$RU/.git/worktrees/w"

# `git am` (rebase-apply + `applying`) beside a stale rebase-merge: git ALLOWS.
mkdir -p "$GDU/rebase-merge" "$GDU/rebase-apply"
printf 'refs/heads/foo\n' >"$GDU/rebase-merge/head-name"
printf 'refs/heads/foo\n' >"$GDU/rebase-apply/head-name"
: >"$GDU/rebase-apply/applying"
if wt_branch_held_by_operation "$RU/w" foo; then
	no "a git am beside a stale rebase-merge must not count as holding the branch (git allows the checkout)"
else
	ok "operation state honours git's rebase-apply-before-rebase-merge precedence"
fi
rm -rf "$GDU/rebase-merge" "$GDU/rebase-apply"

# A real apply-backend rebase (no `applying` marker): git REFUSES.
mkdir -p "$GDU/rebase-apply"
printf 'refs/heads/foo\n' >"$GDU/rebase-apply/head-name"
if wt_branch_held_by_operation "$RU/w" foo; then
	ok "an apply-backend rebase is recognised as holding the branch"
else
	no "apply-backend rebase not recognised as holding the branch"
fi
rm -rf "$GDU/rebase-apply"

# NON-directory rebase-apply beside a rebase-merge naming the branch: git stops
# at the apply backend, finds no head-name, and ALLOWS.
mkdir -p "$GDU/rebase-merge"
printf 'refs/heads/foo\n' >"$GDU/rebase-merge/head-name"
printf 'junk\n' >"$GDU/rebase-apply"
if wt_branch_held_by_operation "$RU/w" foo; then
	no "a non-directory rebase-apply must stop the scan like git's stat() does (git allows the checkout)"
else
	ok "a non-directory rebase-apply degrades to unknown instead of falling through"
fi
rm -f "$GDU/rebase-apply"

# DANGLING-SYMLINK rebase-apply: stat() follows and fails, so git falls through
# to rebase-merge and REFUSES.
ln -s /nonexistent-rebase-apply-target "$GDU/rebase-apply"
if wt_branch_held_by_operation "$RU/w" foo; then
	ok "a dangling-symlink rebase-apply falls through to rebase-merge, as stat() does"
else
	no "a dangling-symlink rebase-apply must not hide the rebase-merge state (git refuses the checkout)"
fi
rm -rf "$GDU/rebase-apply" "$GDU/rebase-merge"

# BISECT_START in refs/heads/ form (git writes the bare name but strips the
# prefix on read): git REFUSES.
: >"$GDU/BISECT_LOG"
printf 'refs/heads/foo\n' >"$GDU/BISECT_START"
if wt_branch_held_by_operation "$RU/w" foo; then
	ok "a BISECT_START written in refs/heads/ form is recognised (git strips the prefix too)"
else
	no "BISECT_START in refs/heads/ form not recognised as holding the branch"
fi

# A bisect from a detached HEAD records the object id; git abbreviates it before
# comparing, so it can never match a branch of that name (and a 40-hex refname is
# unusable in git anyway). Comparing the raw value would be wrong either way.
HEXB=0123456789abcdef0123456789abcdef01234567
printf '%s\n' "$HEXB" >"$GDU/BISECT_START"
if wt_branch_held_by_operation "$RU/w" "$HEXB"; then
	no "a full object id in BISECT_START must not match a same-named branch"
else
	ok "a full object id in BISECT_START is treated as a detached start, not a branch"
fi

# get_oid_hex() is CASE-INSENSITIVE: a mixed-case object id is a detached start.
printf '%s\n' "0123456789ABCDEF0123456789abcdef01234567" >"$GDU/BISECT_START"
if wt_branch_held_by_operation "$RU/w" "0123456789ABCDEF0123456789abcdef01234567"; then
	no "a mixed-case object id in BISECT_START must not match a same-named branch"
else
	ok "object-id recognition in BISECT_START is case-insensitive, as git's is"
fi

# 41+ hex digits, or 40 with trailing junk: an object id to git yet a legal
# branch name — git ALLOWS the second checkout of the same-named branch.
for oidish in \
	0123456789abcdef0123456789abcdef0123456789abc \
	0123456789abcdef0123456789abcdef01234567zz; do
	printf '%s\n' "$oidish" >"$GDU/BISECT_START"
	if wt_branch_held_by_operation "$RU/w" "$oidish"; then
		no "BISECT_START '$oidish' (${#oidish} chars) must not match a same-named branch (git allows the checkout)"
	else
		ok "a ${#oidish}-char BISECT_START opening with a full object id is treated as an id, not a branch"
	fi
done

# Below the hash width a hex string is just a branch name: git REFUSES. The
# threshold must not over-reach and lose a real diagnosis.
HEX39=0123456789abcdef0123456789abcdef0123456
printf '%s\n' "$HEX39" >"$GDU/BISECT_START"
if wt_branch_held_by_operation "$RU/w" "$HEX39"; then
	ok "a hex branch name shorter than the hash width is still recognised as held"
else
	no "a 39-hex branch name in BISECT_START must still count as holding the branch"
fi

# git probes bisect INDEPENDENTLY of the rebase state, so a broken rebase entry
# must not mask a live bisect: git REFUSES.
printf 'refs/heads/foo\n' >"$GDU/BISECT_START"
printf 'junk\n' >"$GDU/rebase-apply"
if wt_branch_held_by_operation "$RU/w" foo; then
	ok "a non-directory rebase-apply does not mask a live bisect"
else
	no "a live bisect must still be recognised beside a non-directory rebase-apply"
fi
rm -f "$GDU/rebase-apply"

# Unreadable state must degrade to "unknown" (never held) for a DETACHED record,
# so the caller falls back to git's own error instead of guessing.
rm -f "$GDU/BISECT_START"
mkdir -p "$GDU/BISECT_START"
if wt_branch_held_by_operation "$RU/w" foo; then
	no "an unreadable BISECT_START must degrade to unknown, not report the branch as held"
else
	ok "unreadable operation state degrades to unknown"
fi
rm -rf "$GDU/BISECT_LOG" "$GDU/BISECT_START"

# ---------------------------------------------------------------------------
# Unit: wt_operation_in_flight answers the question a `branch` record poses —
# "is ANY operation running here?" — with THREE outcomes, per THE REMEDY RULE.
# ---------------------------------------------------------------------------
RO="$(make_repo ro)"
git_quiet -C "$RO" worktree add -q "$RO/op" -b op-b >/dev/null 2>&1
GDO="$RO/.git/worktrees/op"

op_rc() {
	local rc=0
	wt_operation_in_flight "$1" || rc=$?
	echo "$rc"
}

if [ "$(op_rc "$RO/op")" = 1 ]; then
	ok "wt_operation_in_flight verifies 'none' on a quiet worktree"
else
	no "quiet worktree should report 1 (none), got $(op_rc "$RO/op")"
fi

: >"$GDO/BISECT_LOG"
if [ "$(op_rc "$RO/op")" = 0 ]; then
	ok "wt_operation_in_flight sees a bisect with no reference to what BISECT_START names"
else
	no "BISECT_LOG present should report 0 (in flight), got $(op_rc "$RO/op")"
fi
rm -f "$GDO/BISECT_LOG"

# A `git am` is an operation too, and needs the same "finish or abort" advice.
mkdir -p "$GDO/rebase-apply"
: >"$GDO/rebase-apply/applying"
if [ "$(op_rc "$RO/op")" = 0 ]; then
	ok "wt_operation_in_flight counts a git am as an operation in flight"
else
	no "git am should report 0 (in flight), got $(op_rc "$RO/op")"
fi
rm -rf "$GDO/rebase-apply"

if [ "$(op_rc "$RO/does-not-exist")" = 2 ]; then
	ok "wt_operation_in_flight reports UNKNOWN for a worktree that is not there"
else
	no "missing worktree should report 2 (unknown), got $(op_rc "$RO/does-not-exist")"
fi

# A worktree that lost its own .git pointer still satisfies `rev-parse`, because
# task worktrees sit INSIDE the main working tree — the answer then describes the
# ENCLOSING repo. That must read as UNKNOWN, not as the enclosing repo's state.
git_quiet -C "$RO" worktree add -q "$RO/.worktrees/$CONTAINER_NAME/inside" -b inside-b >/dev/null 2>&1
rm -f "$RO/.worktrees/$CONTAINER_NAME/inside/.git"
if git -C "$RO/.worktrees/$CONTAINER_NAME/inside" rev-parse --absolute-git-dir >/dev/null 2>&1; then
	if [ "$(op_rc "$RO/.worktrees/$CONTAINER_NAME/inside")" = 2 ]; then
		ok "wt_operation_in_flight refuses to read the ENCLOSING repo's state as the worktree's"
	else
		no "worktree without its .git pointer should report 2 (unknown), got $(op_rc "$RO/.worktrees/$CONTAINER_NAME/inside")"
	fi
else
	no "precondition: rev-parse should still resolve upwards from a worktree that lost its .git"
fi

# ---------------------------------------------------------------------------
# Unit: wt_worktree_for_branch must report the blocker AND its operation state
# from ONE scan, so the caller never re-probes to pick a remedy (a second probe
# can disagree with the first and hand out advice that does not match the blocker
# actually found). Cases below cover both record kinds and all three states.
# ---------------------------------------------------------------------------
RG="$(make_repo rg)"
git_quiet -C "$RG" worktree add -q "$RG/plain" -b plain-b >/dev/null 2>&1
WT_BLOCKER_PATH='(unset)'
WT_BLOCKER_OPERATION='(unset)'
if wt_worktree_for_branch "$RG" plain-b >/dev/null &&
	[ "$WT_BLOCKER_PATH" = "$RG/plain" ] &&
	[ "$WT_BLOCKER_OPERATION" = none ]; then
	ok "wt_worktree_for_branch records a plain blocker with a VERIFIED 'none'"
else
	no "plain blocker globals wrong: path='$WT_BLOCKER_PATH' op='$WT_BLOCKER_OPERATION'"
fi

git_quiet -C "$RG" branch bis-b
git_quiet -C "$RG" worktree add -q "$RG/bis" bis-b >/dev/null 2>&1
git_quiet -C "$RG/bis" bisect start >/dev/null 2>&1 || true
if git -C "$RG" worktree list --porcelain | grep -qx "branch refs/heads/bis-b" &&
	[ -z "$(git -C "$RG/bis" status --porcelain)" ]; then
	WT_BLOCKER_PATH='(unset)'
	WT_BLOCKER_OPERATION='(unset)'
	if wt_worktree_for_branch "$RG" bis-b >/dev/null &&
		[ "$WT_BLOCKER_PATH" = "$RG/bis" ] &&
		[ "$WT_BLOCKER_OPERATION" = in-flight ]; then
		ok "a live bisect on an ON-BRANCH worktree is flagged from the same scan"
	else
		no "on-branch bisect globals wrong: path='$WT_BLOCKER_PATH' op='$WT_BLOCKER_OPERATION'"
	fi
else
	no "precondition: 'git bisect start' should leave $RG/bis on its branch with a clean status"
fi

# An ON-BRANCH bisect of a branch whose NAME BEGINS WITH 40 HEX DIGITS — a legal
# refname that wt_state_branch must read as an object id. Deriving the state by
# comparing BISECT_START to the branch name would therefore report "none" here.
HEXBR=0123456789abcdef0123456789abcdef01234567-br
git_quiet -C "$RG" branch "$HEXBR"
git_quiet -C "$RG" worktree add -q "$RG/hexbis" "$HEXBR" >/dev/null 2>&1
git_quiet -C "$RG/hexbis" bisect start >/dev/null 2>&1 || true
if git -C "$RG" worktree list --porcelain | grep -qx "branch refs/heads/$HEXBR" &&
	[ -z "$(git -C "$RG/hexbis" status --porcelain)" ] &&
	! wt_state_branch "$RG/.git/worktrees/hexbis/BISECT_START" >/dev/null; then
	WT_BLOCKER_PATH='(unset)'
	WT_BLOCKER_OPERATION='(unset)'
	if wt_worktree_for_branch "$RG" "$HEXBR" >/dev/null &&
		[ "$WT_BLOCKER_PATH" = "$RG/hexbis" ] &&
		[ "$WT_BLOCKER_OPERATION" = in-flight ]; then
		ok "an on-branch bisect is flagged even when BISECT_START looks like an object id"
	else
		no "oid-shaped-branch bisect globals wrong: path='$WT_BLOCKER_PATH' op='$WT_BLOCKER_OPERATION'"
	fi
else
	no "precondition: '$HEXBR' should be a legal branch, on-branch bisecting, with an oid-shaped BISECT_START"
fi

# Same shape, different cause: BISECT_START unreadable. Reading it would yield
# "no operation" again; not reading it keeps the bisect visible.
git_quiet -C "$RG" branch unread-b
git_quiet -C "$RG" worktree add -q "$RG/unread" unread-b >/dev/null 2>&1
git_quiet -C "$RG/unread" bisect start >/dev/null 2>&1 || true
chmod 000 "$RG/.git/worktrees/unread/BISECT_START"
if ! cat "$RG/.git/worktrees/unread/BISECT_START" >/dev/null 2>&1; then
	WT_BLOCKER_PATH='(unset)'
	WT_BLOCKER_OPERATION='(unset)'
	if wt_worktree_for_branch "$RG" unread-b >/dev/null &&
		[ "$WT_BLOCKER_OPERATION" = in-flight ]; then
		ok "an on-branch bisect with an UNREADABLE BISECT_START is still flagged"
	else
		no "unreadable-BISECT_START bisect op wrong: op='$WT_BLOCKER_OPERATION'"
	fi
else
	no "precondition: BISECT_START should be unreadable after chmod 000 (are we root?)"
fi
chmod 600 "$RG/.git/worktrees/unread/BISECT_START"

# A registered blocker whose directory is gone: nothing can be verified there.
git_quiet -C "$RG" worktree add -q "$RG/vanished" -b vanished-b >/dev/null 2>&1
rm -rf "$RG/vanished"
WT_BLOCKER_PATH='(unset)'
WT_BLOCKER_OPERATION='(unset)'
if wt_worktree_for_branch "$RG" vanished-b >/dev/null &&
	[ "$WT_BLOCKER_PATH" = "$RG/vanished" ] &&
	[ "$WT_BLOCKER_OPERATION" = unknown ]; then
	ok "a blocker whose directory is gone reports UNKNOWN, not 'none'"
else
	no "vanished blocker globals wrong: path='$WT_BLOCKER_PATH' op='$WT_BLOCKER_OPERATION'"
fi

WT_BLOCKER_PATH='(unset)'
WT_BLOCKER_OPERATION='(unset)'
git_quiet -C "$RG" branch unheld-b
if wt_worktree_for_branch "$RG" unheld-b >/dev/null; then
	no "wt_worktree_for_branch must not claim a blocker for an unheld branch"
elif [ -z "$WT_BLOCKER_PATH" ] && [ "$WT_BLOCKER_OPERATION" = none ]; then
	ok "wt_worktree_for_branch clears its globals when no worktree holds the branch"
else
	no "unheld-branch globals not cleared: path='$WT_BLOCKER_PATH' op='$WT_BLOCKER_OPERATION'"
fi

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

# ---------------------------------------------------------------------------
# Integration: wt-enter names the PRIMARY checkout when it is what blocks the
# branch (a human or peer agent switched the shared main working tree onto it).
# The error must identify the main checkout, flag that it is shared, and point
# at coordination — never auto-detach — and stdout must stay empty on failure.
# ---------------------------------------------------------------------------
R5="$(make_repo r5)"
E5="$WORK_ROOT/r5.err"
# make_repo leaves the primary checkout on 'main', so requesting a worktree on
# 'main' is blocked by the primary checkout itself.
if out="$(cd "$R5" && bash "$WT_ENTER" task-e main 2>"$E5")"; then
	no "wt-enter must fail when the branch is checked out in the primary checkout (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	grep -qiF "primary" "$E5" || miss="$miss no-primary-wording"
	# The path must appear on wt-enter's OWN line, not only in git's fatal.
	grep -F "$R5" "$E5" | grep -q '^wt-enter:' || miss="$miss no-primary-path"
	grep -qiF "shared" "$E5" || miss="$miss no-shared-warning"
	grep -qiF "coordinate" "$E5" || miss="$miss no-coordination-hint"
	# Nothing may be silently remediated: the main checkout stays on 'main' and
	# no worktree is left behind.
	[ "$(git -C "$R5" branch --show-current)" = "main" ] || miss="$miss primary-branch-moved"
	[ ! -e "$R5/.worktrees/$CONTAINER_NAME/task-e" ] || miss="$miss worktree-created"
	if [ -z "$miss" ]; then
		ok "wt-enter names the shared primary checkout when it blocks the branch"
	else
		no "wt-enter primary-checkout conflict message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: blocked by a SIBLING task worktree keeps the ordinary semantics
# (failure, empty stdout) but must surface the blocking worktree path rather
# than swallowing it — and must NOT claim the primary checkout is involved.
# ---------------------------------------------------------------------------
R6="$(make_repo r6)"
WB6="$R6/.worktrees/$CONTAINER_NAME"
E6="$WORK_ROOT/r6.err"
git_quiet -C "$R6" worktree add -q "$WB6/task-f" -b task-f >/dev/null 2>&1
if out="$(cd "$R6" && bash "$WT_ENTER" task-g task-f 2>"$E6")"; then
	no "wt-enter must fail when the branch is checked out in a sibling worktree (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	# Surfaced by wt-enter itself, not merely left inside git's fatal text.
	grep -F "$WB6/task-f" "$E6" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
	! grep -qiF "primary" "$E6" || miss="$miss claims-primary"
	# Nothing is in flight in that worktree, so wt-remove genuinely is the remedy
	# (and still refuses over unsaved work) — it must be offered here.
	grep -qF "wt-remove" "$E6" || miss="$miss no-wt-remove-remedy"
	[ ! -e "$WB6/task-g" ] || miss="$miss worktree-created"
	if [ -z "$miss" ]; then
		ok "wt-enter surfaces the blocking sibling worktree path (and does not blame the primary checkout)"
	else
		no "wt-enter sibling-worktree conflict message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# THE REMEDY RULE, which the next several cases each probe from a different
# angle: wt-remove may be offered ONLY for a VERIFIED "no operation". It guards
# unsaved work and rebase/merge state but has NO bisect guard, and a bisect
# leaves `git status --porcelain` empty, so nothing else would stop the removal
# from discarding it. "In flight" and "could not be verified" therefore both get
# "do not remove", and only a plain idle worktree gets wt-remove.
#
# Integration: blocked by a worktree with an INTERRUPTED REBASE. git reports such
# a worktree as `detached` in the porcelain yet still refuses to check its branch
# out elsewhere, so the diagnosis must consult the operation state instead of
# concluding "no worktree holds this branch". Same expectations as the sibling
# case above.
# ---------------------------------------------------------------------------
R7="$(make_repo r7)"
WB7="$R7/.worktrees/$CONTAINER_NAME"
E7="$WORK_ROOT/r7.err"
git_quiet -C "$R7" checkout -q -b task-h
echo "branch side" >"$R7/seed.txt"
git_quiet -C "$R7" commit -qam "task-h edit"
git_quiet -C "$R7" checkout -q main
echo "main side" >"$R7/seed.txt"
git_quiet -C "$R7" commit -qam "main edit"
git_quiet -C "$R7" worktree add -q "$WB7/task-h" task-h >/dev/null 2>&1
# Conflicting rebase: it stops mid-flight and leaves the worktree detached.
git_quiet -C "$WB7/task-h" rebase main >/dev/null 2>&1 || true
if git -C "$R7" worktree list --porcelain | grep -qx detached; then
	if out="$(cd "$R7" && bash "$WT_ENTER" task-i task-h 2>"$E7")"; then
		no "wt-enter must fail when the branch is held by an interrupted rebase (got '$out')"
	else
		miss=""
		[ -z "$out" ] || miss="$miss stdout-not-empty"
		grep -F "$WB7/task-h" "$E7" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
		! grep -qiF "primary" "$E7" || miss="$miss claims-primary"
		# An unfinished operation must NOT be answered with wt-remove.
		! grep -qF "wt-remove" "$E7" || miss="$miss points-at-wt-remove"
		grep -qiF "abort" "$E7" || miss="$miss no-finish-or-abort-remedy"
		[ ! -e "$WB7/task-i" ] || miss="$miss worktree-created"
		if [ -z "$miss" ]; then
			ok "wt-enter names the blocking worktree even when a rebase leaves it detached"
		else
			no "wt-enter interrupted-rebase conflict message inadequate:$miss"
		fi
	fi
else
	no "precondition: rebase did not leave $WB7/task-h detached"
fi

# ---------------------------------------------------------------------------
# Integration: blocked by a BISECT — same detached shape as the rebase above, but
# the remedy must be "finish or abort", not wt-remove.
# ---------------------------------------------------------------------------
R8="$(make_repo r8)"
WB8="$R8/.worktrees/$CONTAINER_NAME"
E8="$WORK_ROOT/r8.err"
for i in 1 2 3; do
	echo "rev $i" >"$R8/seed.txt"
	git_quiet -C "$R8" commit -qam "c$i"
done
git_quiet -C "$R8" branch task-j
git_quiet -C "$R8" worktree add -q "$WB8/task-j" task-j >/dev/null 2>&1
git_quiet -C "$WB8/task-j" bisect start HEAD HEAD~2 >/dev/null 2>&1 || true
if git -C "$R8" worktree list --porcelain | grep -qx detached; then
	if out="$(cd "$R8" && bash "$WT_ENTER" task-k task-j 2>"$E8")"; then
		no "wt-enter must fail when the branch is held by a bisect (got '$out')"
	else
		miss=""
		[ -z "$out" ] || miss="$miss stdout-not-empty"
		grep -F "$WB8/task-j" "$E8" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
		! grep -qiF "primary" "$E8" || miss="$miss claims-primary"
		# wt-remove would delete the worktree and the bisect state with it.
		! grep -qF "wt-remove" "$E8" || miss="$miss points-at-wt-remove"
		grep -qiF "bisect reset" "$E8" || miss="$miss no-bisect-remedy"
		[ ! -e "$WB8/task-k" ] || miss="$miss worktree-created"
		if [ -z "$miss" ]; then
			ok "wt-enter tells a bisect-blocked caller to finish/abort, never to wt-remove the worktree"
		else
			no "wt-enter bisect conflict message inadequate:$miss"
		fi
	fi
else
	no "precondition: bisect did not leave $WB8/task-j detached"
fi

# ---------------------------------------------------------------------------
# Integration: a bisect not yet given a good/bad commit does NOT detach — the
# worktree stays ON its branch, so this only works if the operation state is read
# for plain `branch` records too, not just detached ones.
# ---------------------------------------------------------------------------
RA="$(make_repo ra)"
WBA="$RA/.worktrees/$CONTAINER_NAME"
EA="$WORK_ROOT/ra.err"
git_quiet -C "$RA" branch task-m
git_quiet -C "$RA" worktree add -q "$WBA/task-m" task-m >/dev/null 2>&1
git_quiet -C "$WBA/task-m" bisect start >/dev/null 2>&1 || true
if git -C "$RA" worktree list --porcelain | grep -qx "branch refs/heads/task-m" &&
	[ -z "$(git -C "$WBA/task-m" status --porcelain)" ]; then
	if out="$(cd "$RA" && bash "$WT_ENTER" task-n task-m 2>"$EA")"; then
		no "wt-enter must fail when the branch is held by an on-branch bisect (got '$out')"
	else
		miss=""
		[ -z "$out" ] || miss="$miss stdout-not-empty"
		grep -F "$WBA/task-m" "$EA" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
		# wt-remove would pass every guard here and take the bisect with it.
		! grep -qF "wt-remove" "$EA" || miss="$miss points-at-wt-remove"
		grep -qiF "bisect reset" "$EA" || miss="$miss no-bisect-remedy"
		[ ! -e "$WBA/task-n" ] || miss="$miss worktree-created"
		if [ -z "$miss" ]; then
			ok "wt-enter warns off wt-remove for a bisect that has not detached the worktree yet"
		else
			no "wt-enter on-branch-bisect conflict message inadequate:$miss"
		fi
	fi
else
	no "precondition: 'git bisect start' should leave $WBA/task-m on its branch with a clean status"
fi

# ---------------------------------------------------------------------------
# Integration: the same on-branch bisect on an oid-shaped branch name (see the
# unit case above). This is the shape that used to offer wt-remove, which then
# deleted the worktree and the live bisect with it.
# ---------------------------------------------------------------------------
RH="$(make_repo rh)"
WBH="$RH/.worktrees/$CONTAINER_NAME"
EH="$WORK_ROOT/rh.err"
HEXBR2=0123456789abcdef0123456789abcdef01234567-task
git_quiet -C "$RH" branch "$HEXBR2"
git_quiet -C "$RH" worktree add -q "$WBH/task-o" "$HEXBR2" >/dev/null 2>&1
git_quiet -C "$WBH/task-o" bisect start >/dev/null 2>&1 || true
if git -C "$RH" worktree list --porcelain | grep -qx "branch refs/heads/$HEXBR2" &&
	[ -z "$(git -C "$WBH/task-o" status --porcelain)" ]; then
	if out="$(cd "$RH" && bash "$WT_ENTER" task-p "$HEXBR2" 2>"$EH")"; then
		no "wt-enter must fail when an oid-shaped branch name is held by an on-branch bisect (got '$out')"
	else
		miss=""
		[ -z "$out" ] || miss="$miss stdout-not-empty"
		grep -F "$WBH/task-o" "$EH" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
		! grep -qF "wt-remove" "$EH" || miss="$miss points-at-wt-remove"
		grep -qiF "bisect reset" "$EH" || miss="$miss no-bisect-remedy"
		if [ -z "$miss" ]; then
			ok "wt-enter warns off wt-remove for a bisect whose branch name looks like an object id"
		else
			no "wt-enter oid-shaped-branch bisect message inadequate:$miss"
		fi
	fi
else
	no "precondition: '$HEXBR2' should be on-branch bisecting with a clean status"
fi

# ---------------------------------------------------------------------------
# Integration: the blocker is a SIBLING worktree registered in git's metadata but
# MISSING on disk. wt-remove is a no-op on an absent dir, so offering it is a
# closed loop; `git worktree prune` is what actually frees it.
# ---------------------------------------------------------------------------
RP="$(make_repo rp)"
WBP="$RP/.worktrees/$CONTAINER_NAME"
EP="$WORK_ROOT/rp.err"
git_quiet -C "$RP" worktree add -q "$WBP/task-q" -b task-q >/dev/null 2>&1
rm -rf "$WBP/task-q"
if out="$(cd "$RP" && bash "$WT_ENTER" task-r task-q 2>"$EP")"; then
	no "wt-enter must fail when a registered-but-missing sibling holds the branch (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	grep -F "$WBP/task-q" "$EP" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
	grep -qF "worktree prune" "$EP" || miss="$miss no-prune-remedy"
	! grep -qF "wt-remove" "$EP" || miss="$miss dead-end-wt-remove-advice"
	if [ -z "$miss" ]; then
		ok "wt-enter advises 'worktree prune' for a registered-but-missing sibling blocker"
	else
		no "wt-enter prunable-sibling message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: the blocker's operation state CANNOT be verified — here because
# the worktree lost its own .git pointer. git still refuses the checkout, so the
# blocker is real; the advice must degrade rather than fall back to wt-remove.
# ---------------------------------------------------------------------------
RV="$(make_repo rv)"
WBV="$RV/.worktrees/$CONTAINER_NAME"
EV="$WORK_ROOT/rv.err"
git_quiet -C "$RV" worktree add -q "$WBV/task-s" -b task-s >/dev/null 2>&1
git_quiet -C "$WBV/task-s" bisect start >/dev/null 2>&1 || true
rm -f "$WBV/task-s/.git"
if out="$(cd "$RV" && bash "$WT_ENTER" task-t task-s 2>"$EV")"; then
	no "wt-enter must fail when an unverifiable sibling holds the branch (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	grep -F "$WBV/task-s" "$EV" | grep -q '^wt-enter:' || miss="$miss no-blocking-path"
	! grep -qF "wt-remove" "$EV" || miss="$miss points-at-wt-remove"
	grep -qiF "could NOT be read" "$EV" || miss="$miss no-unverified-warning"
	if [ -z "$miss" ]; then
		ok "wt-enter refuses to recommend removal when the blocker's state cannot be verified"
	else
		no "wt-enter unverifiable-blocker message inadequate:$miss"
	fi
fi

# ---------------------------------------------------------------------------
# Integration: `git worktree add` also fails when the DESTINATION worktree is
# registered but missing on disk (hand-deleted, or a pre-durable-metadata
# leftover). git's own message carries the right remedy there ("prune"/"remove"),
# and the porcelain still lists that path as holding the branch — so the
# branch-conflict diagnosis must stay silent rather than tell the caller the path
# it just asked for is blocked by "another worktree" and hand it a wt-remove that
# is a no-op on an absent dir (a closed advice loop).
# ---------------------------------------------------------------------------
R9="$(make_repo r9)"
WB9="$R9/.worktrees/$CONTAINER_NAME"
E9="$WORK_ROOT/r9.err"
git_quiet -C "$R9" worktree add -q "$WB9/task-l" -b task-l >/dev/null 2>&1
rm -rf "$WB9/task-l" # registered in .git/worktrees, gone from disk
if out="$(cd "$R9" && bash "$WT_ENTER" task-l task-l 2>"$E9")"; then
	no "wt-enter must fail when its destination is registered but missing (got '$out')"
else
	miss=""
	[ -z "$out" ] || miss="$miss stdout-not-empty"
	# No tailored branch-conflict diagnosis: git's own remedy must stand alone.
	! grep -q '^wt-enter: branch ' "$E9" || miss="$miss self-blocker-diagnosis"
	! grep -qF "wt-remove" "$E9" || miss="$miss dead-end-wt-remove-advice"
	if [ -z "$miss" ]; then
		ok "wt-enter leaves git's own remedy standing when the blocker is its own destination"
	else
		no "wt-enter self-blocker message inadequate:$miss"
	fi
fi

echo
echo "wt-orphan-safety: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
