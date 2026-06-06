#!/usr/bin/env bash
set -euo pipefail

# Refresh the image-baked agent skills onto the persistent config volumes.
#
# Skill text is baked into powbox-agent:latest at build time and seeded onto the
# claude-config / codex-config volumes the first time each skill folder is absent
# (no-clobber, see docker/shared/entrypoint-*-hook.sh). That no-clobber means a
# rebuilt image with updated skills does NOT overwrite the stale copies already
# on the volume. This command closes that gap in one go: it runs a throwaway
# container that copies the freshly built skills over the volume copies, removing
# the old "enter a container, delete skills, exit, relaunch to re-seed" dance.
#
# Rebuild the image first (e.g. `cc <project> --build`, `agent-update`, or
# `build.sh agent`) so the baked skills reflect your latest edits — this command
# seeds from whatever is currently in powbox-agent:latest.
#
# The config volumes are shared by every agent container, so this works whether
# or not any containers are running. A container that is already running picks up
# a refreshed skill the next time that skill is invoked; restart it for certainty.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="powbox-agent:latest"
WORKER="$ROOT_DIR/commands/update-skills-incontainer.sh"

DRY_RUN=false
while [ "$#" -gt 0 ]; do
	case "$1" in
	--dry-run | -n)
		DRY_RUN=true
		;;
	-h | --help)
		echo "Usage: $0 [--dry-run]"
		echo "  Refresh image-baked skills onto the claude-config / codex-config volumes."
		echo "  --dry-run, -n   List the skills that would be refreshed without copying."
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	esac
	shift
done

if ! docker info >/dev/null 2>&1; then
	echo "Docker daemon is not running. Start Docker Desktop (or the Docker daemon) and try again." >&2
	exit 1
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Image '$IMAGE' not found. Build it first (e.g. './build.sh agent' or 'cc <project> --build')." >&2
	exit 1
fi

if [ ! -f "$WORKER" ]; then
	echo "Worker script not found: $WORKER" >&2
	exit 1
fi

# Run the worker inside powbox-agent (the only image that carries the baked seed
# dirs) with both config volumes mounted. --entrypoint bash bypasses the agent
# entrypoint; the worker is bind-mounted read-only and executed by path.
docker run --rm \
	-v "claude-config:/home/node/.claude" \
	-v "codex-config:/home/node/.codex" \
	-v "${WORKER}:/usr/local/bin/update-skills-incontainer.sh:ro" \
	-e "POWBOX_DRY_RUN=${DRY_RUN}" \
	--entrypoint bash \
	"$IMAGE" /usr/local/bin/update-skills-incontainer.sh
