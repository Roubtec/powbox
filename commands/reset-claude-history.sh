#!/usr/bin/env bash
set -euo pipefail

# Prune per-project session history from the shared claude-config volume,
# preserving settings.json, credentials, and any other top-level config files.
# Runs a throwaway container to access the volume's contents, since named
# volumes are not directly reachable from the host filesystem.
#
# Prefers powbox-agent-base:latest (guaranteed present whenever claude-config
# has content) so the helper stays offline-friendly and inherits whatever
# base image docker/base/Dockerfile declares. Falls back to node:24-slim if
# the base image has not been built yet.

VOLUME_NAME="claude-config"
FORCE=false
DRY_RUN=false

while [ "$#" -gt 0 ]; do
	case "$1" in
	--force | -f)
		FORCE=true
		;;
	--dry-run | -n)
		DRY_RUN=true
		;;
	-h | --help)
		echo "Usage: $0 [--force] [--dry-run]"
		echo "  --force, -f     Skip confirmation prompt"
		echo "  --dry-run, -n   Show what would be deleted without deleting"
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	esac
	shift
done

if ! docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
	echo "Volume '$VOLUME_NAME' does not exist. Nothing to prune."
	exit 0
fi

# Running containers with the volume mounted would race against the prune.
# Stopped containers are fine — they do not hold the volume open.
RUNNING_CONTAINERS=$(docker ps --filter "volume=$VOLUME_NAME" --format "{{.Names}}")
if [ -n "$RUNNING_CONTAINERS" ]; then
	echo "Refusing to prune: the following running container(s) have '$VOLUME_NAME' mounted. Stop them first." >&2
	echo "$RUNNING_CONTAINERS" >&2
	exit 1
fi

if docker image inspect powbox-agent-base:latest >/dev/null 2>&1; then
	HELPER_IMAGE="powbox-agent-base:latest"
else
	HELPER_IMAGE="node:24-slim"
	echo "powbox-agent-base:latest not found; falling back to $HELPER_IMAGE." >&2
fi

echo "Project histories currently in '$VOLUME_NAME':"
docker run --rm -v "${VOLUME_NAME}:/data" "$HELPER_IMAGE" sh -c '
	if [ -d /data/projects ]; then
		ls -1 /data/projects 2>/dev/null | sed "s/^/  /"
	else
		echo "  (none)"
	fi
	echo
	echo "Other pruneable state:"
	for d in todos shell-snapshots; do
		if [ -d "/data/$d" ]; then
			echo "  $d/"
		fi
	done
'

if [ "$DRY_RUN" = true ]; then
	echo
	echo "--dry-run: no changes made."
	exit 0
fi

if [ "$FORCE" != true ]; then
	echo
	read -r -p "Delete all project histories, todos, and shell snapshots from '$VOLUME_NAME'? Credentials and settings will be preserved. [y/N] " confirm
	case "$confirm" in
	[yY] | [yY][eE][sS]) ;;
	*)
		echo "Aborted."
		exit 0
		;;
	esac
fi

docker run --rm -v "${VOLUME_NAME}:/data" "$HELPER_IMAGE" sh -c 'rm -rf /data/projects /data/todos /data/shell-snapshots'
echo "Done. Credentials and settings preserved."
