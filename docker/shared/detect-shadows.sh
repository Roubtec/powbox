#!/usr/bin/env bash
# Detect workspace directories that need tmpfs shadowing.
#
# Scans for pnpm, npm, and yarn workspace declarations (-> per-package
# node_modules), .NET project files (-> per-project bin/obj), plus optional
# .powbox.yml / .powbox.local.yml override files.  Outputs one absolute path per line — each
# path is a directory to shadow with tmpfs so that host-native build output
# (e.g. Windows) never mixes with container-native (Linux) output.
#
# Usage: detect-shadows.sh <workspace-dir>
set -euo pipefail
shopt -s nullglob globstar

WORKSPACE_DIR="${1:?usage: detect-shadows.sh <workspace-dir>}"

# Normalize away trailing slashes before anything derives a path from it.
# entrypoint-core.sh strips one, but shadow-refresh.sh passes its argument
# through verbatim and `shadow-refresh.sh /workspace/<slug>/` is exactly what
# shell tab completion produces — leaving one on would spell every derived path
# with a `//` that some comparisons see and others do not.  Looped, so `<ws>//`
# normalizes too, and guarded so a lone "/" cannot become the empty string.
while :; do
	case "$WORKSPACE_DIR" in
	/) break ;;
	*/) WORKSPACE_DIR="${WORKSPACE_DIR%/}" ;;
	*) break ;;
	esac
done

if [ ! -d "$WORKSPACE_DIR" ]; then
	exit 0
fi

shadows=()
workspace_resolved="$(realpath -- "$WORKSPACE_DIR")"

# Append a resolved path to the shadow list iff it stays strictly under
# the workspace root; otherwise reject it.  The second argument is the
# original (pre-resolution) path used only for the diagnostic message.
add_shadow_path() {
	local resolved="$1" original="$2"
	if [ "$resolved" = "$workspace_resolved" ]; then
		# e.g. pattern '.' — shadowing the root would mask the whole repo.
		echo "detect-shadows: skipping '$original' — refusing to shadow the workspace root itself." >&2
		return
	fi
	case "$resolved" in
	"$workspace_resolved"/*)
		shadows+=("$resolved")
		;;
	*)
		echo "detect-shadows: skipping '$original' — resolves outside workspace root." >&2
		;;
	esac
}

# git, with the ambient GIT_* redirection variables scrubbed.  `git -C <dir>` does
# NOT override them, and shadow-refresh.sh runs from whatever environment invoked
# it — the pnpm wrapper, or a Git hook, where GIT_DIR and GIT_INDEX_FILE are set
# — so an inherited value would silently point a read at another repository and
# have it answer for a tree that is not this one, in either direction.
# `safe.directory=*` keeps the reads working when the checkout's host uid differs
# from node's; this script is unprivileged and only ever reads.
# The pathspec-mode variables are scrubbed for a different reason: any of them
# makes the explicit --literal-pathspecs below a fatal "incompatible with all
# other global pathspec settings", which would fail the whole probe closed and
# silently switch the .NET scan off in a hook environment that sets them.
git_scrubbed() {
	env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
		-u GIT_OBJECT_DIRECTORY -u GIT_GLOB_PATHSPECS -u GIT_NOGLOB_PATHSPECS \
		-u GIT_ICASE_PATHSPECS -u GIT_LITERAL_PATHSPECS \
		git -c safe.directory='*' "$@"
}

# True when <path> exists LEXICALLY — a real entry, or a symlink whose target is
# missing.  `-e` follows symlinks and so answers FALSE for a dangling one, and
# every repository-evidence test below reads a missing entry as "not a
# repository" — the fail-OPEN direction, which would shadow a bin/obj without
# ever establishing whether it holds real content.  An entry that merely EXISTS
# is enough evidence to withhold that; the thing it points at being temporarily
# unavailable is exactly when the question cannot be answered and must not be
# assumed away.  Reached by a dangling `.git` (a linked worktree whose gitdir
# moved or was pruned, a `.git` symlinked onto a volume not mounted yet) and by
# a bare repository's `HEAD` under the deprecated-but-supported
# `core.prefersymlinkrefs`, where HEAD is a symlink to a branch that does not
# exist yet — an unborn default branch on a freshly created bare repo.
entry_present() {
	[ -e "$1" ] || [ -L "$1" ]
}

# True when <dir> lies inside a repository NESTED under the workspace — some
# ancestor strictly below WORKSPACE_DIR carries a .git (an initialized submodule
# at libs/sub, a nested clone at vendor/lib).  The workspace's own index cannot
# see such a directory's files at all, so folding it into the batched query below
# would answer "untracked" for genuinely tracked content.  Pure stats, no git.
# On success sets NESTED_REPO_DIR to the ancestor that carries the .git, so the
# probe below can confirm it is that repository which ends up answering.
NESTED_REPO_DIR=""
nested_repo_owns() {
	local dir="${1%/*}"
	NESTED_REPO_DIR=""
	while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "$WORKSPACE_DIR" ]; do
		if entry_present "$dir/.git"; then
			NESTED_REPO_DIR="$dir"
			return 0
		fi
		dir="${dir%/*}"
	done
	return 1
}

# For those few directories, ask their own repository directly.  Asked from the
# PARENT (the project directory, which exists because find(1) matched a project
# file in it) with the candidate's name as the pathspec, so it answers just as
# well for a candidate that is not on disk — a gitlink whose submodule was never
# initialized, or a sparse checkout — as for one that is.
#
# Three-way on purpose, mirroring the batched outer probe below: "could not
# determine" is NOT the same answer as "holds tracked content".  Collapsing them
# would withhold a candidate that is merely ABSENT — the fresh-clone/never-built
# case the whole feature exists for — whenever the owning repository's index was
# unreadable, where the outer path still shadows it; and it would report the skip
# as "contains Git-tracked files" when the truth is that nothing was established.
#   0 — positively holds tracked content
#   1 — positively holds none
#   2 — could not determine (wrong repository answered, git failed, or an
#       untrustworthy index)
#
# $2 is the owning repository nested_repo_owns found.  It has to be checked,
# because a `.git` entry is not always a repository git will USE: for a dangling
# `.git` symlink (or a gitlink file whose target is gone) the discovery walk
# steps straight past it and the OUTER repository answers instead — reporting
# "untracked" for a directory whose real owner it cannot see into, which is the
# fail-open this whole branch exists to prevent.  Comparing the resolved
# toplevel catches that; a mismatch is "could not determine", not "clean".
nested_dir_state() {
	local owner="$2" parent="${1%/*}" name="${1##*/}" tracked toplevel
	toplevel="$(git_scrubbed -C "$parent" rev-parse --show-toplevel 2>/dev/null)" || return 2
	[ "$toplevel" = "$(realpath -m -- "$owner")" ] || return 2
	if ! tracked="$(git_scrubbed --literal-pathspecs -C "$parent" \
		ls-files --cached -- "$name" 2>/dev/null)"; then
		return 2
	fi
	if [ -n "$tracked" ]; then
		return 0
	fi
	# An empty result is only trustworthy if there was an index to read.
	git_index_trustworthy "$parent" && return 1
	return 2
}

