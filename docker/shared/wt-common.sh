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
# documented, machine-readable format. They emit a single absolute path on stdout
# NUL-terminated (nothing on failure) and return non-zero when they cannot
# answer, so a caller can always fall back to git's own error. Read them with
# wt_read_path, never with `$(…)` — see the delimiter note below.
#
# They IDENTIFY the blocking worktree and stop there, deliberately: they do not
# classify it as safe to delete, and no caller may use them to pick a remedy that
# discards a worktree. Whether one may be thrown away depends on every state git
# can leave behind (rebase, am, cherry-pick, revert/sequencer, merge, bisect, ...)
# and would have to stay in lockstep with wt-remove's own guards; naming the
# blocker and handing over needs no such list and can destroy nothing.
#
# Every claim below about what git does was established by fabricating the state
# and observing whether `git worktree add` then refuses. That rationale lives
# HERE only; scripts/test-wt-orphan-safety.sh pins the outcomes without
# restating it.
#
# The porcelain is always read NUL-delimited (`--porcelain -z`), never
# line-delimited. A worktree path may legally contain a NEWLINE, and the
# line-based format emits it raw and unescaped: the tail of such a path then
# reads as a separate attribute and the parser answers a TRUNCATED path (observed
# with a blocker at `odd<LF>path`, which came back as `odd` — a path that does not
# exist, so wt-enter went on to report the blocker as missing on disk and offered
# `worktree prune`, the one remedy that is wrong there). `-z` terminates every
# attribute with a NUL instead, and NUL is the one byte a path cannot contain, so
# every other byte survives intact; an empty attribute ends a record.
#
# The records are consumed straight from a pipeline rather than through a command
# substitution because a bash variable CANNOT hold a NUL byte — `$(…)` silently
# drops them and would splice the whole listing into one field. That loses git's
# exit status, which costs nothing here: a `git worktree list` that fails (or is
# too old to know `-z`) produces no records at all, the loop ends without a match,
# and the function returns 1 — the same "unknown, fall back to git's own error"
# answer the explicit status check used to give.
#
# The ANSWER is handed back the same way, NUL-terminated and read out-of-band,
# because `$(…)` would undo the `-z` read one step later: command substitution
# strips TRAILING newlines, so a blocker at `odd<LF>` comes back as `odd` — again
# a path that is not on disk, and again wt-enter calling a live worktree missing
# and offering `worktree prune` (reproduced end to end). A newline is the only
# path byte `$(…)` can eat, and only at the end, but that is exactly the byte the
# porcelain read was hardened against, so the value never travels through a
# command substitution at all: wt_read_path takes it off a process substitution
# with the same `IFS= read -r -d ''` the porcelain loops use. Losing the exit
# status costs nothing here either — a resolver that cannot answer prints
# nothing, the read hits EOF without its delimiter and fails, and the caller
# takes the same "unknown" branch.

# wt_read_path <var> <resolver> [<args>...]
#   Run <resolver> and store the single NUL-terminated path it emits in <var>,
#   whole, whatever bytes it contains. Returns 1 — leaving <var> untouched — when
#   the resolver answers nothing, i.e. exactly when the resolver itself would
#   have returned non-zero, so callers branch on this instead:
#       wt_read_path blocker wt_worktree_for_branch "$root" "$branch" || ...
#   `IFS=` is load-bearing: `read` strips leading and trailing IFS whitespace,
#   and the default IFS contains the newline (and the space) that this whole
#   exercise exists to preserve. Its own locals are `__wt_`-prefixed so that a
#   caller's variable is never shadowed by one of them, and a <var> carrying that
#   prefix is REFUSED with status 2 rather than obeyed: `printf -v` would write
#   the answer into the helper's OWN local, leave the caller's variable at
#   whatever it held before, and still return 0 — a silently wrong answer no
#   caller can branch on. The refusal is deliberately silent; the non-zero status
#   is the whole signal, and it lands the caller on the same "unknown" branch a
#   resolver that answers nothing does, instead of proceeding on a stale value.
wt_read_path() {
	case "$1" in __wt_*) return 2 ;; esac
	local __wt_out_var="$1" __wt_path
	shift
	IFS= read -r -d '' __wt_path < <("$@") || return 1
	printf -v "$__wt_out_var" '%s' "$__wt_path"
}

