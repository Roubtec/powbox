#!/usr/bin/env bash
set -euo pipefail

# Usage: ./claude-container.sh [path-to-project] [--build] [--detach] [--shell] [--volatile] [--persist] [--resume]
# Examples:
#   ./claude-container.sh /c/Projects/MyProject
#   ./claude-container.sh . --build
#   ./claude-container.sh /c/Projects/MyProject --shell   # opens zsh instead of claude

PROJECT_PATH="${1:-.}"
# Filter out flags from PROJECT_PATH
[[ "$PROJECT_PATH" == --* ]] && PROJECT_PATH="."
PROJECT_PATH="$(cd "$PROJECT_PATH" 2>/dev/null && pwd)"
PROJECT_BASENAME="$(basename "$PROJECT_PATH")"
PROJECT_HASH="$(printf '%s' "$PROJECT_PATH" | sha256sum | cut -c1-12)"
PROJECT_NAME="$(printf '%s' "$PROJECT_BASENAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^-//; s/-$//')-$PROJECT_HASH"

BUILD=false
DETACH=false
SHELL_ONLY=false
VOLATILE=false
PERSIST=false
RESUME=false

for arg in "$@"; do
  case $arg in
    --build) BUILD=true ;;
    --detach) DETACH=true ;;
    --shell) SHELL_ONLY=true ;;
    --volatile) VOLATILE=true ;;
    --persist) PERSIST=true ;;
    --resume) RESUME=true ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

export WORKSPACE_PATH="$PROJECT_PATH"
export CLAUDE_HOST_CONFIG_DIR="${CLAUDE_HOST_CONFIG_DIR:-$HOME/.claude}"
GH_HOST_CONFIG_DIR="${GH_HOST_CONFIG_DIR:-$HOME/.config/gh}"
GIT_CONFIG_PATH="${GIT_CONFIG_PATH:-$HOME/.gitconfig}"
export PROJECT_NAME

CONTAINER_NAME="claude-${PROJECT_NAME}"
CONTAINER_EXISTS=false
CONTAINER_RUNNING=false

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  CONTAINER_EXISTS=true
  if [ "$(docker container inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
    CONTAINER_RUNNING=true
  fi
fi

if [ "$BUILD" = true ]; then
  docker compose -f "$COMPOSE_FILE" build
fi

if [ "$RESUME" = true ]; then
  if [ "$CONTAINER_EXISTS" != true ]; then
    echo "No persisted container named ${CONTAINER_NAME} was found. Start it once normally, or with --persist if you want to be explicit." >&2
    exit 1
  fi

  exec docker start -ai "$CONTAINER_NAME"
fi

if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
  if [ "$CONTAINER_RUNNING" = true ]; then
    if [ "$DETACH" = true ]; then
      echo "Container ${CONTAINER_NAME} is already running."
      exit 0
    fi

    exec docker attach "$CONTAINER_NAME"
  fi

  if [ "$DETACH" = true ]; then
    exec docker start "$CONTAINER_NAME"
  fi

  exec docker start -ai "$CONTAINER_NAME"
fi

# Determine command to run
if [ "$SHELL_ONLY" = true ]; then
  CMD=(zsh)
else
  CMD=(claude --dangerously-skip-permissions)
fi

CLAUDE_SEED_ARGS=()
if [ -d "$CLAUDE_HOST_CONFIG_DIR" ]; then
  CLAUDE_SEED_ARGS=(-v "${CLAUDE_HOST_CONFIG_DIR}:/home/node/.claude-host:ro")
fi

GIT_CONFIG_ARGS=()
if [ -f "$GIT_CONFIG_PATH" ]; then
  GIT_CONFIG_ARGS=(-v "${GIT_CONFIG_PATH}:/home/node/.gitconfig-host:ro")
fi

GH_CONFIG_ARGS=()
if [ -d "$GH_HOST_CONFIG_DIR" ]; then
  GH_CONFIG_ARGS=(-v "${GH_HOST_CONFIG_DIR}:/home/node/.config/gh-host:ro")
fi

# Node_modules volume name for this project
NM_VOLUME="agent-nm-${PROJECT_NAME}"

docker compose -f "$COMPOSE_FILE" run --rm --no-deps --user root --entrypoint /bin/sh \
  -v "${NM_VOLUME}:/mnt/node_modules" \
  claude \
  -lc 'mkdir -p /mnt/node_modules && chown node:node /mnt/node_modules'

# Launch container
if [ "$DETACH" = true ]; then
  docker compose -f "$COMPOSE_FILE" run -d \
    --name "$CONTAINER_NAME" \
    -e "CONTAINER_NAME=$CONTAINER_NAME" \
    "${CLAUDE_SEED_ARGS[@]}" \
    "${GIT_CONFIG_ARGS[@]}" \
    "${GH_CONFIG_ARGS[@]}" \
    -v "${NM_VOLUME}:/workspace/node_modules" \
    claude \
    "${CMD[@]}"
  echo "Container ${CONTAINER_NAME} running in background."
  echo "Attach with: docker exec -it ${CONTAINER_NAME} zsh"
else
  RUN_ARGS=()
  if [ "$VOLATILE" = true ] && [ "$PERSIST" != true ]; then
    RUN_ARGS+=(--rm)
  fi

  docker compose -f "$COMPOSE_FILE" run "${RUN_ARGS[@]}" \
    --name "$CONTAINER_NAME" \
    -e "CONTAINER_NAME=$CONTAINER_NAME" \
    "${CLAUDE_SEED_ARGS[@]}" \
    "${GIT_CONFIG_ARGS[@]}" \
    "${GH_CONFIG_ARGS[@]}" \
    -v "${NM_VOLUME}:/workspace/node_modules" \
    claude \
    "${CMD[@]}"
fi
