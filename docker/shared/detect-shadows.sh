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

# Normalize away a trailing slash before anything derives a path from it.
# entrypoint-core.sh strips one, but shadow-refresh.sh passes its argument
# through verbatim and `shadow-refresh.sh /workspace/<slug>/` is exactly what
# shell tab completion produces — leaving it on would spell every derived path
# with a `//` that some comparisons see and others do not.  Guarded so a lone
# "/" cannot normalize to the empty string.
case "$WORKSPACE_DIR" in
/) ;;
*/) WORKSPACE_DIR="${WORKSPACE_DIR%/}" ;;
esac

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
git_scrubbed() {
	env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
		-u GIT_OBJECT_DIRECTORY git -c safe.directory='*' "$@"
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
		if [ -e "$artifact_dir/.git" ]; then
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
	# One `git ls-files` for the whole scan, restricted to the candidates that
	# actually exist: a path that is not there cannot hold tracked content, and on
	# a fresh clone — the case the shadow exists for — that is all of them.
	#
	# `--literal-pathspecs` so a project directory named `app[1]` is matched as
	# itself rather than as a character class; git_scrubbed for the GIT_* and
	# safe.directory handling described at its definition.
	declare -A tracked_artifact_dir=()
	existing_rel=()
	for artifact_dir in "${dotnet_artifact_dirs[@]}"; do
		if [ -d "$artifact_dir" ]; then
			# Compare workspace-RELATIVE, the same form `git -C` prints, so no
			# absolute-path arithmetic can disagree with git's own spelling.
			existing_rel+=("${artifact_dir#"$WORKSPACE_DIR"/}")
		fi
	done
	probe_failed=0
	if [ ${#existing_rel[@]} -gt 0 ]; then
		# The output is NUL-delimited (a tracked path may contain anything, and
		# command substitution cannot carry NULs), so the exit status is smuggled
		# out as a trailing sentinel rather than captured: every real record starts
		# with one of the candidate prefixes, so it cannot collide with a path.
		probe_ok=0
		probe_sentinel='//detect-shadows-probe-ok//'
		while IFS= read -r -d '' tracked_file; do
			if [ "$tracked_file" = "$probe_sentinel" ]; then
				probe_ok=1
				continue
			fi
			for rel in "${existing_rel[@]}"; do
				case "$tracked_file" in
				"$rel" | "$rel"/*) tracked_artifact_dir["$rel"]=1 ;;
				esac
			done
		done < <(git_scrubbed --literal-pathspecs -C "$WORKSPACE_DIR" \
			ls-files -z --cached -- "${existing_rel[@]}" 2>/dev/null &&
			printf '%s\0' "$probe_sentinel")
		if [ "$probe_ok" = 0 ] &&
			git_scrubbed -C "$WORKSPACE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
			# It IS a repository, so the failure is a real one (unreadable or
			# corrupt index, git too old for a flag, ...) and we cannot tell
			# disposable output from tracked content.  Fail CLOSED for the
			# directories that exist: not shadowing them costs a host/container
			# obj collision, while shadowing tracked files loses edits.
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
