#!/usr/bin/env bash
# Mount tmpfs over directories to shadow host-mounted content, and bind durable
# per-worktree git metadata over .git/worktrees.
#
# Called via sudo from the entrypoint or shadow-refresh.sh.  Each argument
# is an absolute path that must reside under /workspace/.  Paths that
# are already mountpoints are silently skipped (idempotent).
#
# Two mount kinds:
#   * Most targets get a fresh tmpfs (host-native binaries never mix with
#     container-native ones — e.g. nested node_modules).
#   * A target that ends in /.git/worktrees is, when its sibling .worktrees is a
#     PERSISTENT container-local volume, instead BIND-mounted from that volume's
#     .gitworktrees subdir, so linked-worktree administrative metadata shares the
#     working trees' durability and survives a container recycle (task 017).
#     Without a persistent .worktrees volume (the fallback launch) it falls back
#     to tmpfs — still container-local, so the host's own .git/worktrees stays
#     hidden and the container's registrations never leak onto the host.
#
# Security: this script is root-owned, immutable inside the image, and
# listed in /etc/sudoers.d/node — the node user can only invoke it
# through sudo, and it refuses to act on any path outside /workspace/.  Both the
# bind source and destination are validated under /workspace/.  tmpfs and bind
# mounts are container-namespace-scoped and invisible to the host.
set -euo pipefail

NODE_UID="$(id -u node)"
NODE_GID="$(id -g node)"
workspace_root="$(realpath /workspace)"
mounted=0

# Per-mount tmpfs size cap.  Each shadowed directory gets its own tmpfs with
# this ceiling; tmpfs allocates lazily, so the cap bounds the worst case rather
# than reserving memory up front.  When the limit is hit, pnpm install gets a
# clear ENOSPC error rather than silently eating RAM.  The default is sized to
# hold several git worktrees sharing one .worktrees mount (each with its own
# node_modules).  Override via SHADOW_TMPFS_SIZE (any value mount -o size= takes).
TMPFS_SIZE="${SHADOW_TMPFS_SIZE:-2g}"

# bind_git_worktrees <dst>
#   <dst> is a resolved, /workspace-validated path ending in /.git/worktrees whose
#   mountpoint dir already exists.  Bind the co-located persistent worktrees
#   volume's .gitworktrees subdir over it so per-worktree git metadata persists.
#   Returns 0 when it bound the durable metadata; returns 1 (caller falls back to
#   tmpfs) when there is no persistent .worktrees volume to co-locate into.
bind_git_worktrees() {
	local dst="$1"
	local ws="${dst%/.git/worktrees}" # /workspace/<slug>
	local wt="$ws/.worktrees"

	# Only bind when .worktrees is a PERSISTENT container-local mount (the
	# launcher's agent-wt-* volume): a plain unmounted dir or the tmpfs fallback
	# would make the "durable" metadata just as ephemeral as tmpfs, so in those
	# cases the caller's tmpfs path is the honest choice.
	mountpoint -q "$wt" 2>/dev/null || return 1
	case "$(findmnt -nro FSTYPE -T "$wt" 2>/dev/null || true)" in
	tmpfs | '') return 1 ;;
	esac

	local src="$wt/.gitworktrees"
	local rsrc
	rsrc="$(realpath -m -- "$src")" || return 1
	# Defence in depth: the bind SOURCE must also resolve under /workspace/.
	case "$rsrc" in
	"$workspace_root"/*) ;;
	*) return 1 ;;
	esac

	# Durable metadata dir inside the volume, owned by node (git runs as node).
	mkdir -p "$rsrc" || return 1
	chown "$NODE_UID:$NODE_GID" "$rsrc" 2>/dev/null || true

	mount --bind "$rsrc" "$dst" || return 1
	echo "Worktree metadata: bound durable $rsrc -> $dst"
	return 0
}

for target in "$@"; do
	if ! resolved_target="$(realpath -m -- "$target")"; then
		echo "shadow-mounts: refusing to shadow '$target' (unable to resolve path)." >&2
		continue
	fi

	# Validate: must resolve to a path under /workspace/.
	case "$resolved_target" in
	"$workspace_root"/*) ;;
	*)
		echo "shadow-mounts: refusing to shadow '$target' (must resolve under /workspace/)." >&2
		continue
		;;
	esac

	# Skip if already a mountpoint (handles re-runs and shadow-refresh.sh) — this
	# covers both a prior tmpfs shadow and a prior durable .git/worktrees bind.
	if mountpoint -q "$resolved_target" 2>/dev/null; then
		continue
	fi

	# Non-fatal under set -e: a path whose parent is a file (e.g. a literal
	# under a .git that is itself a file in a linked worktree) must not abort
	# the whole loop and leave the remaining directories unshadowed.
	if ! mkdir -p "$resolved_target" 2>/dev/null; then
		echo "shadow-mounts: skipping '$target' (cannot create directory — parent may be a file)." >&2
		continue
	fi

	# .git/worktrees gets a durable bind from the persistent .worktrees volume
	# when one is present; otherwise fall through to the tmpfs path below.
	case "$resolved_target" in
	*/.git/worktrees)
		if bind_git_worktrees "$resolved_target"; then
			mounted=$((mounted + 1))
			continue
		fi
		;;
	esac

	mount -t tmpfs -o "uid=$NODE_UID,gid=$NODE_GID,mode=755,size=$TMPFS_SIZE" tmpfs "$resolved_target"
	mounted=$((mounted + 1))
done

if [ "$mounted" -gt 0 ]; then
	echo "Shadow mounts: $mounted director$([ "$mounted" -eq 1 ] && echo 'y' || echo 'ies') shadowed (tmpfs, plus any durable .git/worktrees bind)."
fi
