#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

TARGET="${1:-all}"
shift || true

CLAUDE_CODE_VERSION="latest"
CODEX_VERSION="latest"
NO_CACHE=false
PULL=false

while [ "$#" -gt 0 ]; do
	case "$1" in
	--claude-version)
		shift
		CLAUDE_CODE_VERSION="${1:?missing value for --claude-version}"
		;;
	--codex-version)
		shift
		CODEX_VERSION="${1:?missing value for --codex-version}"
		;;
	--no-cache)
		NO_CACHE=true
		;;
	--pull)
		PULL=true
		;;
	*)
		echo "Unknown build option: $1" >&2
		exit 1
		;;
	esac
	shift
done

case "$TARGET" in
base | agent | all) ;;
*)
	echo "Unknown build target: $TARGET" >&2
	exit 1
	;;
esac

# Upstream base image, parsed from the base Dockerfile's FROM so it never drifts
# from what is actually built. BASE_SOURCE_DIGEST is resolved lazily just before
# the base target is built and stamped onto the image as a label (see
# docker/base/Dockerfile) so agent-check-updates can detect a newer base.
BASE_SOURCE_IMAGE="$(sed -n 's/^FROM[[:space:]]\+\([^[:space:]]\+\).*/\1/p' "${ROOT_DIR}/docker/base/Dockerfile" | head -1)"
BASE_SOURCE_DIGEST=""

# Powbox commit that built this image, baked into the agent's top layers and the
# skill ownership marker for provenance. A `-dirty` suffix flags an uncommitted
# worktree so a stamped commit is never silently misleading. Falls back to
# "unknown" outside a git checkout.
powbox_commit() {
	local sha
	sha="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null)" || {
		echo unknown
		return
	}
	if [ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null)" ]; then
		sha="${sha}-dirty"
	fi
	echo "$sha"
}
POWBOX_COMMIT="$(powbox_commit)"

image_label() {
	# Echo a label value off a local image, or empty when the image/label is absent.
	local v
	v="$(docker image inspect "$1" --format "{{ index .Config.Labels \"$2\" }}" 2>/dev/null)" || return 0
	[ "$v" = "<no value>" ] && v=""
	printf '%s' "$v"
}

base_image_id() {
	# Content ID of the local base image (empty when absent). The parent half of
	# the Codex layer's cache key: stamped onto the agent (powbox.base.image.id)
	# and compared against the previous agent's recorded value to tell whether a
	# separate base rebuild will bust that layer.
	docker image inspect powbox-agent-base:latest --format '{{.Id}}' 2>/dev/null || true
}

# Commit that built the Codex install layer. Stamping it inside that layer would
# bust its cache on every commit (defeating the Codex-below-Claude ordering), so
# resolve it here: use HEAD when the layer will rebuild this run, otherwise carry
# the existing image's recorded value forward. The reuse test mirrors Docker's
# cache key for that layer: its parent (the base image) AND the install
# instruction (CODEX_VERSION). See docs/skills-refresh-and-provenance.md.
POWBOX_COMMIT_CODEX="$POWBOX_COMMIT"
resolve_codex_commit() {
	# Any of these rebuild the Codex layer, so it was built at HEAD.
	[ "$NO_CACHE" = true ] && return 0
	[ "$PULL" = true ] && return 0
	case "$TARGET" in base | all) return 0 ;; esac
	docker image inspect powbox-agent:latest >/dev/null 2>&1 || return 0
	# The Codex layer's parent is the base image, so a base that differs from the
	# one the previous agent was built on (e.g. a separate `build.sh base`)
	# rebuilds the Codex layer regardless of version. Only an identical base ID
	# means the layer can be reused; an absent base (about to be built) or a
	# previous agent with no recorded base ID counts as changed -> HEAD.
	local cur_base_id prev_base_id
	cur_base_id="$(base_image_id)"
	prev_base_id="$(image_label powbox-agent:latest powbox.base.image.id)"
	[ -n "$cur_base_id" ] && [ "$cur_base_id" = "$prev_base_id" ] || return 0
	local prev_ver prev_commit
	prev_ver="$(image_label powbox-agent:latest powbox.codex.version)"
	prev_commit="$(image_label powbox-agent:latest powbox.commit.codex)"
	# Same base and same Codex version => layer reused, so carry its recorded
	# commit forward. An image built before provenance labelling has none to
	# carry, and we cannot know which commit built the reused layer, so record
	# "unknown" rather than misattributing this build's HEAD to it. A differing
	# version rebuilds the layer at HEAD (the default).
	if [ "$prev_ver" = "$CODEX_VERSION" ]; then
		POWBOX_COMMIT_CODEX="${prev_commit:-unknown}"
	fi
}
resolve_codex_commit

registry_base_digest() {
	docker buildx imagetools inspect "$BASE_SOURCE_IMAGE" --format '{{.Manifest.Digest}}' 2>/dev/null || true
}

