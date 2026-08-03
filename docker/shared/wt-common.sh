#!/usr/bin/env bash
# wt-common.sh — shared helpers for wt-bootstrap / wt-enter / wt-remove.
#
# SOURCED, never executed: it defines functions only and has no side effects at
# source time. The three worktree helpers pick it up via their sibling directory
# (repo / test tree) first, falling back to the baked /usr/local/bin copy.
#
# The safety-critical primitive here is orphan reaping. With DURABLE worktree
# metadata (task 017), a recycled worktree keeps its .git/worktrees entry (bound
# from the persistent .worktrees volume) and is reused as a live worktree — so a
# genuine orphan is now rare: a partially-created worktree, or a directory left
# by a PRE-durable-metadata container whose tmpfs .git/worktrees was lost on
# recycle. In that last case the directory can hold the SOLE surviving copy of
# uncommitted work, so it must NEVER be deleted merely because its metadata
# vanished. wt_reap_orphan_dir encodes that: delete only proven-empty dirs, and
# preserve (move aside) anything with content.

# wt_reap_orphan_dir <dir>
#   <dir> = <root>/.worktrees/<container>/<slug>, already established NOT to be a
#   live git worktree. Decide safely and act:
#     * empty            -> atomic rmdir                            prints "pruned"
#     * has any content  -> move to <root>/.worktrees/.orphaned/<container>/<slug>.<ts>
#                           (same persistent volume, out of the scanned base)
#                                                         prints "quarantined:<dest>"
#     * cannot do either -> leave it in place              prints "kept"
#   The ONLY thing on stdout is that outcome token; all human diagnostics go to
#   stderr. Never exits (best-effort) and always returns 0, so `set -e` callers
#   keep going and branch on the token.
#
#   Emptiness is decided ATOMICALLY by `rmdir`, never by a separate probe: rmdir
#   removes the directory only if it is truly empty and fails otherwise, so there
#   is no TOCTOU window in which content appearing after an `ls` check could be
#   recursively deleted. A non-empty (or otherwise un-rmdir-able) dir falls
#   through to the preserve/quarantine path and is NEVER rm -rf'd.
wt_reap_orphan_dir() {
	local dir="$1"

	[ -e "$dir" ] || {
		printf 'pruned\n'
		return 0
	}

	# Empty? `rmdir` succeeds only for a truly-empty dir and is atomic — no
	# TOCTOU window where content created after a probe could be deleted. If it
	# fails, the dir has content (or cannot be removed): PRESERVE it below,
	# never rm -rf.
	if rmdir -- "$dir" 2>/dev/null; then
		printf 'pruned\n'
		return 0
	fi

	# Non-empty (or un-rmdir-able): PRESERVE. Move it aside rather than delete —
	# it may be the only copy of dirty work whose worktree metadata was lost on
	# recycle/migration.
	local wt_base slug container worktrees_root dest_base dest ts
	wt_base="$(dirname -- "$dir")" # <root>/.worktrees/<container>
	slug="$(basename -- "$dir")"
	container="$(basename -- "$wt_base")"
	worktrees_root="$(dirname -- "$wt_base")" # <root>/.worktrees
	dest_base="$worktrees_root/.orphaned/$container"
	ts="$(date +%s 2>/dev/null || echo 0)"
	dest="$dest_base/$slug.$ts"
	# Avoid clobbering a same-second quarantine of the same slug.
	[ ! -e "$dest" ] || dest="$dest.$$"

	if mkdir -p -- "$dest_base" 2>/dev/null && mv -- "$dir" "$dest" 2>/dev/null; then
		echo "wt: preserved non-empty orphan (not a live worktree; metadata lost): moved $dir -> $dest" >&2
		echo "wt: recover any uncommitted work from there, then delete it — the branch's committed history is safe in the shared .git." >&2
		printf 'quarantined:%s\n' "$dest"
		return 0
	fi

	echo "wt: warning: could not quarantine non-empty orphan $dir; leaving it in place (refusing to delete possibly-unsaved work)." >&2
	printf 'kept\n'
	return 0
}

# The resolvers below exist so callers can DIAGNOSE a "branch is already used by
# worktree at ..." failure without parsing git's fatal message: that text is
# localizable and unstable, whereas `git worktree list --porcelain` is a
# documented, machine-readable format. They print a single absolute path on
# stdout (nothing on failure) and return non-zero when they cannot answer, so a
# caller can always fall back to git's own error.
#
# Every claim below about what git does was established by fabricating the state
# and observing whether `git worktree add` then refuses. That rationale lives
# HERE only; scripts/test-wt-orphan-safety.sh pins the outcomes without
# restating it.

# wt_primary_checkout <root>
#   Print the absolute path of the repository's PRIMARY (main) working tree.
#   `git worktree list --porcelain` always lists the main working tree first, so
#   the first `worktree ` line is it. Returns 1 if git cannot be queried.
wt_primary_checkout() {
	local out line
	out="$(git -C "$1" worktree list --porcelain 2>/dev/null)" || return 1
	while IFS= read -r line; do
		case "$line" in
		"worktree "*)
			printf '%s\n' "${line#worktree }"
			return 0
			;;
		esac
	done <<<"$out"
	return 1
}

