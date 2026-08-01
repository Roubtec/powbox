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
			shadows+=("$pkg_dir/node_modules")
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
# node_modules/.git/.worktrees are pruned so the walk stays cheap (~0.16s on a
# 1700-directory monorepo, hence no depth bound) and so worktree checkouts are
# skipped: those live in a container-local volume with no host counterpart, so
# they have nothing to collide with and shadowing them would only cost RAM and
# discard build state.  bin/obj themselves are pruned so a copied-out project
# file under bin/ cannot seed a nested scan.
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
while IFS= read -r -d '' proj_dir; do
	for artifact_dir in "$proj_dir/bin" "$proj_dir/obj"; do
		if [ -L "$artifact_dir" ]; then
			echo "detect-shadows: skipping '$artifact_dir' — symlink; refusing to shadow its target." >&2
			continue
		fi
		add_shadow_path "$(realpath -m -- "$artifact_dir")" "$artifact_dir"
	done
done < <(
	find "$WORKSPACE_DIR" \
		\( -type d \( -name node_modules -o -name .git -o -name .worktrees \
		-o -name bin -o -name obj \) -prune \) -o \
		\( -type f \( -name '*.csproj' -o -name '*.fsproj' -o -name '*.vbproj' \) \
		-printf '%h\0' \) 2>/dev/null | sort -zu
)

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
if [ ${#shadows[@]} -gt 0 ]; then
	printf '%s\n' "${shadows[@]}" | sort -u
fi
