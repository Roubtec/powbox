#!/usr/bin/env bash
set -euo pipefail

AGENT="${1:?usage: launch-agent.sh <claude|codex> [project-path] [--build] [--detach] [--shell] [--volatile] [--persist] [--resume] [--continue] [--exec <task> (codex only)]}"
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
CONTINUE=false
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
	--continue)
		CONTINUE=true
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
# Per-project worktrees volume. Holds the git worktrees AND the pnpm store under
# ONE mount so pnpm hardlinks package files into per-worktree node_modules
# instead of copying them. ext4, persistent, container-local, and shared between
# this project's Claude and Codex containers (project-keyed, like NM_VOLUME).
WT_VOLUME="agent-wt-${PROJECT_NAME}"
WORKSPACE_MOUNT="/workspace/${PROJECT_NAME}"
# pnpm store path inside the worktrees volume (same mount as .worktrees/<task>).
WT_STORE_DIR="${WORKSPACE_MOUNT}/.worktrees/.pnpm-store"
# Per-container rootless Podman storage (images + named volumes) so an in-sandbox
# agent's containers and their data persist across restarts. Keyed by the OUTER
# container (agent + project), NOT just the project: a project's Claude and Codex
# containers can run concurrently, and two Podman instances with separate
# runroots/namespaces sharing one graphroot corrupt each other's metadata and
# lifecycle state. A shared image cache is a separate concern (additionalimagestores).
PODMAN_VOLUME="agent-podman-${CONTAINER_NAME}"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_ARGS=(-p powbox -f "${ROOT_DIR}/compose.shared.yml" -f "${ROOT_DIR}/compose.agent.yml")

# Ensure named volumes exist (compose won't auto-create external volumes). Both
# config volumes are always created/mounted so the non-primary agent can be
# spun up in-container with its own persistent login and skills.
SHARED_VOLUMES=(agent-gh-config agent-zsh-history claude-config codex-config)
for vol in "${SHARED_VOLUMES[@]}"; do
	if ! docker volume inspect "$vol" >/dev/null 2>&1; then
		docker volume create "$vol" >/dev/null
	fi
done

export WORKSPACE_PATH="$PROJECT_PATH"
export PROJECT_NAME

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
	"${ROOT_DIR}/scripts/build-image.sh" agent
fi

if [ "$RESUME" = true ]; then
	if [ "$CONTAINER_EXISTS" != true ]; then
		echo "No persisted container named ${CONTAINER_NAME} was found. Start it once normally, or with --persist if you want to be explicit." >&2
		exit 1
	fi
	if [ -n "$CTX_PATH" ]; then
		echo "Note: --ctx is ignored with --resume; container will resume with its existing mounts. Omit --resume to apply ctx changes." >&2
	fi
	if [ "$CONTINUE" = true ]; then
		echo "Note: --continue is ignored with --resume; container will restart with the CMD it was originally created with. Omit --resume to apply a continue-flag change." >&2
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

# Detect whether the --continue flag state differs from what the container was created with.
# The CMD is frozen at container creation, so a flag change only takes effect after recreation.
# Missing label on an existing container predates this flag — treat it as "true" so the old
# auto-resume default remains in effect for reused containers until the user explicitly opts out,
# at which point this branch recycles the container to honour the new intent.
if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	EXISTING_CONTINUE="$(docker inspect --format '{{with .Config.Labels}}{{with index . "powbox.continue"}}{{.}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
	if [ -z "$EXISTING_CONTINUE" ]; then
		EXISTING_CONTINUE="true"
	fi
	WANT_CONTINUE="false"
	if [ "$CONTINUE" = true ]; then
		WANT_CONTINUE="true"
	fi
	if [ "$EXISTING_CONTINUE" != "$WANT_CONTINUE" ]; then
		if [ "$CONTAINER_RUNNING" = true ]; then
			echo "Note: container ${CONTAINER_NAME} is running; --continue=${WANT_CONTINUE} is ignored because the existing process was started with --continue=${EXISTING_CONTINUE}. Attaching to the running process. Stop it and relaunch to apply the flag change." >&2
		else
			echo "Continue flag changed (was '${EXISTING_CONTINUE}', now '${WANT_CONTINUE}'); recreating container."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	fi
