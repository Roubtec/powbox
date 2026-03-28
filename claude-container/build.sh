#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-latest}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

echo "Building claude-code-dev image with Claude Code version: $VERSION"
docker compose -f "$COMPOSE_FILE" build --build-arg CLAUDE_CODE_VERSION="$VERSION" --no-cache

echo "Done. Image: claude-code-dev:latest"
echo "Run: ./claude-container.sh /path/to/project"
