#!/usr/bin/env bash
set -euo pipefail

AGENT="${1:?usage: launch-agent.sh <claude|codex> [project-path] [--build] [--detach] [--shell] [--volatile] [--persist] [--resume] [--exec <task> (codex only)]}"
shift

case "$AGENT" in
claude | codex) ;;
*)
	echo "Unknown agent: $AGENT" >&2
	exit 1
	;;
esac

PROJECT_PATH="."
POSITIONAL_SET=false
BUILD=false
DETACH=false
SHELL_ONLY=false
VOLATILE=false
PERSIST=false
RESUME=false
EXEC_TASK=""
CTX_PATH=""

while [ "$#" -gt 0 ]; do
	case "$1" in
	--build)
		BUILD=true
		;;
	--detach)
		DETACH=true
		;;
	--shell)
		SHELL_ONLY=true
		;;
	--volatile)
		VOLATILE=true
		;;
	--persist)
		PERSIST=true
		;;
	--resume)
		RESUME=true
		;;
	--ctx)
		shift
		CTX_PATH="${1:?missing path for --ctx}"
		;;
	--exec)
		if [ "$AGENT" != "codex" ]; then
			echo "--exec is only supported for codex." >&2
			exit 1
		fi
		shift
		EXEC_TASK="${1:?missing task for --exec}"
		;;
	--*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	*)
		if [ "$POSITIONAL_SET" = true ]; then
			echo "Unexpected extra positional argument: $1" >&2
			exit 1
		fi
		PROJECT_PATH="$1"
		POSITIONAL_SET=true
		;;
	esac
	shift
done

if [ ! -d "$PROJECT_PATH" ]; then
	echo "Error: project path does not exist: ${PROJECT_PATH}" >&2
	exit 1
fi

if [ -n "$CTX_PATH" ] && [ ! -d "$CTX_PATH" ]; then
	echo "Error: context path does not exist: ${CTX_PATH}" >&2
	exit 1
fi
if [ -n "$CTX_PATH" ]; then
	CTX_PATH="$(cd "$CTX_PATH" && pwd -P)"
fi
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd -P)"
# Only strip the trailing slash when the path is not the filesystem root ("/"), since
# stripping "/" would produce an empty string and break basename and Docker bind-mount paths.
if [ "$PROJECT_PATH" != "/" ]; then
	PROJECT_PATH="${PROJECT_PATH%/}"
fi
PROJECT_BASENAME="$(basename "$PROJECT_PATH")"

project_hash() {
	local input="${1:-}"
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum | cut -c1-12
	elif command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 | cut -c1-12
	elif command -v openssl >/dev/null 2>&1; then
		printf '%s' "$input" | openssl dgst -sha256 | sed 's/^.* //' | cut -c1-12
	else
		echo "Error: no hashing command found (need sha256sum, shasum, or openssl)." >&2
		echo "" >&2
		echo "A unique hash of the project path is used to generate the container name." >&2
		echo "Without it, containers for different projects may share the same name, causing" >&2
		echo "one project's container to be silently reused for another — which can be destructive." >&2
		echo "" >&2
		echo "Install one of the following and retry:" >&2
		echo "  sha256sum  — part of GNU coreutils (Linux, Git Bash, WSL)" >&2
		echo "  shasum     — bundled with Perl (macOS, many Linux distros)" >&2
		echo "  openssl    — https://www.openssl.org/" >&2
		return 1
	fi
}

# Normalise a path for /ctx comparison.
# On Windows (MSYS/Cygwin), Docker Desktop may report bind-mount sources using
# Linux-style prefixes rather than the native drive:/... form that the shell sees.
# Convert all known representations to a canonical drive:/... form so an unchanged
# mount compares equal regardless of which format Docker happens to report.
# On Linux/macOS paths are returned as-is (case-sensitive, trailing slash stripped).
# Backslash-to-slash conversion is Windows-only; on POSIX systems a backslash is
# a valid path character and must not be silently altered.
normalize_ctx_path() {
	local p
	p="$1"
	case "$(uname -s)" in
		MINGW* | MSYS* | CYGWIN*)
			# Normalize backslashes to forward slashes (Windows paths only).
			p="$(printf '%s' "$p" | sed 's|\\|/|g')"
			# Lowercase first so that the prefix patterns below only need to match [a-z].
			# This must stay above the sed substitutions — moving it after them would
			# leave prefixes intact when Docker reports an uppercase drive letter.
			p="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
			# /run/desktop/mnt/host/c and /run/desktop/mnt/host/c/... → c: and c:/...
			p="$(printf '%s' "$p" | sed 's|^/run/desktop/mnt/host/\([a-z]\)\(/.*\)\{0,1\}$|\1:\2|')"
			# /host_mnt/c and /host_mnt/c/... → c: and c:/...
			p="$(printf '%s' "$p" | sed 's|^/host_mnt/\([a-z]\)\(/.*\)\{0,1\}$|\1:\2|')"
			# /mnt/c and /mnt/c/... → c: and c:/...
			p="$(printf '%s' "$p" | sed 's|^/mnt/\([a-z]\)\(/.*\)\{0,1\}$|\1:\2|')"
			# MSYS/Git Bash native form: /c and /c/... → c: and c:/...
			p="$(printf '%s' "$p" | sed 's|^/\([a-z]\)\(/.*\)\{0,1\}$|\1:\2|')"
			;;
	esac
	# Strip trailing slash.
	printf '%s' "${p%/}"
}

