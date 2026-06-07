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

registry_base_digest() {
	docker buildx imagetools inspect "$BASE_SOURCE_IMAGE" --format '{{.Manifest.Digest}}' 2>/dev/null || true
}

local_base_digest() {
	docker image inspect "$BASE_SOURCE_IMAGE" --format '{{range .RepoDigests}}{{println .}}{{end}}' 2>/dev/null \
		| sed -n 's/.*@\(sha256:[0-9a-f]\{64\}\).*/\1/p' | head -1
}

resolve_base_source_digest() {
	# Usage: resolve_base_source_digest <with_pull>. With --pull the build uses
	# the registry-latest base, so stamp the registry digest. Otherwise the build
	# reuses whatever base is cached locally; stamp that, falling back to the
	# registry digest when the base is not present locally (buildx will pull it).
	if [ "$1" = true ]; then
		BASE_SOURCE_DIGEST="$(registry_base_digest)"
	else
		BASE_SOURCE_DIGEST="$(local_base_digest)"
		[ -n "$BASE_SOURCE_DIGEST" ] || BASE_SOURCE_DIGEST="$(registry_base_digest)"
	fi
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

	if [ "$with_pull" = true ]; then
		cmd+=(--pull)
	fi

	if [ "$with_no_cache" = true ]; then
		cmd+=(--no-cache)
	fi

	cmd+=("${target_args[@]}")

	echo "Running: CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION} CODEX_VERSION=${CODEX_VERSION} POWBOX_COMMIT=${POWBOX_COMMIT} ${cmd[*]}"
	CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" \
		CODEX_VERSION="$CODEX_VERSION" \
		BASE_SOURCE_IMAGE="$BASE_SOURCE_IMAGE" \
		BASE_SOURCE_DIGEST="$BASE_SOURCE_DIGEST" \
		POWBOX_COMMIT="$POWBOX_COMMIT" \
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
		docker buildx bake --file "${ROOT_DIR}/docker-bake.hcl" base
}

# --pull only makes sense for the base image (whose FROM is an upstream
# registry image). The agent image's only FROM is the locally-built
# powbox-agent-base, so passing --pull to its bake invocation would make
# buildx try to resolve it from a registry and fail. When the user requests
# --pull on the agent target, refresh the base first (cascading any digest
# change into the agent layers automatically) and then build the agent
# without --pull.
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