fi

# Detect whether the existing container predates the per-project .worktrees volume
# (and its co-located pnpm store). Such a container was created before this change,
# so it still has a tmpfs .worktrees shadow and points pnpm at the old shared store —
# it never gets the hardlinking store-dir, even after the image is rebuilt. Recreate a
# stopped container that lacks the agent-wt-* mount so the new mount + PNPM_STORE_DIR
# take effect; warn (don't disrupt) if it is currently running.
if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	HAS_WT_MOUNT="$(docker inspect --format "{{range .Mounts}}{{if eq .Destination \"${WORKSPACE_MOUNT}/.worktrees\"}}yes{{end}}{{end}}" "$CONTAINER_NAME" 2>/dev/null || true)"
	if [ -z "$HAS_WT_MOUNT" ]; then
		if [ "$CONTAINER_RUNNING" = true ]; then
			echo "Note: container ${CONTAINER_NAME} predates the per-project .worktrees volume; it is still using a tmpfs .worktrees and the old pnpm store, so worktree installs won't hardlink. Stop it and relaunch (or use --volatile) to enable hardlinked worktree node_modules." >&2
		else
			echo "Container ${CONTAINER_NAME} predates the per-project .worktrees volume; recreating it so worktree node_modules hardlink from the co-located pnpm store."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	fi
fi

# Detect whether the existing container predates the per-container Podman storage
# volume. Such a container was created before rootless-Podman support, so its
# /home/node/.local/share/containers is ephemeral (no agent-podman-* mount) and
# it was launched without /dev/fuse — pulled images and podman volumes would not
# persist, even after the image is rebuilt. Recreate a stopped container that
# lacks the mount so the new volume + device attach; warn (don't disrupt) if it
# is currently running.
if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	HAS_PODMAN_MOUNT="$(docker inspect --format "{{range .Mounts}}{{if eq .Destination \"/home/node/.local/share/containers\"}}yes{{end}}{{end}}" "$CONTAINER_NAME" 2>/dev/null || true)"
	if [ -z "$HAS_PODMAN_MOUNT" ]; then
		if [ "$CONTAINER_RUNNING" = true ]; then
			echo "Note: container ${CONTAINER_NAME} predates the per-container Podman storage volume; nested-container images and volumes won't persist and /dev/fuse isn't attached. Stop it and relaunch (or use --volatile) to enable persistent rootless Podman storage." >&2
		else
			echo "Container ${CONTAINER_NAME} predates the per-container Podman storage volume; recreating it so rootless Podman images and volumes persist."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
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
	if [ "$CONTINUE" = true ]; then
		echo "Note: --continue has no effect with --shell; this launch opens a plain zsh." >&2
	fi
elif [ "$AGENT" = "codex" ] && [ -n "$EXEC_TASK" ]; then
	CMD=(codex exec "$EXEC_TASK")
	if [ "$CONTINUE" = true ]; then
		echo "Note: --continue has no effect with --exec; codex exec always starts a fresh non-interactive session." >&2
	fi
elif [ "$AGENT" = "claude" ]; then
	if [ "$CONTINUE" = true ]; then
		# Pre-flight check: only pass --continue if a session history exists for this
		# working directory. Claude stores sessions in ~/.claude/projects/<slug>/,
		# where <slug> is the cwd with every non-alphanumeric, non-dash character
		# replaced by '-' (verified empirically against '/', '.', '_', spaces, '+',
		# and uppercase; case is preserved and adjacent dashes are not collapsed).
		# Passing --continue when no session exists makes claude print "No
		# conversation found" and exit instead of falling back to a fresh session.
		# The check runs inside the container where claude-config is mounted.
		CMD=(sh -c 'slug=$(printf %s "$PWD" | sed "s/[^a-zA-Z0-9-]/-/g"); if ls "$HOME/.claude/projects/$slug"/*.jsonl >/dev/null 2>&1; then exec claude --dangerously-skip-permissions --continue; else exec claude --dangerously-skip-permissions; fi')
	else
		CMD=(claude --dangerously-skip-permissions)
	fi
else
	if [ "$CONTINUE" = true ]; then
		# Codex resume --last already filters to the current cwd and falls through to
		# a fresh interactive session when nothing resumable exists there.
		CMD=(codex resume --last --dangerously-bypass-approvals-and-sandbox)
	else
		CMD=(codex --dangerously-bypass-approvals-and-sandbox)
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

docker compose "${COMPOSE_ARGS[@]}" run --rm --no-deps --user root --entrypoint /bin/sh \
	-v "${NM_VOLUME}:/mnt/node_modules" \
	-v "${WT_VOLUME}:/mnt/worktrees" \
	-v "${PODMAN_VOLUME}:/mnt/containers" \
	agent \
	-lc 'mkdir -p /mnt/node_modules /mnt/worktrees /mnt/containers && chown node:node /mnt/node_modules /mnt/worktrees /mnt/containers'

RUN_ARGS=()
if [ "$DETACH" = true ]; then
	RUN_ARGS+=(-d)
elif [ "$VOLATILE" = true ] && [ "$PERSIST" != true ]; then
	RUN_ARGS+=(--rm)
fi

# Pass /dev/fuse through for rootless Podman's fuse-overlayfs storage driver.
# Auto-detect from the host; POWBOX_FUSE=on|off overrides. In `auto` (and `off`)
# this is best-effort: a missing device just drops the container to the slower vfs
# driver (see entrypoint-core.sh), never aborting the launch. `on` forces the
# device, so if the Docker host cannot expose /dev/fuse the run hard-fails — that
# is intentional for callers who explicitly demand the overlay driver.
case "${POWBOX_FUSE:-auto}" in
on)
	RUN_ARGS+=(--device /dev/fuse)
	;;
off) ;;
*)
	if [ -e /dev/fuse ]; then
		RUN_ARGS+=(--device /dev/fuse)
	fi
	;;
