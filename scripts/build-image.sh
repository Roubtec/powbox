#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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
	local target_args=("$@")
	local cmd=(docker buildx bake --file "${ROOT_DIR}/docker-bake.hcl")

	if [ "$PULL" = true ]; then
		cmd+=(--pull)
	fi

	if [ "$NO_CACHE" = true ]; then
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

	echo "Base image powbox-agent-base:latest was not found locally. Building it first."
	CLAUDE_CODE_VERSION="$CLAUDE_CODE_VERSION" \
		CODEX_VERSION="$CODEX_VERSION" \
		docker buildx bake --file "${ROOT_DIR}/docker-bake.hcl" base
}

case "$TARGET" in
all)
	run_bake base
	run_bake claude codex
	;;
claude | codex)
	ensure_base_image
	run_bake "$TARGET"
	;;
base)
	run_bake base
	;;
esac