# wt_worktree_gitdir <worktree>
#   Print the absolute git dir belonging to <worktree> ITSELF; return 1 when that
#   cannot be established, so callers can tell "read it" from "did not read it".
#   The toplevel cross-check is load-bearing: task worktrees live INSIDE the main
#   working tree ($ROOT/.worktrees/...), so a worktree that has lost its own .git
#   pointer still makes `rev-parse` succeed — against the ENCLOSING repo, whose
#   operation state belongs to a different checkout (verified: git keeps refusing
#   the second checkout there, so the blocker is real while its state is not ours
#   to read). An unreachable git dir needs no separate probe: it already fails
#   rev-parse (verified — such a worktree drops out of `git worktree list` too).
wt_worktree_gitdir() {
	local out gitdir top
	out="$(git -C "$1" rev-parse --absolute-git-dir --show-toplevel 2>/dev/null)" || return 1
	gitdir="${out%%$'\n'*}"
	top="${out##*$'\n'}"
	[ "$top" = "$1" ] || return 1
	printf '%s\n' "$gitdir"
}

# wt_operation_in_flight <worktree>
#   Is ANY unfinished rebase / am / bisect in progress in <worktree>? Three
#   answers, because "none" and "could not tell" must never collapse into one —
#   a caller turns "none" into a remedy that DELETES the worktree:
#     0  an operation IS in flight
#     1  none — verified
#     2  UNKNOWN, nothing was observed
#   For a worktree the porcelain already reports as holding the branch, this is
#   the whole question: that `branch` record proves the block by itself, so no
#   name comparison is needed and the answer cannot be skewed by whatever
#   head-name/BISECT_START happen to contain — which matters, because a legal
#   branch name may itself parse as an object id (see wt_state_branch).
#   The three entries are exactly the ones git's own is_worktree_being_rebased()
#   / is_worktree_being_bisected() stat(), probed with `-e` for the reasons given
#   under wt_branch_held_by_operation.
wt_operation_in_flight() {
	local gitdir
	gitdir="$(wt_worktree_gitdir "$1")" || return 2
	[ ! -e "$gitdir/rebase-apply" ] || return 0
	[ ! -e "$gitdir/rebase-merge" ] || return 0
	[ ! -e "$gitdir/BISECT_LOG" ] || return 0
	return 1
}

