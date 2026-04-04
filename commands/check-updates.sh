#!/usr/bin/env bash
# Compare the agent versions baked into the local Docker images against the
# latest releases on npm and report any available updates.
set -euo pipefail

CLAUDE_IMAGE="${1:-powbox-claude:latest}"
CODEX_IMAGE="${2:-powbox-codex:latest}"

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
	npm view "$1" version 2>/dev/null
}

compare() {
	local agent="$1" baked="$2" latest="$3"
	if [ -z "$baked" ]; then
		printf '  %-8s  baked: %-14s  latest: %s\n' "$agent" "(unknown)" "$latest"
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

if has_image "$CLAUDE_IMAGE"; then
	claude_baked="$(baked_claude_version "$CLAUDE_IMAGE")"
else
	echo "Image $CLAUDE_IMAGE not found — skipping Claude."
fi

if has_image "$CODEX_IMAGE"; then
	codex_baked="$(baked_codex_version "$CODEX_IMAGE")"
else
	echo "Image $CODEX_IMAGE not found — skipping Codex."
fi

claude_latest="$(latest_npm_version '@anthropic-ai/claude-code')"
codex_latest="$(latest_npm_version '@openai/codex')"

# -------------------------------------------------------------------
# Report
# -------------------------------------------------------------------

echo ""
echo "Agent update check:"
[ -n "$claude_baked" ] || [ -n "$claude_latest" ] && compare "Claude" "$claude_baked" "$claude_latest"
[ -n "$codex_baked" ] || [ -n "$codex_latest" ] && compare "Codex" "$codex_baked" "$codex_latest"
echo ""