# wt_primary_checkout <root>
#   Emit the absolute path of the repository's PRIMARY (main) working tree,
#   NUL-terminated (read it with wt_read_path). `git worktree list --porcelain`
#   always lists the main working tree first, so the first `worktree ` attribute
#   is it. Returns 1 if git cannot be queried.
wt_primary_checkout() {
	local field
	while IFS= read -r -d '' field; do
		case "$field" in
		"worktree "*)
			printf '%s\0' "${field#worktree }"
			return 0
			;;
		esac
	done < <(git -C "$1" worktree list --porcelain -z 2>/dev/null)
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
#   The two answers are asked for SEPARATELY rather than split out of one
#   newline-separated reply, for the same reason the porcelain is read with `-z`:
#   a worktree path may contain a newline, and splitting on newlines would hand
#   back a fragment of the toplevel and fail the cross-check for a perfectly good
#   worktree. (A path ENDING in a newline still degrades, since `$(…)` strips
#   trailing newlines — but only to `return 1`, i.e. "not read", which is this
#   function's documented safe direction.)
wt_worktree_gitdir() {
	local gitdir top
	gitdir="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
	top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
	[ "$top" = "$1" ] || return 1
	printf '%s\n' "$gitdir"
}

# wt_state_branch <file>
#   Print the BARE branch name recorded in a per-worktree operation-state file,
#   mirroring git's own reader (wt-status.c: get_branch()), which tolerates the
#   several formats these files can hold:
#     "refs/heads/<b>" -> "<b>"    (rebase's head-name spelling; git accepts it
#                                   in BISECT_START too, where it writes "<b>")
#     "detached HEAD"  -> nothing, return 1 (rebase from a detached HEAD)
#     an object id     -> nothing, return 1 (a bisect from a detached HEAD records
#                                   the commit, which git abbreviates before
#                                   comparing — never match it to a branch name)
#     anything else    -> verbatim (bisect's bare "<b>"; any other "refs/..." can
#                                   never equal a branch short-name anyway)
#
#   The object-id test mirrors get_oid_hex() CONSERVATIVELY: git parses hex
#   case-INsensitively and consumes exactly the hash width without requiring
#   end-of-string, so 41+ hex digits, or 40 followed by junk, is an object id to
#   git and it ALLOWS a second checkout of a same-named branch — an
#   `^[0-9a-f]{40}$` test would have called those held. Hence: any value BEGINNING
#   with 40 hex digits of either case. That over-reaches in a SHA-256 repository,
#   but only towards "no blocker identified", which costs no more than git's own
#   error message; the opposite error would be a false "held".
#   Returns 1 (printing nothing) when the file is missing, unreadable or empty, so
#   a partially-read state is never compared against truncated content.
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
#   records need this; a `branch` record already names the blocker by itself.
#
#   Reads the same per-worktree state files git reads, in git's own precedence
#   (wt-status.c: wt_status_check_rebase / wt_status_check_bisect):
#     rebase-apply/   apply backend, checked FIRST. A sibling `applying` marker
#                     makes it a `git am`, which holds no branch and stops git
#                     consulting rebase-merge at all — git then ALLOWS the second
#                     checkout, so probing rebase-merge first would be a FALSE
#                     "held".
#     rebase-merge/   merge/interactive backend, only when rebase-apply is absent.
#     BISECT_START    bisect, only when BISECT_LOG marks one in progress; probed
#                     independently of the rebase state, as git does.
#   Probed with `-e`, not `-d`, because git decides with a bare stat(): a
#   NON-directory `rebase-apply` still stops git at the apply backend, where it
#   finds no branch and ALLOWS the second checkout, whereas a `-d` probe would
#   skip on to rebase-merge and report a false "held". `-e` follows symlinks just
#   as stat() does, so a DANGLING symlink correctly falls through to rebase-merge
#   (git refuses there).
#   Returns 1 for "not held OR unreadable": an unidentified detached blocker costs
#   nothing but git's own error message, and git itself allows the second checkout
#   when it cannot read the state either (verified with an unreadable head-name).
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
#   Emit the absolute path of the worktree that currently has <branch> checked
#   out, NUL-terminated (read it with wt_read_path), or return 1 (emitting
#   nothing) when no worktree holds it. A worktree
#   with a rebase/bisect in progress reports as `detached` in the porcelain even
#   though git still refuses to check its branch out elsewhere, so detached
#   records are cross-checked against the operation state (see
#   wt_branch_held_by_operation). A non-zero return still means "unknown" rather
#   than a guarantee of "no conflict": callers must fall back to git's own error.
#   The answer is a PATH and nothing else — what state that worktree is in, and
#   what should be done about it, is for its owner to look at (see the note above
#   the resolvers).
wt_worktree_for_branch() {
	local root="$1" branch="$2" field path=""
	while IFS= read -r -d '' field; do
		case "$field" in
		"worktree "*) path="${field#worktree }" ;;
		"branch "*)
			if [ "${field#branch }" = "refs/heads/$branch" ] && [ -n "$path" ]; then
				printf '%s\0' "$path"
				return 0
			fi
			;;
		detached)
			# stdin is closed for the probe: it runs git itself, and the
			# undelimited records still queued on our stdin are not its to read.
			if [ -n "$path" ] && wt_branch_held_by_operation "$path" "$branch" </dev/null; then
				printf '%s\0' "$path"
				return 0
			fi
			;;
		esac
	done < <(git -C "$root" worktree list --porcelain -z 2>/dev/null)
	return 1
}