# wt_state_branch <file>
#   Print the BARE branch name recorded in a per-worktree operation-state file,
#   mirroring git's own reader (wt-status.c: get_branch()), which tolerates the
#   several formats these files can hold:
#     "refs/heads/<b>" -> "<b>"    (rebase's head-name spelling; git accepts it
#                                   in BISECT_START too, where it writes "<b>")
#     other "refs/..." -> verbatim (never equals a branch short-name)
#     "detached HEAD"  -> nothing, return 1 (rebase from a detached HEAD)
#     an object id     -> nothing, return 1 (a bisect from a detached HEAD records
#                                   the commit; git abbreviates it before
#                                   comparing, so it must NEVER be matched
#                                   against a branch name)
#     anything else    -> verbatim (bisect's bare "<b>")
#
#   The object-id test mirrors get_oid_hex() CONSERVATIVELY: git parses hex
#   case-INsensitively and consumes exactly the hash width without requiring
#   end-of-string, so 41+ hex digits, or 40 followed by junk, is an object id to
#   git — for both, git ALLOWS a second checkout of a same-named branch, which an
#   `^[0-9a-f]{40}$` test would have called held. Hence: any value BEGINNING with
#   40 hex digits of either case. That over-reaches in a SHA-256 repository and
#   for oid-shaped refnames git itself rejects as ambiguous, but only towards
#   UNKNOWN, which costs no more than git's own error message; the opposite error
#   would be a false "held".
#   Returns 1 (printing nothing) when the file is missing, unreadable or empty,
#   so a state we could not fully read degrades to UNKNOWN instead of being
#   compared against truncated content.
wt_state_branch() {
	local raw
	raw="$(cat -- "$1" 2>/dev/null)" || return 1
	[ -n "$raw" ] || return 1
	case "$raw" in
	"detached HEAD") return 1 ;;
	refs/heads/*)
		printf '%s\n' "${raw#refs/heads/}"
		return 0
		;;
	esac
	if printf '%s' "$raw" | LC_ALL=C grep -Eq '^[0-9a-fA-F]{40}'; then
		return 1
	fi
	printf '%s\n' "$raw"
}

# wt_branch_held_by_operation <worktree> <branch>
#   Return 0 when the worktree at <worktree> — which `git worktree list
#   --porcelain` reports as DETACHED — is nevertheless holding <branch> through
#   an in-progress rebase or bisect. Git counts such a branch as checked out and
#   refuses to check it out again (worktree.c: find_shared_symref() consults
#   is_worktree_being_rebased() / is_worktree_being_bisected() for detached
#   worktrees), so without this the resolver would miss exactly the case where an
#   interrupted operation, not a plain checkout, is the blocker. ONLY detached
#   records need this; a `branch` record already proves the block, and the
#   question there is the simpler wt_operation_in_flight.
#
#   Reads the same per-worktree state files git reads, in git's own precedence
#   (wt-status.c: wt_status_check_rebase / wt_status_check_bisect):
#     rebase-apply/   apply backend, checked FIRST. A sibling `applying` marker
#                     makes it a `git am`, which does not hold the branch and
#                     stops git from consulting rebase-merge at all — with both
#                     dirs present and `applying` set, git ALLOWS the second
#                     checkout, so probing rebase-merge first would be a FALSE
#                     "held".
#     rebase-merge/   merge/interactive backend, only when rebase-apply is absent.
#     BISECT_START    bisect, only when BISECT_LOG marks one in progress; checked
#                     independently of the rebase state, as git checks
#                     is_worktree_being_bisected() separately.
#   Probed with `-e`, not `-d`, because git decides with a bare stat(): a
#   NON-directory `rebase-apply` still makes git stop at the apply backend, where
#   it finds no branch — git ALLOWS the second checkout, whereas a `-d` probe
#   would skip to rebase-merge and report a false "held". `-e` follows symlinks
#   just as stat() does, so a DANGLING symlink correctly falls through to
#   rebase-merge (git refuses there).
#   Returns 1 for "not held OR unreadable". Conflating them is safe HERE and only
#   here: an unidentified detached blocker costs nothing but git's own error
#   message, and git itself allows the second checkout when it cannot read the
#   state either (verified with an unreadable head-name).
wt_branch_held_by_operation() {
	local wt="$1" branch="$2" gitdir head
	gitdir="$(wt_worktree_gitdir "$wt")" || return 1
	if [ -e "$gitdir/rebase-apply" ]; then
		if [ ! -e "$gitdir/rebase-apply/applying" ] &&
			head="$(wt_state_branch "$gitdir/rebase-apply/head-name")" &&
			[ "$head" = "$branch" ]; then
			return 0
		fi
	elif [ -e "$gitdir/rebase-merge" ]; then
		if head="$(wt_state_branch "$gitdir/rebase-merge/head-name")" &&
			[ "$head" = "$branch" ]; then
			return 0
		fi
	fi
	if [ -e "$gitdir/BISECT_LOG" ] &&
		head="$(wt_state_branch "$gitdir/BISECT_START")" &&
		[ "$head" = "$branch" ]; then
		return 0
	fi
	return 1
}

# wt_worktree_for_branch <root> <branch>
#   Print the absolute path of the worktree that currently has <branch> checked
#   out, or return 1 (printing nothing) when no worktree holds it. A worktree
#   with a rebase/bisect in progress reports as `detached` in the porcelain even
#   though git still refuses to check its branch out elsewhere, so detached
#   records are cross-checked against the operation state (see
#   wt_branch_held_by_operation). A non-zero return still means "unknown" rather
#   than a guarantee of "no conflict": callers must fall back to git's own error.
#
#   The SAME scan also records what it found in two globals, so a caller picking a
#   remedy never re-probes the blocker. A second probe can disagree with the first
#   — the operation may have ended, or a read failed transiently — and then the
#   advice would not match the blocker that was actually found, which here means
#   offering "just remove that worktree" for one holding live bisect state:
#     WT_BLOCKER_PATH        the path just printed ("" when none)
#     WT_BLOCKER_OPERATION   none | in-flight | unknown, for that worktree
#   "unknown" is deliberately NOT folded into "none": only a VERIFIED "none" may
#   be answered with a remedy that deletes the worktree (see wt-enter, which
#   applies that rule). The state is probed for a `branch` record too, not only
#   for detached ones — `git bisect start` before the first good/bad leaves HEAD
#   ON the branch, so a live bisect hides behind a plain `branch` record.
#   A command substitution runs the function in a subshell and would throw both
#   globals away, so a caller that needs them invokes it directly and redirects
#   stdout instead.
# shellcheck disable=SC2034 # WT_BLOCKER_* are outputs, read by the caller (wt-enter)
wt_worktree_for_branch() {
	local root="$1" branch="$2" out line path="" op
	WT_BLOCKER_PATH=""
	WT_BLOCKER_OPERATION="none"
	out="$(git -C "$root" worktree list --porcelain 2>/dev/null)" || return 1
	while IFS= read -r line; do
		case "$line" in
		"worktree "*) path="${line#worktree }" ;;
		"branch "*)
			if [ "${line#branch }" = "refs/heads/$branch" ] && [ -n "$path" ]; then
				WT_BLOCKER_PATH="$path"
				op=0
				wt_operation_in_flight "$path" || op=$?
				case "$op" in
				0) WT_BLOCKER_OPERATION="in-flight" ;;
				2) WT_BLOCKER_OPERATION="unknown" ;;
				esac
				printf '%s\n' "$path"
				return 0
			fi
			;;
		detached)
			if [ -n "$path" ] && wt_branch_held_by_operation "$path" "$branch"; then
				WT_BLOCKER_PATH="$path"
				WT_BLOCKER_OPERATION="in-flight"
				printf '%s\n' "$path"
				return 0
			fi
			;;
		esac
	done <<<"$out"
	return 1
}
