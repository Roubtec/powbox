#!/usr/bin/env bash
set -euo pipefail

# Usage: ./codex-container.sh [path-to-project] [--build] [--detach] [--shell] [--volatile] [--persist] [--resume] [--exec "task"]
# Examples:
#   ./codex-container.sh /path/to/project
#   ./codex-container.sh . --build
#   ./codex-container.sh /path/to/project --shell        # opens zsh instead of codex
#   ./codex-container.sh /path/to/project --exec "fix the tests"  # headless mode

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
EXEC_TASK=""

while [ $# -gt 0 ]; do
  case $1 in
    --build) BUILD=true ;;
    --detach) DETACH=true ;;
    --shell) SHELL_ONLY=true ;;
    --volatile) VOLATILE=true ;;
    --persist) PERSIST=true ;;
    --resume) RESUME=true ;;
    --exec)
      if [ $# -lt 2 ]; then
        echo "Error: --exec requires a following task argument." >&2
        exit 1
      fi
      shift
      EXEC_TASK="$1"
      ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

export WORKSPACE_PATH="$PROJECT_PATH"
export CODEX_HOST_CONFIG_DIR="${CODEX_HOST_CONFIG_DIR:-$HOME/.codex}"
GH_HOST_CONFIG_DIR="${GH_HOST_CONFIG_DIR:-$HOME/.config/gh}"
GIT_CONFIG_PATH="${GIT_CONFIG_PATH:-$HOME/.gitconfig}"
export PROJECT_NAME

CONTAINER_NAME="codex-${PROJECT_NAME}"
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
elif [ -n "$EXEC_TASK" ]; then
  CMD=(codex exec "$EXEC_TASK")
else
  CMD=(codex --dangerously-bypass-approvals-and-sandbox)
fi

CODEX_SEED_ARGS=()
if [ -d "$CODEX_HOST_CONFIG_DIR" ]; then
  CODEX_SEED_ARGS=(-v "${CODEX_HOST_CONFIG_DIR}:/home/node/.codex-host:ro")
fi

GIT_CONFIG_ARGS=()
if [ -f "$GIT_CONFIG_PATH" ]; then
  GIT_CONFIG_ARGS=(-v "${GIT_CONFIG_PATH}:/home/node/.gitconfig-host:ro")
fi

GH_CONFIG_ARGS=()
if [ -d "$GH_HOST_CONFIG_DIR" ]; then
  GH_CONFIG_ARGS=(-v "${GH_HOST_CONFIG_DIR}:/home/node/.config/gh-host:ro")
fi

# Node_modules volume name for this project (shared with Claude containers)
NM_VOLUME="agent-nm-${PROJECT_NAME}"

docker compose -f "$COMPOSE_FILE" run --rm --no-deps --user root --entrypoint /bin/sh \
  -v "${NM_VOLUME}:/mnt/node_modules" \
  codex \
  -lc 'mkdir -p /mnt/node_modules && chown node:node /mnt/node_modules'

# Launch container
if [ "$DETACH" = true ]; then
  docker compose -f "$COMPOSE_FILE" run -d \
    --name "$CONTAINER_NAME" \
    -e "CONTAINER_NAME=$CONTAINER_NAME" \
    -e "OPENAI_API_KEY=${OPENAI_API_KEY:-}" \
    "${CODEX_SEED_ARGS[@]}" \
    "${GIT_CONFIG_ARGS[@]}" \
    "${GH_CONFIG_ARGS[@]}" \
    -v "${NM_VOLUME}:/workspace/node_modules" \
    codex \
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
    -e "OPENAI_API_KEY=${OPENAI_API_KEY:-}" \
    "${CODEX_SEED_ARGS[@]}" \
    "${GIT_CONFIG_ARGS[@]}" \
    "${GH_CONFIG_ARGS[@]}" \
    -v "${NM_VOLUME}:/workspace/node_modules" \
    codex \
    "${CMD[@]}"
fi
