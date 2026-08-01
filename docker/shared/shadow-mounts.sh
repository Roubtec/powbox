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

# warn_bind_broken <wt> <dst> <reason>
#   Loud stderr diagnostic for the case where a persistent .worktrees volume was
#   detected but the durable .git/worktrees bind could not be established.  The
#   caller still falls back to tmpfs (a working-but-ephemeral .git/worktrees
#   beats none), but this fallback must never look like the normal "no volume
#   present" launch — an operator has to be able to tell a broken durable bind
#   from a launch mode that never had one.
warn_bind_broken() {
	echo "shadow-mounts: WARNING: persistent .worktrees volume found at '$1' but the durable .git/worktrees bind failed ($3); falling back to EPHEMERAL tmpfs for '$2' — linked-worktree metadata will NOT survive container recreation." >&2
}

# bind_git_worktrees <dst>
#   <dst> is a resolved, /workspace-validated path ending in /.git/worktrees whose
#   mountpoint dir already exists.  Bind the co-located persistent worktrees
#   volume's .gitworktrees subdir over it so per-worktree git metadata persists.
#   Returns 0 when it bound the durable metadata; returns 1 (caller falls back to
#   tmpfs) when there is no persistent .worktrees volume to co-locate into — or,
#   with a LOUD stderr warning, when a persistent volume IS present but the
#   durable bind could not be established, so a broken bind never masquerades as
#   the normal no-volume fallback.
bind_git_worktrees() {
	local dst="$1"
	local ws="${dst%/.git/worktrees}" # /workspace/<slug>
	local wt="$ws/.worktrees"

	# Only bind when .worktrees is a PERSISTENT container-local mount (the
	# launcher's agent-wt-* volume): a plain unmounted dir or the tmpfs fallback
	# would make the "durable" metadata just as ephemeral as tmpfs, so in those
	# cases the caller's tmpfs path is the honest choice.  These two checks are
	# the only SILENT return-1 paths: "no durable volume" is a normal launch
	# mode, not a fault.
	mountpoint -q "$wt" 2>/dev/null || return 1
	case "$(findmnt -nro FSTYPE -T "$wt" 2>/dev/null || true)" in
	tmpfs | '') return 1 ;;
	esac

	# From here on a persistent .worktrees volume IS present, so any failure
	# means the durable metadata bind is BROKEN, not merely absent.  Warn loudly
	# (warn_bind_broken) before the caller falls back to tmpfs: silently
	# degrading would reintroduce the exact persistent-working-trees /
	# ephemeral-metadata mismatch this bind exists to prevent (worktrees that
	# survive a container recycle while their registrations vanish), and make it
	# indistinguishable from a normal no-volume launch.
	local src="$wt/.gitworktrees"
	local rsrc
	rsrc="$(realpath -m -- "$src")" || {
		warn_bind_broken "$wt" "$dst" "cannot resolve bind source '$src'"
		return 1
	}
	# Defence in depth: the bind SOURCE must also resolve under /workspace/.
	case "$rsrc" in
	"$workspace_root"/*) ;;
	*)
		warn_bind_broken "$wt" "$dst" "bind source '$rsrc' resolves outside /workspace/"
		return 1
		;;
	esac

	# Durable metadata dir inside the volume, owned by node (git runs as node).
	mkdir -p "$rsrc" || {
		warn_bind_broken "$wt" "$dst" "cannot create durable metadata dir '$rsrc'"
		return 1
	}
	chown "$NODE_UID:$NODE_GID" "$rsrc" 2>/dev/null || true

	mount --bind "$rsrc" "$dst" || {
		warn_bind_broken "$wt" "$dst" "mount --bind '$rsrc' -> '$dst' failed"
		return 1
	}
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

	# Remember which components mkdir -p is about to create, plus the deepest
	# ancestor that already exists, so the new ones can inherit its ownership
	# (see the chown below).  Computed BEFORE the mkdir, while they are absent.
	new_dirs=()
	deepest_existing="$resolved_target"
	while [ ! -e "$deepest_existing" ] && [ "$deepest_existing" != "/" ]; do
		new_dirs+=("$deepest_existing")
		deepest_existing="$(dirname "$deepest_existing")"
	done

	# Non-fatal under set -e: a path whose parent is a file (e.g. a literal
	# under a .git that is itself a file in a linked worktree) must not abort
	# the whole loop and leave the remaining directories unshadowed.
	if ! mkdir -p "$resolved_target" 2>/dev/null; then
		echo "shadow-mounts: skipping '$target' (cannot create directory — parent may be a file)." >&2
		continue
	fi

	# A mountpoint we had to create is created by ROOT (this helper only ever runs
	# via sudo), so on a native-Linux bind mount it outlives the container as a
	# root-owned mode-755 directory once the tmpfs goes away — and the host user
	# can then neither populate nor remove it (e.g. a subsequent host `dotnet
	# build` writing into bin/obj). Only the tmpfs itself was ever node-owned, and
	# it exists only while the container runs. So hand every component we just
	# created the uid/gid of the deepest ancestor that already existed: for a
	# bind-mounted checkout that is the tree's host owner, and for a container-local
	# volume it is node either way. heal-workspace-perms.sh has already run by this
	# point in entrypoint-core.sh, so a root-owned checkout is node-owned here
	# rather than inheriting root. Pre-existing for .powbox.yml literals; the .NET
	# scan is what makes it automatic and per-project, hence the fix. Must happen
	# BEFORE the mount below, or it would chown the tmpfs root instead of the
	# directory underneath it. Never fatal: a failed chown leaves today's behaviour.
	if [ "${#new_dirs[@]}" -gt 0 ]; then
		if owner="$(stat -c '%u:%g' "$deepest_existing" 2>/dev/null)"; then
			chown -h "$owner" "${new_dirs[@]}" 2>/dev/null ||
				echo "shadow-mounts: warning: could not give '$resolved_target' the host ownership ($owner) of '$deepest_existing'; it may be left root-owned on the host after the container stops." >&2
		else
			echo "shadow-mounts: warning: could not read the ownership of '$deepest_existing'; '$resolved_target' may be left root-owned on the host after the container stops." >&2
		fi
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
