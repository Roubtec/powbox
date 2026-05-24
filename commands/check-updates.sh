#!/usr/bin/env bash
# Compare the agent versions baked into the local Docker images against the
# latest releases on npm and report any available updates.
#
# With --porcelain, suppress all human-readable output and instead print just
# the names of the stale build targets (base|claude|codex), one per line, for
# `agent-update` to consume. A target is stale when a latest version is known
# and differs from what is baked in (a missing image counts as stale).
set -euo pipefail

PORCELAIN=false
positional=()
while [ "$#" -gt 0 ]; do
	case "$1" in
	--porcelain) PORCELAIN=true ;;
	*) positional+=("$1") ;;
	esac
	shift
done

CLAUDE_IMAGE="${positional[0]:-powbox-claude:latest}"
CODEX_IMAGE="${positional[1]:-powbox-codex:latest}"
BASE_IMAGE="${positional[2]:-powbox-agent-base:latest}"

# Emit informational text only in human mode so --porcelain stdout stays clean.
note() {
	$PORCELAIN || echo "$@"
}

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

has_image() {
	docker image inspect "$1" >/dev/null 2>&1
}

baked_claude_version() {
	docker run --rm --entrypoint claude "$1" --version 2>/dev/null \
		| head -1 | sed 's/ *(.*//; s/[[:space:]]*$//'
}

baked_codex_version() {
	docker run --rm --entrypoint codex "$1" --version 2>/dev/null \
		| head -1 | sed 's/^codex-cli *//; s/[[:space:]]*$//'
}

latest_npm_version() {
	local ver
	ver="$(npm view "$1" version 2>/dev/null)" || true
	echo "$ver"
}

# Digest (label) the base image records for the upstream image it was built from.
image_label() {
	docker image inspect "$1" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null || true
}

# Current digest of an upstream tag in its registry, without pulling it.
registry_digest() {
	docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null || true
}

short_digest() {
	echo "$1" | sed -n 's/^sha256:\([0-9a-f]\{12\}\).*/\1/p'
}

# Stale when a latest value is known and differs from the baked value. An
# empty baked value (missing/unknown image) with a known latest counts as
# stale so agent-update will build it.
is_stale() {
	local baked="$1" latest="$2"
	[ -n "$latest" ] || return 1
	[ "$baked" != "$latest" ]
}

compare_base() {
	local baked="$1" latest="$2"
	local b l
	b="$(short_digest "$baked")"
	l="$(short_digest "$latest")"
	if [ -z "$baked" ] || [ -z "$latest" ]; then
		printf '  %-8s  baked: %-14s  latest: %s\n' "Base" "${b:-(unknown)}" "${l:-(unknown)}"
		return
	fi
	if [ "$baked" = "$latest" ]; then
		printf '  %-8s  %s  (up to date)\n' "Base" "$b"
	else
		printf '  %-8s  %s -> %s  ** update available **\n' "Base" "$b" "$l"
	fi
}

compare() {
	local agent="$1" baked="$2" latest="$3"
	if [ -z "$baked" ]; then
		printf '  %-8s  baked: %-14s  latest: %s\n' "$agent" "(unknown)" "${latest:-(unknown)}"
		return
	fi
	if [ -z "$latest" ]; then
		printf '  %-8s  %s  latest: (unknown)\n' "$agent" "$baked"
		return
	fi
	if [ "$baked" = "$latest" ]; then
		printf '  %-8s  %s  (up to date)\n' "$agent" "$baked"
	else
		printf '  %-8s  %s -> %s  ** update available **\n' "$agent" "$baked" "$latest"
	fi
}

# -------------------------------------------------------------------
# Gather versions
# -------------------------------------------------------------------

claude_baked="" codex_baked=""
claude_latest="" codex_latest=""
base_source="" base_baked="" base_latest=""

if has_image "$CLAUDE_IMAGE"; then
	claude_baked="$(baked_claude_version "$CLAUDE_IMAGE")"
else
	note "Image $CLAUDE_IMAGE not found — Claude baked version will be shown as (unknown)."
fi

if has_image "$CODEX_IMAGE"; then
	codex_baked="$(baked_codex_version "$CODEX_IMAGE")"
else
	note "Image $CODEX_IMAGE not found — Codex baked version will be shown as (unknown)."
fi

if has_image "$BASE_IMAGE"; then
	base_source="$(image_label "$BASE_IMAGE" 'powbox.base.source')"
	base_baked="$(image_label "$BASE_IMAGE" 'powbox.base.source.digest')"
else
	note "Image $BASE_IMAGE not found — base will be shown as (unknown)."
fi

if command -v npm >/dev/null 2>&1; then
	claude_latest="$(latest_npm_version '@anthropic-ai/claude-code')"
	codex_latest="$(latest_npm_version '@openai/codex')"
else
	note "npm not found — latest agent versions will be shown as (unknown)."
fi

if [ -n "$base_source" ]; then
	base_latest="$(registry_digest "$base_source")"
fi

# -------------------------------------------------------------------
# Porcelain: emit stale target names only, in build order (base first).
# -------------------------------------------------------------------

if $PORCELAIN; then
	if is_stale "$base_baked" "$base_latest"; then echo base; fi
	if is_stale "$claude_baked" "$claude_latest"; then echo claude; fi
	if is_stale "$codex_baked" "$codex_latest"; then echo codex; fi
	exit 0
fi

# -------------------------------------------------------------------
# Report
# -------------------------------------------------------------------

echo ""
echo "Agent update check:"
[ -n "$base_baked" ] || [ -n "$base_latest" ] && compare_base "$base_baked" "$base_latest"
[ -n "$claude_baked" ] || [ -n "$claude_latest" ] && compare "Claude" "$claude_baked" "$claude_latest"
[ -n "$codex_baked" ] || [ -n "$codex_latest" ] && compare "Codex" "$codex_baked" "$codex_latest"
echo ""
