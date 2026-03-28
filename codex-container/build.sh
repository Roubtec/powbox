#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-latest}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

echo "Building codex-dev image with Codex CLI version: $VERSION"
docker compose -f "$COMPOSE_FILE" build --build-arg CODEX_VERSION="$VERSION" --no-cache

echo "Done. Image: codex-dev:latest"
echo "Run: ./codex-container.sh /path/to/project"