# On Windows (MSYS/Cygwin), the filesystem is typically case-insensitive and the terminal
# may report paths with inconsistent capitalisation, so we normalise to lowercase before
# hashing — matching PowerShell's ToLowerInvariant() behaviour.
# On Linux and macOS the filesystem is case-sensitive, so two paths differing only by case
# are genuinely distinct directories; lowercasing would risk hash collisions between different
# workspaces. We therefore preserve the path as-is on those platforms.
case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*)
		PROJECT_HASH_INPUT="$(printf '%s' "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]')"
		;;
	*)
		PROJECT_HASH_INPUT="$PROJECT_PATH"
		;;
esac
PROJECT_HASH="$(project_hash "$PROJECT_HASH_INPUT")"
PROJECT_NAME="$(printf '%s' "$PROJECT_BASENAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^-//; s/-$//')-$PROJECT_HASH"
CONTAINER_NAME="${AGENT}-${PROJECT_NAME}"
NM_VOLUME="agent-nm-${PROJECT_NAME}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_ARGS=(-p powbox -f "${ROOT_DIR}/compose.shared.yml" -f "${ROOT_DIR}/compose.${AGENT}.yml")

# Ensure shared named volumes exist (compose won't auto-create external volumes).
SHARED_VOLUMES=(agent-gh-config agent-pnpm-store agent-zsh-history)
if [ "$AGENT" = "claude" ]; then
	SHARED_VOLUMES+=(claude-config)
else
	SHARED_VOLUMES+=(codex-config)
fi
for vol in "${SHARED_VOLUMES[@]}"; do
	if ! docker volume inspect "$vol" >/dev/null 2>&1; then
		docker volume create "$vol" >/dev/null
	fi
done

export WORKSPACE_PATH="$PROJECT_PATH"
export PROJECT_NAME

if [ "$AGENT" = "claude" ]; then
	AGENT_HOST_CONFIG_DIR="${CLAUDE_HOST_CONFIG_DIR:-$HOME/.claude}"
else
	AGENT_HOST_CONFIG_DIR="${CODEX_HOST_CONFIG_DIR:-$HOME/.codex}"
fi
GH_HOST_CONFIG_DIR="${GH_HOST_CONFIG_DIR:-$HOME/.config/gh}"
GIT_CONFIG_PATH="${GIT_CONFIG_PATH:-$HOME/.gitconfig}"

