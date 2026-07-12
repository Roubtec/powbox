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
