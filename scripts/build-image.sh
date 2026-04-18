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
base | claude | codex | all) ;;
*)
	echo "Unknown build target: $TARGET" >&2
	exit 1
	;;
esac

run_bake() {
	# Usage: run_bake <with_pull> <with_no_cache> <targets...>
	local with_pull="$1"
	shift
	local with_no_cache="$1"
	shift
	local target_args=("$@")
	local cmd=(docker buildx bake --file "${ROOT_DIR}/docker-bake.hcl")

	if [ "$with_pull" = true ]; then
		cmd+=(--pull)
	fi

	if [ "$with_no_cache" = true ]; then
		cmd+=(--no-cache)
	fi

	cmd+=("${target_args[@]}")

	echo "Running: CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION} CODEX_VERSION=${CODEX_VERSION} ${cmd[*]}"
	CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" \
		CODEX_VERSION="$CODEX_VERSION" \
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
	CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" \
		CODEX_VERSION="$CODEX_VERSION" \
		docker buildx bake --file "${ROOT_DIR}/docker-bake.hcl" base
}

# --pull only makes sense for the base image (whose FROM is an upstream
# registry image). The agent images' only FROM is the locally-built
# powbox-agent-base, so passing --pull to their bake invocation would make
# buildx try to resolve it from a registry and fail. When the user requests
# --pull on an agent target, refresh the base first (cascading any digest
# change into the agent layers automatically) and then build the agent
# without --pull.
case "$TARGET" in
all)
	run_bake "$PULL" "$NO_CACHE" base
	run_bake false "$NO_CACHE" claude codex
	;;
claude | codex)
	if [ "$PULL" = true ]; then
		run_bake true false base
	else
		ensure_base_image
	fi
	run_bake false "$NO_CACHE" "$TARGET"
	;;
base)
	run_bake "$PULL" "$NO_CACHE" base
	;;
esac
