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
	while IFS= read -r pattern; do
		[ -z "$pattern" ] && continue
		case "$pattern" in
			'!'*) continue ;;
		esac
		# .powbox.yml patterns resolve to the path itself (not appending /node_modules)
		# so the user has full control over what gets shadowed.
		# shellcheck disable=SC2086
		for shadow_dir in $WORKSPACE_DIR/$pattern; do
			[ -d "$shadow_dir" ] || continue
			shadows+=("$shadow_dir")
		done
	done < <(yq -r '.shadow[]? // empty' "$POWBOX_YML" 2>/dev/null || true)
fi

# Deduplicate and output.
if [ ${#shadows[@]} -gt 0 ]; then
	printf '%s\n' "${shadows[@]}" | sort -u
fi
