#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

VERSION="latest"
if [ "$#" -gt 0 ] && [[ "${1:-}" != --* ]]; then
	VERSION="$1"
	shift
fi

exec "${ROOT_DIR}/build.sh" codex --codex-version "$VERSION" "$@"
