#!/usr/bin/env bash
# Detect workspace subpackage directories that need node_modules shadowing.
#
# Scans for pnpm, npm, and yarn workspace declarations plus an optional
# .powbox.yml override file.  Outputs one absolute path per line — each
# path is a directory to shadow with tmpfs so that host-native binaries
# (e.g. Windows) never mix with container-native (Linux) binaries.
#
# Usage: detect-shadows.sh <workspace-dir>
set -euo pipefail
shopt -s nullglob globstar

WORKSPACE_DIR="${1:?usage: detect-shadows.sh <workspace-dir>}"

if [ ! -d "$WORKSPACE_DIR" ]; then
	exit 0
fi

shadows=()

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

# --- .powbox.yml custom shadow paths ---
POWBOX_YML="$WORKSPACE_DIR/.powbox.yml"
if [ -f "$POWBOX_YML" ]; then
	workspace_resolved="$(realpath -- "$WORKSPACE_DIR")"

	# Append a resolved path to the shadow list iff it stays under the
	# workspace root; otherwise reject it.  The second argument is the
	# original (pre-resolution) path used only for the diagnostic message.
	add_shadow_path() {
		local resolved="$1" original="$2"
		case "$resolved" in
			"$workspace_resolved"/*)
				shadows+=("$resolved")
				;;
			*)
				echo "detect-shadows: skipping '$original' — resolves outside workspace root." >&2
				;;
		esac
	}

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
				resolved="$(realpath -m -- "$WORKSPACE_DIR/$pattern")" || continue
				add_shadow_path "$resolved" "$WORKSPACE_DIR/$pattern"
				;;
		esac
	done < <(yq -r '.shadow[]? // empty' "$POWBOX_YML" 2>/dev/null || true)
fi

# Deduplicate and output.
if [ ${#shadows[@]} -gt 0 ]; then
	printf '%s\n' "${shadows[@]}" | sort -u
fi
