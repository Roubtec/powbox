#!/usr/bin/env bash
# Compare the agent versions baked into the local unified image against the
# latest releases on npm and report any available updates.
#
# With --porcelain, suppress all human-readable output and instead print one
# tab-separated row per component for `agent-update` to consume:
#
#     base	<ok|stale|unknown>	<baked-digest|->	<latest-digest|->
#     claude	<ok|stale|unknown>	<baked-version|->	<latest-version|->
#     codex	<ok|stale|unknown>	<baked-version|->	<latest-version|->
#
# A component is stale when a latest value is known and differs from what is
# baked in (a missing image counts as stale); unknown means the latest could not
# be determined (npm/registry unreachable) and must never force a rebuild. The
# baked/latest versions let agent-update pin each binary so Docker rebuilds only
# the layers that actually changed.
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

AGENT_IMAGE="${positional[0]:-powbox-agent:latest}"
BASE_IMAGE="${positional[1]:-powbox-agent-base:latest}"

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

# Read both agents' baked versions in a SINGLE container start (the unified
# image carries both binaries). Emits two lines, tagged so each can be parsed
# back regardless of either command's own output quirks:
#   CLAUDE:<raw claude --version line>
#   CODEX:<raw codex --version line>
baked_versions_raw() {
	docker run --rm --entrypoint sh "$1" -c '
		printf "CLAUDE:%s\n" "$(claude --version 2>/dev/null | head -1)"
		printf "CODEX:%s\n" "$(codex --version 2>/dev/null | head -1)"
	' 2>/dev/null
}

latest_npm_version() {
	local ver
	ver="$(npm view "$1" version 2>/dev/null)" || true
	echo "$ver"
}

# Digest (label) the base image records for the upstream image it was built from.
# Docker renders a missing label as the literal "<no value>" when the image
# carries no labels map at all; normalize that to empty so unlabeled images fall
# through to the default-source fallback and staleness logic instead of looking
# like a set-but-bogus value.
image_label() {
	local val
	val="$(docker image inspect "$1" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null)" || true
	[ "$val" = "<no value>" ] && val=""
	echo "$val"
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

# Classify a baked/latest pair as ok | stale | unknown. A latest value that
# could not be determined (npm/registry unreachable) is "unknown" and must never
# force a rebuild; an empty baked value (missing/unknown image) with a known
# latest counts as "stale" so agent-update will build it.
component_status() {
	local baked="$1" latest="$2"
	if [ -z "$latest" ]; then
		echo unknown
	elif [ "$baked" != "$latest" ]; then
		echo stale
	else
		echo ok
	fi
}

# The marker emitted here must mirror component_status: a known latest with a missing or
# unlabeled (empty) baked value is stale and needs a build, so it is flagged just
# like a version mismatch. This keeps the human report consistent with the
# porcelain output that agent-update consumes. An unknown latest (registry/npm
# unreachable) is undeterminable and is never flagged.
compare_base() {
	local baked="$1" latest="$2"
	local b l
	b="$(short_digest "$baked")"
	l="$(short_digest "$latest")"
	if [ -z "$baked" ]; then
		# Image missing or unlabeled: a build is needed when the upstream is known.
		if [ -n "$latest" ]; then
			printf '  %-8s  baked: %-14s  latest: %s  ** update available **\n' "Base" "(unknown)" "$l"
		else
			printf '  %-8s  baked: %-14s  latest: %s\n' "Base" "(unknown)" "(unknown)"
		fi
		return
	fi
	if [ -z "$latest" ]; then
		printf '  %-8s  baked: %-14s  latest: %s\n' "Base" "$b" "(unknown)"
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
		# Image missing: a build is needed when the upstream is known.
		if [ -n "$latest" ]; then
			printf '  %-8s  baked: %-14s  latest: %s  ** update available **\n' "$agent" "(unknown)" "$latest"
		else
			printf '  %-8s  baked: %-14s  latest: %s\n' "$agent" "(unknown)" "(unknown)"
		fi
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

if has_image "$AGENT_IMAGE"; then
	versions_raw="$(baked_versions_raw "$AGENT_IMAGE")"
	claude_baked="$(printf '%s\n' "$versions_raw" | sed -n 's/^CLAUDE://p' | head -1 | sed 's/ *(.*//; s/[[:space:]]*$//')"
	codex_baked="$(printf '%s\n' "$versions_raw" | sed -n 's/^CODEX://p' | head -1 | sed 's/^codex-cli *//; s/[[:space:]]*$//')"
else
	note "Image $AGENT_IMAGE not found — baked agent versions will be shown as (unknown)."
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
# If the registry is then unreachable, base_latest stays empty and component_status
# treats the base as "unknown" — an unreachable registry must not force a rebuild.
[ -n "$base_source" ] || base_source="$(default_base_source)"

if [ -n "$base_source" ]; then
	base_latest="$(registry_digest "$base_source")"
fi

# -------------------------------------------------------------------
# Porcelain: one tab-separated row per component (see header comment).
# -------------------------------------------------------------------

if $PORCELAIN; then
	printf '%s\t%s\t%s\t%s\n' base \
		"$(component_status "$(short_digest "$base_baked")" "$(short_digest "$base_latest")")" \
		"${base_baked:--}" "${base_latest:--}"
	printf '%s\t%s\t%s\t%s\n' claude \
		"$(component_status "$claude_baked" "$claude_latest")" \
		"${claude_baked:--}" "${claude_latest:--}"
	printf '%s\t%s\t%s\t%s\n' codex \
		"$(component_status "$codex_baked" "$codex_latest")" \
		"${codex_baked:--}" "${codex_latest:--}"
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
# Codex before Claude: Codex updates less often and the Claude layer is built on
# top of it, so the report mirrors the Docker layer stacking (base -> codex -> claude).
if [ -n "$codex_baked" ] || [ -n "$codex_latest" ]; then compare "Codex" "$codex_baked" "$codex_latest"; fi
if [ -n "$claude_baked" ] || [ -n "$claude_latest" ]; then compare "Claude" "$claude_baked" "$claude_latest"; fi
echo ""
