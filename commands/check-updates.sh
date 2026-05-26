#!/usr/bin/env bash
# Compare the agent versions baked into the local Docker images against the
# latest releases on npm and report any available updates.
#
# With --porcelain, suppress all human-readable output and instead print just
# the names of the stale build targets (base|claude|codex), one per line, for
# `agent-update` to consume. A target is stale when a latest version is known
# and differs from what is baked in (a missing image counts as stale).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

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

# Upstream image the base is built FROM, parsed from the base Dockerfile (the
# same source the build scripts use, so it never drifts). Used as a fallback
# when the local base image is absent or unlabeled, so a missing base can still
# be compared against the registry and reported stale. Emits nothing if the
# Dockerfile can't be read — an undeterminable upstream must not force a rebuild.
default_base_source() {
	local dockerfile="${ROOT_DIR}/docker/base/Dockerfile"
	[ -f "$dockerfile" ] || return 0
	sed -n 's/^FROM[[:space:]]\+\([^[:space:]]\+\).*/\1/p' "$dockerfile" | head -1
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

# The marker emitted here must mirror is_stale: a known latest with a missing or
# unlabeled (empty) baked value is stale and needs a build, so it is flagged just
# like a version mismatch. This keeps the human report consistent with the
# porcelain output that agent-update consumes.
compare_base() {
	local baked="$1" latest="$2"
	local b l
	b="$(short_digest "$baked")"
	l="$(short_digest "$latest")"
	# Latest unknown (registry unreachable): can't determine staleness, never flag.
	if [ -z "$latest" ]; then
		printf '  %-8s  baked: %-14s  latest: %s\n' "Base" "${b:-(unknown)}" "(unknown)"
		return
	fi
	# Image missing or unlabeled but upstream known: a build is needed.
	if [ -z "$baked" ]; then
		printf '  %-8s  baked: %-14s  latest: %s  ** update available **\n' "Base" "(unknown)" "$l"
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
	# Latest unknown (npm unreachable): can't determine staleness, never flag.
	if [ -z "$latest" ]; then
		printf '  %-8s  %s  latest: (unknown)\n' "$agent" "${baked:-(unknown)}"
		return
	fi
	# Image missing but latest known: a build is needed.
	if [ -z "$baked" ]; then
		printf '  %-8s  baked: %-14s  latest: %s  ** update available **\n' "$agent" "(unknown)" "$latest"
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

# When the local base image is absent (or carries no source label) we can't
# read the upstream it was built from, but a missing base should still count as
# stale. Fall back to the Dockerfile's upstream so base_latest can be resolved.
# If the registry is then unreachable, base_latest stays empty and is_stale
# treats the base as not-stale — an unreachable registry must not force a rebuild.
[ -n "$base_source" ] || base_source="$(default_base_source)"

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
#
# The "** update available **" marker emitted below is parsed by agent-update
# (shell/powbox.*) to decide whether to prompt — keep that phrase stable.
# -------------------------------------------------------------------

echo ""
echo "Agent update check:"
if [ -n "$base_baked" ] || [ -n "$base_latest" ]; then compare_base "$base_baked" "$base_latest"; fi
if [ -n "$claude_baked" ] || [ -n "$claude_latest" ]; then compare "Claude" "$claude_baked" "$claude_latest"; fi
if [ -n "$codex_baked" ] || [ -n "$codex_latest" ]; then compare "Codex" "$codex_baked" "$codex_latest"; fi
echo ""