local_base_digest() {
	# Must return empty -- never fail -- when the image is absent (fresh host
	# that has not pulled the upstream base yet): under set -euo pipefail a
	# failing `docker image inspect` would otherwise abort the whole script
	# with no output. The caller falls back to registry_base_digest.
	docker image inspect "$BASE_SOURCE_IMAGE" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
		| sed -n 's/.*@\(sha256:[0-9a-f]\{64\}\).*/\1/p' | head -1 || true
}

resolve_base_source_digest() {
	# Usage: resolve_base_source_digest <with_pull>. --pull refreshes the upstream
	# tag in the LOCAL IMAGE STORE via `docker pull`. buildx's own --pull only
	# updates BuildKit's separate build cache, leaving the `docker images` entry
	# stale; pulling into the store means this bake builds FROM the refreshed image
	# AND the next no-pull rebuild reuses it, so the stamped digest always matches
	# what we actually built from. Read it back from the store afterwards, falling
	# back to the registry digest only when the base is absent locally (e.g. the
	# pull failed offline) — buildx pulls it at bake time.
	if [ "$1" = true ]; then
		docker pull "$BASE_SOURCE_IMAGE" >/dev/null 2>&1 || true
	fi
	BASE_SOURCE_DIGEST="$(local_base_digest)"
	[ -n "$BASE_SOURCE_DIGEST" ] || BASE_SOURCE_DIGEST="$(registry_base_digest)"
}

run_bake() {
	# Usage: run_bake <with_pull> <with_no_cache> <targets...>
	local with_pull="$1"
	shift
	local with_no_cache="$1"
	shift
	local target_args=("$@")

	case " ${target_args[*]} " in
	*" base "*) resolve_base_source_digest "$with_pull" ;;
	esac

	local cmd=(docker buildx bake --file "${ROOT_DIR}/docker-bake.hcl")

	# No --pull here: resolve_base_source_digest already pulled the upstream base
	# into the local image store when --pull was requested, and this bake builds
	# FROM that store image. A bake --pull would re-resolve from the registry into
	# BuildKit's cache instead, re-introducing the store/cache split.
	if [ "$with_no_cache" = true ]; then
		cmd+=(--no-cache)
	fi

	cmd+=("${target_args[@]}")

	echo "Running: CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION} CODEX_VERSION=${CODEX_VERSION} POWBOX_COMMIT=${POWBOX_COMMIT} POWBOX_COMMIT_CODEX=${POWBOX_COMMIT_CODEX} ${cmd[*]}"
	CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" \
		CODEX_VERSION="$CODEX_VERSION" \
		BASE_SOURCE_IMAGE="$BASE_SOURCE_IMAGE" \
		BASE_SOURCE_DIGEST="$BASE_SOURCE_DIGEST" \
		POWBOX_COMMIT="$POWBOX_COMMIT" \
		POWBOX_COMMIT_CODEX="$POWBOX_COMMIT_CODEX" \
		POWBOX_BASE_IMAGE_ID="$(base_image_id)" \
		"${cmd[@]}"
}

ensure_base_image() {
	if docker image inspect powbox-agent-base:latest >/dev/null 2>&1; then
		return
	fi

	# Build the base image without --no-cache. That flag applies to the
	# top-layer agent build only (i.e. "don't reuse cached agent layers"). When
	# the base image is simply absent locally there is nothing to skip caching
	# for, and rebuilding it fresh unconditionally on every no-cache top-layer
	# build would be unnecessarily slow. Use `build.sh base --no-cache` if you
	# explicitly want a fresh base.
	echo "Base image powbox-agent-base:latest was not found locally. Building it first."
	resolve_base_source_digest false
	CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" \
		CODEX_VERSION="$CODEX_VERSION" \
		BASE_SOURCE_IMAGE="$BASE_SOURCE_IMAGE" \
		BASE_SOURCE_DIGEST="$BASE_SOURCE_DIGEST" \
		POWBOX_COMMIT="$POWBOX_COMMIT" \
		POWBOX_COMMIT_CODEX="$POWBOX_COMMIT_CODEX" \
		docker buildx bake --file "${ROOT_DIR}/docker-bake.hcl" base
}

# --pull only makes sense for the base image (whose FROM is an upstream
# registry image); it re-pulls that upstream tag into the local image store
# (see resolve_base_source_digest). The agent image's only FROM is the
# locally-built powbox-agent-base, which is not a registry image, so when the
# user requests --pull on the agent target we refresh the base first (cascading
# any digest change into the agent layers automatically) and then build the
# agent.
case "$TARGET" in
all)
	run_bake "$PULL" "$NO_CACHE" base
	run_bake false "$NO_CACHE" agent
	;;
agent)
	if [ "$PULL" = true ]; then
		run_bake true false base
	else
		ensure_base_image
	fi
	run_bake false "$NO_CACHE" agent
	;;
base)
	run_bake "$PULL" "$NO_CACHE" base
	;;
esac
