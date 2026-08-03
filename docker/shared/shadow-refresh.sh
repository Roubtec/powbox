#!/usr/bin/env bash
# Re-run workspace shadow detection and mount any new subpackage
# node_modules that appeared since the container started.
#
# Safe to call at any time — already-mounted paths are skipped.
# Useful after adding a new workspace package mid-session.
#
# Usage: shadow-refresh.sh [workspace-dir]
#        Defaults to scanning all directories under /workspace/.
set -euo pipefail

# Mirror entrypoint-core.sh's shadow skip conditions. Startup declines to shadow
# in two modes, and a hand-run must not mount what startup deliberately withheld
# — nothing downstream re-checks, and shadow-mounts.sh guards only "under
# /workspace/ and not depth-1", never emptiness, so a tmpfs would mask real
# content rather than fail. CAP_SYS_ADMIN is granted in both modes
# (compose.shared.yml), so the mount would succeed.
#
# Self-hosted (--isolated): there is no host filesystem to shadow — the whole
# workspace is one container-local volume — and a tmpfs over a subpackage's
# node_modules would break the hardlinking that single-volume layout exists to
# enable. Shadowing .worktrees there would also mask live worktrees.
if [ "${POWBOX_SELF_HOSTED:-}" = "1" ]; then
	echo "shadow-refresh.sh: self-hosted (--isolated) workspace — shadowing is skipped in this mode; nothing to do."
	exit 0
fi

# Image-store WRITER role: that short-lived container mounts the host workspace
# BIND but not the agent-nm-*/agent-wt-* volumes, so node_modules here is the
# host checkout's own tree; shadowing it would churn host-side pnpm state.
if [ "${POWBOX_IMAGE_STORE_ROLE:-}" = "writer" ]; then
	echo "shadow-refresh.sh: image-store writer container — shadowing is skipped in this role; nothing to do."
	exit 0
fi

if [ $# -gt 0 ]; then
	dirs=("$1")
else
	dirs=()
	for d in /workspace/*/; do
		[ -d "$d" ] || continue
		dirs+=("${d%/}")
	done
fi

if [ ${#dirs[@]} -eq 0 ]; then
	echo "No workspace directories found under /workspace/."
	exit 0
fi

all_targets=()
for ws_dir in "${dirs[@]}"; do
	while IFS= read -r target; do
		[ -z "$target" ] && continue
		all_targets+=("$target")
	done < <(detect-shadows.sh "$ws_dir")
done

if [ ${#all_targets[@]} -eq 0 ]; then
	echo "No directories to shadow."
	exit 0
fi

sudo --preserve-env=SHADOW_TMPFS_SIZE /usr/local/bin/shadow-mounts.sh "${all_targets[@]}" || {
	status=$?
	echo "shadow-refresh.sh: failed to mount shadow directories." >&2
	echo "Hint: ensure the container has mount permissions (CAP_SYS_ADMIN in compose.shared.yml)." >&2
	exit "$status"
}