CONTAINER_EXISTS=false
CONTAINER_RUNNING=false

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
	CONTAINER_EXISTS=true
	if [ "$(docker container inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
		CONTAINER_RUNNING=true
	fi
fi

if [ "$BUILD" = true ]; then
	"${ROOT_DIR}/scripts/build-image.sh" "$AGENT"
fi

if [ "$RESUME" = true ]; then
	if [ "$CONTAINER_EXISTS" != true ]; then
		echo "No persisted container named ${CONTAINER_NAME} was found. Start it once normally, or with --persist if you want to be explicit." >&2
		exit 1
	fi
	if [ -n "$CTX_PATH" ]; then
		echo "Note: --ctx is ignored with --resume; container will resume with its existing mounts. Omit --resume to apply ctx changes." >&2
	fi
	exec docker start -ai "$CONTAINER_NAME"
fi

if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	# Detect whether the requested /ctx mount differs from the existing container.
	# If it does, remove the stopped container so it gets recreated with the correct mounts.
	# When --ctx is omitted, keep whatever is already mounted (or not) — the user can add
	# --volatile to force a clean slate.
	EXISTING_CTX="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/ctx"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"

	if [ -n "$CTX_PATH" ]; then
		EXISTING_NORM="$(normalize_ctx_path "$EXISTING_CTX")"
		WANT_NORM="$(normalize_ctx_path "$CTX_PATH")"
		if [ "$EXISTING_NORM" != "$WANT_NORM" ]; then
			if [ "$CONTAINER_RUNNING" = true ]; then
				echo "Container ${CONTAINER_NAME} is running with a different /ctx mount. Stop the container first, then relaunch with the new --ctx path." >&2
				exit 1
			fi
			echo "Context mount changed (was '${EXISTING_CTX}', now '${CTX_PATH}'); recreating container."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	elif [ -n "$EXISTING_CTX" ]; then
		echo "Note: container has /ctx mounted from a previous session (${EXISTING_CTX}). Use --volatile to start fresh or --ctx to change it."
	fi
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

if [ "$SHELL_ONLY" = true ]; then
	CMD=(zsh)
elif [ "$AGENT" = "codex" ] && [ -n "$EXEC_TASK" ]; then
	CMD=(codex exec "$EXEC_TASK")
elif [ "$AGENT" = "claude" ]; then
	CMD=(claude --dangerously-skip-permissions)
else
	CMD=(codex --dangerously-bypass-approvals-and-sandbox)
fi

AGENT_SEED_ARGS=()
if [ -d "$AGENT_HOST_CONFIG_DIR" ]; then
	if [ "$AGENT" = "claude" ]; then
		AGENT_SEED_ARGS=(-v "${AGENT_HOST_CONFIG_DIR}:/home/node/.claude-host:ro")
	else
		AGENT_SEED_ARGS=(-v "${AGENT_HOST_CONFIG_DIR}:/home/node/.codex-host:ro")
	fi
fi

GIT_CONFIG_ARGS=()
if [ -f "$GIT_CONFIG_PATH" ]; then
	GIT_CONFIG_ARGS=(-v "${GIT_CONFIG_PATH}:/home/node/.gitconfig-host:ro")
fi

GH_CONFIG_ARGS=()
if [ -d "$GH_HOST_CONFIG_DIR" ]; then
	GH_CONFIG_ARGS=(-v "${GH_HOST_CONFIG_DIR}:/home/node/.config/gh-host:ro")
fi

CTX_ARGS=()
if [ -n "$CTX_PATH" ]; then
	CTX_ARGS=(-v "${CTX_PATH}:/ctx:ro")
fi

WORKSPACE_MOUNT="/workspace/${PROJECT_NAME}"

docker compose "${COMPOSE_ARGS[@]}" run --rm --no-deps --user root --entrypoint /bin/sh \
	-v "${NM_VOLUME}:/mnt/node_modules" \
	agent \
	-lc 'mkdir -p /mnt/node_modules && chown node:node /mnt/node_modules'

RUN_ARGS=()
if [ "$DETACH" = true ]; then
	RUN_ARGS+=(-d)
elif [ "$VOLATILE" = true ] && [ "$PERSIST" != true ]; then
	RUN_ARGS+=(--rm)
fi

EXTRA_ENV=(-e "CONTAINER_NAME=$CONTAINER_NAME")
if [ "$AGENT" = "claude" ]; then
	EXTRA_ENV+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}")
elif [ "$AGENT" = "codex" ]; then
	EXTRA_ENV+=(-e "OPENAI_API_KEY=${OPENAI_API_KEY:-}")
fi

# Mount a per-project named volume over node_modules inside the bind mount.
# This shadows the host's node_modules with a Linux-native volume so that
# native binaries compiled for the container OS are never mixed with host
# binaries. The trade-off is that Docker may create an empty node_modules/
# directory on the host the first time (usually harmless since the project
# already has one), and the host's node_modules is inaccessible inside the
# container (intentional — use the volume copy for all in-container installs).
docker compose "${COMPOSE_ARGS[@]}" run "${RUN_ARGS[@]}" \
	--name "$CONTAINER_NAME" \
	"${EXTRA_ENV[@]}" \
	"${AGENT_SEED_ARGS[@]}" \
	"${GIT_CONFIG_ARGS[@]}" \
	"${GH_CONFIG_ARGS[@]}" \
	"${CTX_ARGS[@]}" \
	-v "${NM_VOLUME}:${WORKSPACE_MOUNT}/node_modules" \
	-w "${WORKSPACE_MOUNT}" \
	agent \
	"${CMD[@]}"
