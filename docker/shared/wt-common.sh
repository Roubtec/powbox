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

# The two resolvers below exist so callers can DIAGNOSE a "branch is already used
# by worktree at ..." failure without parsing git's fatal message: that text is
# localizable and unstable, whereas `git worktree list --porcelain` is a
# documented, machine-readable format. Both print a single absolute path on
# stdout (nothing on failure) and return non-zero when they cannot answer, so a
# caller can always fall back to git's own error.

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

# wt_state_branch <file>
#   Print the BARE branch name recorded in a per-worktree operation-state file,
#   mirroring git's own reader (wt-status.c: get_branch()), which is deliberately
#   tolerant of the several formats these files can hold:
#     "refs/heads/<b>" -> "<b>"    (what rebase writes to head-name; git also
#                                   accepts it in BISECT_START, where it writes
#                                   the bare name — verified: git refuses a second
#                                   checkout for either spelling)
#     other "refs/..." -> verbatim (never equals a branch short-name, so no match)
#     "detached HEAD"  -> nothing, return 1 (rebase started from a detached HEAD)
#     a full object id -> nothing, return 1 (a bisect started from a detached
#                                   HEAD records the commit; git abbreviates it,
#                                   so the full id must NEVER be compared against
#                                   a branch name — verified: git does not treat
#                                   a branch literally named that 40-hex as held)
#     anything else    -> verbatim (bisect's bare "<b>")
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
	if printf '%s' "$raw" | LC_ALL=C grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$'; then
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
#   interrupted operation, not a plain checkout, is the blocker.
#
#   Reads the same per-worktree state files git itself reads, all under the
#   worktree's own git dir (<common>/worktrees/<id>, or <root>/.git for the main
#   working tree), and in git's own precedence (wt-status.c:
#   wt_status_check_rebase / wt_status_check_bisect):
#     rebase-apply/         apply backend, checked FIRST. When the sibling
#                           `applying` marker marks it a `git am`, git stops
#                           there and does NOT fall through to rebase-merge, and
#                           an am does not hold the branch — verified: with both
#                           dirs present and `applying` set, git allows the second
#                           checkout, so probing rebase-merge first would be a
#                           FALSE "held".
#     rebase-merge/         merge/interactive backend, only when rebase-apply is
#                           absent.
#     BISECT_START          bisect, only when BISECT_LOG marks one in progress.
#   Returns 1 when the state cannot be read (e.g. the worktree dir is gone), so
#   the caller degrades to git's own error rather than guessing: a false "held"
#   is worse than falling back to git's message.
wt_branch_held_by_operation() {
	local wt="$1" branch="$2" gitdir head
	gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
	if [ -d "$gitdir/rebase-apply" ]; then
		if [ ! -e "$gitdir/rebase-apply/applying" ] &&
			head="$(wt_state_branch "$gitdir/rebase-apply/head-name")" &&
			[ "$head" = "$branch" ]; then
			return 0
		fi
	elif [ -d "$gitdir/rebase-merge" ]; then
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
wt_worktree_for_branch() {
	local root="$1" branch="$2" out line path=""
	out="$(git -C "$root" worktree list --porcelain 2>/dev/null)" || return 1
	while IFS= read -r line; do
		case "$line" in
		"worktree "*) path="${line#worktree }" ;;
		"branch "*)
			if [ "${line#branch }" = "refs/heads/$branch" ] && [ -n "$path" ]; then
				printf '%s\n' "$path"
				return 0
			fi
			;;
		detached)
			if [ -n "$path" ] && wt_branch_held_by_operation "$path" "$branch"; then
				printf '%s\n' "$path"
				return 0
			fi
			;;
		esac
	done <<<"$out"
	return 1
}