# `ls-files --cached` reads the INDEX, and a missing index reads as an empty one
# with a SUCCESS status — so "nothing tracked here" and "no index at all" are
# indistinguishable from the exit code, and the latter would fail open on a repo
# whose index was deleted or never written.  Ask git where the index belongs and
# look.  ($1 is a directory to ask from; the path git prints is relative to it
# unless absolute.)
git_index_present() {
	local index_path
	index_path="$(git_scrubbed -C "$1" rev-parse --git-path index 2>/dev/null)" || return 1
	case "$index_path" in
	/*) [ -e "$index_path" ] ;;
	*) [ -e "$1/$index_path" ] ;;
	esac
}

# ... but a MISSING index is only suspicious when the repository has content to
# be missing from.  `git init` writes no index until something is staged, so a
# brand-new repo with no commits legitimately has none, and its empty answer is
# the truth rather than a failure — treating that as broken would withhold the
# shadows and print an alarm on an ordinary "start a new project here".  HEAD
# tells the two apart: no index AND no commits is a fresh repo; no index WITH
# commits is a broken one.
git_index_trustworthy() {
	if git_index_present "$1"; then
		return 0
	fi
	! git_scrubbed -C "$1" rev-parse --verify --quiet HEAD >/dev/null 2>&1
}

# Expand workspace glob patterns into node_modules paths.
# Each pattern is resolved relative to WORKSPACE_DIR; only directories
# that actually exist produce output (nullglob handles the rest).
expand_workspace_patterns() {
	local pattern
	while IFS= read -r pattern; do
		[ -z "$pattern" ] && continue
		# Skip negation/exclusion patterns (pnpm supports "!pattern").
		case "$pattern" in
		'!'*) continue ;;
		esac
		# Intentionally unquoted to allow glob expansion.
		# shellcheck disable=SC2086
		for pkg_dir in $WORKSPACE_DIR/$pattern; do
			[ -d "$pkg_dir" ] || continue
			# Via add_shadow_path like every other producer: a manifest is repo
			# content, so `packages: ["../other/src"]` must not be able to point
			# the shadow at a sibling project's tree.  This adds the containment
			# check only — deliberately NOT the .NET branch's symlink refusal:
			# this branch is existence-gated and its symlink resolution is
			# long-standing behaviour on main that a committed workspace layout
			# may rely on, the same scoping call already made for .powbox.yml.
			add_shadow_path "$(realpath -m -- "$pkg_dir/node_modules")" "$pkg_dir/node_modules"
		done
	done
}

# --- pnpm workspaces (pnpm-workspace.yaml) ---
PNPM_WS="$WORKSPACE_DIR/pnpm-workspace.yaml"
if [ -f "$PNPM_WS" ]; then
	expand_workspace_patterns < <(yq -r '.packages[]? // empty' "$PNPM_WS" 2>/dev/null || true)
fi

# --- npm / yarn workspaces (package.json) ---
PKG_JSON="$WORKSPACE_DIR/package.json"
if [ -f "$PKG_JSON" ]; then
	expand_workspace_patterns < <(jq -r '
		if (.workspaces | type) == "array" then .workspaces[]
		elif (.workspaces | type) == "object" and
		     (.workspaces.packages | type) == "array"
		then .workspaces.packages[]
		else empty end
	' "$PKG_JSON" 2>/dev/null || true)
fi

# --- .NET projects (*.csproj / *.fsproj / *.vbproj) -> bin + obj ---
#
# Same derivation shape as the workspace globs above (a project manifest implies
# an artifact directory beside it), and the same reason: MSBuild bakes ABSOLUTE
# paths into obj/.  A container restore writes `/home/node/.nuget/packages/`
# into obj/project.assets.json and obj/*.nuget.g.props, while the same project
# built on a Windows host writes `C:\Users\<user>\.nuget\packages\`.  Sharing
# those directories over the bind mount makes a container build and a host
# Visual Studio build silently clobber each other's restore graph — exactly the
# host-vs-container mixing that node_modules shadowing already prevents.
#
# Emitted as LITERAL paths (not a glob like `*/bin`) on purpose: build output
# does not exist on a fresh clone or after a clean, and the glob branch below is
# existence-gated, so a glob would silently shadow nothing in precisely the
# situation this exists for.  Literals are mkdir -p'd by shadow-mounts.sh.  The
# cost is an empty bin/obj mountpoint dir appearing for a project that has never
# been built (and for one that redirects output via ArtifactsPath); both are
# gitignored by every standard .NET template, and it is the same accepted
# trade-off as the empty node_modules/.worktrees mountpoint dirs.
#
# node_modules/.git/.worktrees/.claude are pruned so the walk stays cheap (~0.16s
# on a 1700-directory monorepo, hence no depth bound) and so worktree checkouts
# are skipped — BOTH roots: `.worktrees` (the persistent volume) and
# `.claude/worktrees` (the harness-native tmpfs shadow).  Those live in
# container-local mounts with no host counterpart, so they have nothing to
# collide with, and shadowing them would only cost RAM, discard build state, and
# nest a tmpfs inside a tmpfs.  bin/obj themselves are pruned so a copied-out
# project file under bin/ cannot seed a nested scan.
#
# An existing bin/obj that is itself a SYMLINK is skipped rather than resolved.
# This scan is automatic — no config declares it — so it must never let repo
# content decide what gets masked: `realpath` on `app/bin -> ../src` yields
# `<ws>/src`, which passes the under-workspace-root check, and shadow-mounts.sh
# would then tmpfs over real source for the whole session.  (The .powbox.yml
# branches below deliberately still resolve symlinks: those paths are an
# explicit operator declaration, not something inferred from the tree.)
# find(1) does not follow symlinks (-P), so proj_dir itself can contain no
# symlinked component and checking the final bin/obj component is sufficient.
#
# An existing bin/obj that is a REPOSITORY CHECKOUT (it contains a .git) or that
# holds GIT-TRACKED content is skipped for that same reason.  A project that
# redirects its output (MSBuild `ArtifactsPath` / `OutputPath`) can legitimately
# keep tracked scripts or fixtures — or a submodule — in a sibling bin/obj; a
# tmpfs over one would make those files read as deleted for the whole session and
# send any edit to an overlay that dies with the container.  Real build output is
# gitignored by every standard .NET template, so "tracked" is a reliable signal
# that a directory is NOT disposable, and a .git inside one settles it outright.
# The two checks are complementary: the .git test catches an initialized
# submodule or nested checkout, whose files the WORKSPACE's index cannot see at
# all, and costs a single stat; the tracked-content probe below is one batched
# `git ls-files` for the whole scan.
dotnet_artifact_dirs=()
while IFS= read -r -d '' proj_dir; do
	for artifact_dir in "$proj_dir/bin" "$proj_dir/obj"; do
		if [ -L "$artifact_dir" ]; then
			echo "detect-shadows: skipping '$artifact_dir' — symlink; refusing to shadow its target." >&2
			continue
		fi
		if [ -e "$artifact_dir" ] && [ ! -d "$artifact_dir" ]; then
			# A plain file named bin/obj: nothing to shadow, and emitting it would
			# make shadow-mounts.sh complain at every container start.
			echo "detect-shadows: skipping '$artifact_dir' — not a directory." >&2
			continue
		fi
		# A .git covers a normal checkout and an initialized submodule (counted
		# lexically, so a dangling one still says "repository" — see
		# entry_present); the HEAD+objects+refs triple covers a BARE
		# repository, which has no .git of its own and is invisible to the outer
		# index, so nothing else would stop it being masked.  MSBuild output never
		# looks like either.  HEAD is counted lexically for the same reason as
		# `.git`: under the deprecated-but-supported `core.prefersymlinkrefs`,
		# `git init --bare` writes HEAD as a SYMLINK to `refs/heads/<default>`,
		# which does not exist until the first commit — so `-e` is false on a
		# freshly created bare repo while `objects` and `refs` are real
		# directories sitting right there.  `objects`/`refs` stay `-d`: a
		# repository cannot function without them as real directories (`-d`
		# still follows a valid symlink to one), and loosening them would start
		# matching things that are not repositories.
		if entry_present "$artifact_dir/.git" ||
			{ entry_present "$artifact_dir/HEAD" && [ -d "$artifact_dir/objects" ] && [ -d "$artifact_dir/refs" ]; }; then
			echo "detect-shadows: skipping '$artifact_dir' — Git repository or submodule checkout, not build output." >&2
			continue
		fi
		dotnet_artifact_dirs+=("$artifact_dir")
	done
done < <(
	find "$WORKSPACE_DIR" \
		\( -type d \( -name node_modules -o -name .git -o -name .worktrees \
		-o -name .claude -o -name bin -o -name obj \) -prune \) -o \
		\( -type f \( -name '*.csproj' -o -name '*.fsproj' -o -name '*.vbproj' \) \
		-printf '%h\0' \) 2>/dev/null | sort -zu
)

if [ ${#dotnet_artifact_dirs[@]} -gt 0 ]; then
	# One `git ls-files` for the whole scan, over EVERY candidate — including the
	# ones not on disk.  "Absent means it cannot hold tracked content" is not
	# true: a gitlink whose submodule was never initialized, or a path excluded by
	# a sparse checkout, is tracked with nothing on disk, and shadowing it would
	# send the eventual `submodule update` or sparse-checkout widening into a
	# tmpfs that dies with the container.  Batching them costs nothing — the call
	# count does not depend on the pathspec count.
	#
	# `--literal-pathspecs` so a project directory named `app[1]` is matched as
	# itself rather than as a character class; git_scrubbed for the GIT_* and
	# safe.directory handling described at its definition.
	declare -A tracked_artifact_dir=()
	declare -A undetermined_artifact_dir=()
	candidate_rel=()
	for artifact_dir in "${dotnet_artifact_dirs[@]}"; do
		if nested_repo_owns "$artifact_dir"; then
			# Owned by a repository nested under the workspace: one git call for
			# this directory alone.  Rare enough not to matter for the scan's
			# budget, and the batched query below still covers everything else.
			nested_state=0
			nested_dir_state "$artifact_dir" "$NESTED_REPO_DIR" || nested_state=$?
			case "$nested_state" in
			0) tracked_artifact_dir["${artifact_dir#"$WORKSPACE_DIR"/}"]=1 ;;
			1) ;;
			# Only a positive "holds none" (1) may fall through to shadowing.
			# Anything else is treated as undetermined, so a status this case
			# does not know about cannot become the fail-OPEN answer by default.
			*) undetermined_artifact_dir["${artifact_dir#"$WORKSPACE_DIR"/}"]=1 ;;
			esac
			continue
		fi
		# Compare workspace-RELATIVE, the same form `git -C` prints, so no
		# absolute-path arithmetic can disagree with git's own spelling.
		candidate_rel+=("${artifact_dir#"$WORKSPACE_DIR"/}")
	done
	probe_failed=0
	if [ ${#candidate_rel[@]} -gt 0 ]; then
		# The output is NUL-delimited (a tracked path may contain anything, and
		# command substitution cannot carry NULs), so the exit status is smuggled
		# out as a trailing sentinel rather than captured: every real record starts
		# with one of the candidate prefixes, so it cannot collide with a path.
		probe_ok=0
		probe_sentinel='//detect-shadows-probe-ok//'
		while IFS= read -r -d '' tracked_file; do
			if [ "$tracked_file" = "$probe_sentinel" ]; then
				# Success alone is not enough: a MISSING index also reads as an
				# empty one with status 0 (see git_index_present).
				if git_index_trustworthy "$WORKSPACE_DIR"; then
					probe_ok=1
				fi
				continue
			fi
			for rel in "${candidate_rel[@]}"; do
				case "$tracked_file" in
				"$rel" | "$rel"/*) tracked_artifact_dir["$rel"]=1 ;;
				esac
			done
		done < <(git_scrubbed --literal-pathspecs -C "$WORKSPACE_DIR" \
			ls-files -z --cached -- "${candidate_rel[@]}" 2>/dev/null &&
			printf '%s\0' "$probe_sentinel")
		if [ "$probe_ok" = 0 ] &&
			{
				git_scrubbed -C "$WORKSPACE_DIR" rev-parse --git-dir >/dev/null 2>&1 ||
					entry_present "$WORKSPACE_DIR/.git"
			}; then
			# It IS a repository, so the failure is a real one (unreadable or
			# corrupt index, git too old for a flag, ...) and we cannot tell
			# disposable output from tracked content.  Fail CLOSED for the
			# directories that exist: not shadowing them costs a host/container
			# obj collision, while shadowing tracked files loses edits.
			#
			# `rev-parse` alone is not the oracle: it fails for the very reasons
			# ls-files did, and an unreadable .git (mode 000, or a linked
			# worktree's .git file pointing at a missing gitdir) reports "not a
			# git repository" — which would fail OPEN and mask tracked files. So
			# a .git entry that merely EXISTS is enough to withhold the shadow —
			# lexically, so a DANGLING .git symlink counts too (see
			# entry_present); `-e` alone would follow it and answer false.
			probe_failed=1
			echo "detect-shadows: could not read the Git index for '$WORKSPACE_DIR'; leaving every existing .NET bin/obj un-shadowed rather than risk masking tracked files." >&2
		fi
		# Otherwise it is simply not a Git repository (a non-git folder launched as
		# a workspace) — nothing can be tracked, so shadow as usual.
	fi

	for artifact_dir in "${dotnet_artifact_dirs[@]}"; do
		rel="${artifact_dir#"$WORKSPACE_DIR"/}"
		if [ -n "${tracked_artifact_dir["$rel"]:-}" ]; then
			echo "detect-shadows: skipping '$artifact_dir' — contains Git-tracked files; refusing to mask them with a tmpfs." >&2
			continue
		fi
		# Same asymmetry as the batched probe's fail-closed branch below: an
		# UNDETERMINED answer withholds only a directory that exists (whose
		# contents a tmpfs could mask), while an absent one is still shadowed —
		# there is nothing there to lose, and that is the fresh-clone case.
		# The wording matches the batched diagnostic's prefix on purpose, so
		# entrypoint-core.sh's stderr allow-list carries it through unchanged:
		# both mean the same thing to an operator — the scan withheld a shadow
		# because it could not read an index, so the feature is degraded.
		if [ -n "${undetermined_artifact_dir["$rel"]:-}" ] && [ -d "$artifact_dir" ]; then
			echo "detect-shadows: could not read the Git index for the repository owning '$artifact_dir'; leaving it un-shadowed rather than risk masking tracked files." >&2
			continue
		fi
		if [ "$probe_failed" = 1 ] && [ -d "$artifact_dir" ]; then
			continue
		fi
		add_shadow_path "$(realpath -m -- "$artifact_dir")" "$artifact_dir"
	done
fi

# --- .powbox.yml / .powbox.local.yml custom shadow paths ---
POWBOX_YML="$WORKSPACE_DIR/.powbox.yml"
POWBOX_LOCAL_YML="$WORKSPACE_DIR/.powbox.local.yml"
SHADOW_YML=""
if [ -f "$POWBOX_LOCAL_YML" ] && [ "$(yq -r 'has("shadow")' "$POWBOX_LOCAL_YML" 2>/dev/null || true)" = true ]; then
	SHADOW_YML="$POWBOX_LOCAL_YML"
	echo "detect-shadows: shadow list overridden by .powbox.local.yml" >&2
elif [ -f "$POWBOX_YML" ]; then
	SHADOW_YML="$POWBOX_YML"
fi

if [ -n "$SHADOW_YML" ]; then
	while IFS= read -r pattern; do
		[ -z "$pattern" ] && continue
		case "$pattern" in
		'!'*) continue ;;
		esac
		# .powbox.yml patterns resolve to the path itself (not appending /node_modules)
		# so the user has full control over what gets shadowed.
		case "$pattern" in
		*[][*?]*)
			# Glob pattern: expand it and keep the existence gate — a glob
			# cannot be mkdir'd, so only matching directories make sense.
			# shellcheck disable=SC2086
			for shadow_dir in $WORKSPACE_DIR/$pattern; do
				[ -d "$shadow_dir" ] || continue
				# Resolve symlinks / ".." and validate it stays under WORKSPACE_DIR.
				resolved="$(realpath -- "$shadow_dir")" || continue
				add_shadow_path "$resolved" "$shadow_dir"
			done
			;;
		*)
			# Literal path: emit it even when it does not exist yet, so
			# committed declarations (e.g. gitignored worktree dirs absent on
			# a fresh checkout) are created and shadowed at startup.  realpath
			# -m tolerates non-existent paths; shadow-mounts.sh mkdir -p's them.
			#
			# Exception: a literal under .git/ is only safe to create when
			# .git is a real directory (the main checkout).  When .git is
			# absent (non-git folder) or a file (a linked worktree, whose
			# .git/worktrees metadata lives in the *main* repo), emitting the
			# path would make shadow-mounts.sh mkdir a bogus .git/ tree or
			# fail outright on the non-directory parent.  Skip it loudly.
			case "$pattern" in
			.git | .git/*)
				if [ ! -d "$WORKSPACE_DIR/.git" ]; then
					echo "detect-shadows: skipping '$pattern' — \$WORKSPACE_DIR/.git is not a directory (non-git checkout or linked worktree)." >&2
					continue
				fi
				;;
			esac
			resolved="$(realpath -m -- "$WORKSPACE_DIR/$pattern")" || continue
			add_shadow_path "$resolved" "$WORKSPACE_DIR/$pattern"
			;;
		esac
	done < <(yq -r '.shadow[]? // empty' "$SHADOW_YML" 2>/dev/null || true)
fi

# Deduplicate and output.
#
# The output protocol is newline-delimited — entrypoint-core.sh reads it with
# `mapfile -t`, shadow-refresh.sh with `read -r` — so a path that itself contains
# a newline would reach the privileged shadow-mounts.sh as TWO arguments, and the
# fragment before the newline is a truncated ANCESTOR of the intended target.  A
# project beside a directory literally named $'\nfoo' emits `<ws>/`, which still
# satisfies shadow-mounts.sh's under-/workspace check, so the whole checkout would
# be tmpfs-masked for the session.  The .NET scan makes that reachable from repo
# CONTENT alone (no declaration), so reject such paths at the one point every
# producer funnels through rather than trusting each call site.  Carrying NUL
# end to end would be the alternative, but it would have to change both consumers
# and the .powbox.yml branches too, for paths no real project has.
if [ ${#shadows[@]} -gt 0 ]; then
	emit=()
	for shadow in "${shadows[@]}"; do
		case "$shadow" in
		*$'\n'*)
			# %q so the diagnostic stays one line despite the embedded newline.
			printf 'detect-shadows: skipping %q — path contains a newline; the output is newline-delimited, so emitting it would hand a truncated ancestor to shadow-mounts.sh.\n' "$shadow" >&2
			continue
			;;
		esac
		emit+=("$shadow")
	done
	if [ ${#emit[@]} -gt 0 ]; then
		printf '%s\n' "${emit[@]}" | sort -u
	fi
fi