esac

# PRIMARY_AGENT selects which agent the unified image runs and seeds as primary.
# Both API keys flow through via compose.agent.yml so a delegated peer agent can
# authenticate too.
EXTRA_ENV=(-e "CONTAINER_NAME=$CONTAINER_NAME" -e "PRIMARY_AGENT=$AGENT" -e "PNPM_STORE_DIR=$WT_STORE_DIR")

# Mount per-project named volumes over node_modules and .worktrees inside the
# bind mount. Both shadow the host paths with Linux-native ext4 volumes so that
# native binaries compiled for the container OS are never mixed with host
# binaries. The .worktrees volume additionally co-locates the pnpm store
# (PNPM_STORE_DIR) with each worktree's node_modules under one mount, so
# per-worktree `pnpm install` hardlinks from the store instead of copying.
# The trade-off is that Docker may create empty node_modules/ and .worktrees/
# directories on the host the first time (harmless; .worktrees is gitignored in
# worktree-enabled repos), and the host's copies are inaccessible inside the
# container (intentional — use the volume copies for all in-container installs).
CONTINUE_LABEL="false"
if [ "$CONTINUE" = true ]; then
	CONTINUE_LABEL="true"
fi

docker compose "${COMPOSE_ARGS[@]}" run "${RUN_ARGS[@]}" \
	--name "$CONTAINER_NAME" \
	--label "powbox.continue=${CONTINUE_LABEL}" \
	"${EXTRA_ENV[@]}" \
	"${GIT_CONFIG_ARGS[@]}" \
	"${GH_CONFIG_ARGS[@]}" \
	"${CTX_ARGS[@]}" \
	-v "${NM_VOLUME}:${WORKSPACE_MOUNT}/node_modules" \
	-v "${WT_VOLUME}:${WORKSPACE_MOUNT}/.worktrees" \
	-v "${PODMAN_VOLUME}:/home/node/.local/share/containers" \
	-w "${WORKSPACE_MOUNT}" \
	agent \
	"${CMD[@]}"
