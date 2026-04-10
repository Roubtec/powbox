#!/usr/bin/env bash
# Mount tmpfs over directories to shadow host-mounted content.
#
# Called via sudo from the entrypoint or shadow-refresh.  Each argument
# is an absolute path that must reside under /workspace/.  Paths that
# are already mountpoints are silently skipped (idempotent).
#
# Security: this script is root-owned, immutable inside the image, and
# listed in /etc/sudoers.d/node — the node user can only invoke it
# through sudo, and it refuses to mount outside /workspace/.  tmpfs
# mounts are container-namespace-scoped and invisible to the host.
set -euo pipefail

NODE_UID=1000
NODE_GID=1000
mounted=0

for target in "$@"; do
	# Validate: must be an absolute path under /workspace/.
	case "$target" in
		/workspace/*)
			;;
		*)
			echo "shadow-mounts: refusing to shadow '$target' (must be under /workspace/)." >&2
			continue
			;;
	esac

	# Skip if already a mountpoint (handles re-runs and shadow-refresh).
	if mountpoint -q "$target" 2>/dev/null; then
		continue
	fi

	mkdir -p "$target"
	mount -t tmpfs -o "uid=$NODE_UID,gid=$NODE_GID,mode=755" tmpfs "$target"
	mounted=$((mounted + 1))
done

if [ "$mounted" -gt 0 ]; then
	echo "Shadow mounts: $mounted director$([ "$mounted" -eq 1 ] && echo 'y' || echo 'ies') shadowed with tmpfs."
fi
