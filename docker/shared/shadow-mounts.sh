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
# bind source and destination are validated under /workspace/, and both are
# then reached by the held-directory walk below, so a path node swaps after
# validation cannot redirect a mkdir, chown or mount.  tmpfs and bind mounts are
# container-namespace-scoped and invisible to the host.
set -euo pipefail

NODE_UID="$(id -u node)"
NODE_GID="$(id -g node)"
workspace_root="$(realpath /workspace)"
mounted=0

# Per-mount tmpfs size cap.  Each shadowed directory gets its own tmpfs with
# this ceiling; tmpfs allocates lazily, so the cap bounds the worst case rather
# than reserving memory up front.  When the limit is hit, pnpm install gets a
# clear ENOSPC error rather than silently eating RAM.  The cap is sized to
# hold several git worktrees sharing one .worktrees mount (each with its own
# node_modules).  Deliberately not read from the environment: sudo resets the
# caller's environment for this grant, and a value that reached the root-run
# `mount -o` string would need validating as a size first (task 081b).
TMPFS_SIZE=2g

# Held-directory walking (task 081a).  Every component below /workspace/<slug>
# is node-writable and node may run this helper at any time, so a path validated
# below can be re-pointed through a swapped-in symlink before it is used.  No
# validated path string is therefore ever handed to mkdir, chown or mount:
# the helper walks down from the root-owned /workspace one component at a time
# with the directory it reached as its cwd, and acts only on that held directory
# ("." — or /proc/self/fd/N for the bind source).  A later swap of the path
# cannot move a directory the process already holds.  Three details carry it:
#   * `cd -P -- ./<name>` is one relative chdir; a plain `cd` makes bash chdir
#     the whole absolute logical path again (and may consult CDPATH).
#   * after each step the kernel's cwd (readlink /proc/self/cwd — never $PWD or
#     the `pwd` builtin, which bash derives from the path string) must equal the
#     parent's physical path plus <name>; anything else means <name> was a
#     symlink or was swapped, and the target is refused.
#   * `mount --no-canonicalize`: by default util-linux rewrites "." back into an
#     absolute path, which the kernel would walk again.
# node can still rename a held directory within the workspace's own mount, so a
# mount or chown follows the directory to its new name — but rename(2) does not
# cross mounts, so it cannot carry either outside /workspace.

# enter_root — hold the workspace root.  Every component of /workspace itself is
# root-owned, so this one absolute chdir is the only one the walk trusts.
enter_root() {
	cd -P -- "$workspace_root" 2>/dev/null || return 1
	held="$workspace_root"
	[ "$(readlink /proc/self/cwd)" = "$held" ]
}

# step_into <name> [create]
#   Hold <name>, a child of the held directory.  With `create`, an absent <name>
#   is made first: a mkdir of one relative name never follows a symlink and never
#   creates anywhere but the held directory.  Sets $created to 1 when this call
#   made it.  Returns 1 when <name> cannot be created or entered (a file, say)
#   and 2 when it is a symlink or was swapped while being entered; after either,
#   the cwd is wherever the failed step left it and must not be acted on.
step_into() {
	created=0
	if [ ! -e "$1" ] && [ ! -L "$1" ]; then
		[ "${2:-}" = create ] || return 1
		mkdir -- "$1" 2>/dev/null || return 1
		created=1
	fi
	if ! cd -P -- "./$1" 2>/dev/null; then
		[ -L "$1" ] && return 2
		return 1
	fi
	[ "$(readlink /proc/self/cwd)" = "$held/$1" ] || return 2
	held="$held/$1"
}

# walk_to <path> — hold an existing <path> under the workspace root, creating
# nothing.  Same return codes as step_into.
walk_to() {
	local -a parts
	local part
	enter_root || return 1
	mapfile -d / -t parts < <(printf '%s' "${1#"$workspace_root"/}")
	for part in "${parts[@]}"; do
		step_into "$part" || return
	done
}

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

# bind_git_worktrees <dst> <dst-fd>
#   <dst> is the resolved, /workspace-validated path ending in /.git/worktrees
#   that the caller holds as fd <dst-fd> (its mountpoint dir already exists).
#   Bind the co-located persistent worktrees volume's .gitworktrees subdir over
#   it so per-worktree git metadata persists.  Returns 0 when it bound the
#   durable metadata; returns 1 (caller falls back to tmpfs) when there is no
#   persistent .worktrees volume to co-locate into — or, with a LOUD stderr
#   warning, when a persistent volume IS present but the durable bind could not
#   be established, so a broken bind never masquerades as the normal no-volume
#   fallback.  Leaves the cwd anywhere: the caller re-enters <dst-fd>.
bind_git_worktrees() {
	local dst="$1" dst_fd="$2" src_fd rc=0
	local wt="${dst%/.git/worktrees}/.worktrees"

	# Only bind when .worktrees is a PERSISTENT container-local mount (the
	# launcher's agent-wt-* volume): a plain unmounted dir or the tmpfs fallback
	# would make the "durable" metadata just as ephemeral as tmpfs, so in those
	# cases the caller's tmpfs path is the honest choice.  These checks are the
	# only SILENT return-1 paths: "no durable volume" is a normal launch mode,
	# not a fault.  The bind source sits inside that node-writable volume, so it
	# is reached by the same held walk as the target.
	walk_to "$wt" || return 1
	mountpoint -q . 2>/dev/null || return 1
	case "$(findmnt -nro FSTYPE -T . 2>/dev/null || true)" in
	tmpfs | '') return 1 ;;
	esac

	# From here on a persistent .worktrees volume IS present, so any failure
	# means the durable metadata bind is BROKEN, not merely absent.  Warn loudly
	# (warn_bind_broken) before the caller falls back to tmpfs: silently
	# degrading would reintroduce the exact persistent-working-trees /
	# ephemeral-metadata mismatch this bind exists to prevent (worktrees that
	# survive a container recycle while their registrations vanish), and make it
	# indistinguishable from a normal no-volume launch.
	step_into .gitworktrees create || rc=$?
	if [ "$rc" -ne 0 ]; then
		warn_bind_broken "$wt" "$dst" "cannot create or enter durable metadata dir '$wt/.gitworktrees' safely"
		return 1
	fi
	# Durable metadata dir inside the volume, owned by node (git runs as node).
	chown "$NODE_UID:$NODE_GID" . 2>/dev/null || true

	exec {src_fd}<.
	if ! cd -P -- "/proc/self/fd/$dst_fd" 2>/dev/null; then
		exec {src_fd}<&-
		warn_bind_broken "$wt" "$dst" "cannot re-enter the held mountpoint '$dst'"
		return 1
	fi
	if ! mount --no-canonicalize --bind "/proc/self/fd/$src_fd" .; then
		exec {src_fd}<&-
		warn_bind_broken "$wt" "$dst" "mount --bind '$wt/.gitworktrees' -> '$dst' failed"
		return 1
	fi
	exec {src_fd}<&-
	echo "Worktree metadata: bound durable $wt/.gitworktrees -> $dst"
	return 0
}

# adopt_owner — give the held directory, which this run just created as root,
# the owner of the deepest directory that already existed ($owner).  A
# mountpoint we had to create is created by ROOT (this helper only ever runs via
# sudo), so on a native-Linux bind mount it outlives the container as a
# root-owned mode-755 directory once the tmpfs goes away — and the host user can
# then neither populate nor remove it (e.g. a subsequent host `dotnet build`
# writing into bin/obj). Only the tmpfs itself was ever node-owned, and it exists
# only while the container runs. For a bind-mounted checkout the deepest
# existing ancestor's owner is the tree's host owner, and for a container-local
# volume it is node either way. heal-workspace-perms.sh has already run by this
# point in entrypoint-core.sh, so a root-owned checkout is node-owned here rather
# than inheriting root. Never fatal: a failed chown leaves today's behaviour.
adopt_owner() {
	if [ -z "$owner" ]; then
		chown_failed=1
		return 0
	fi
	chown "$owner" . 2>/dev/null || chown_failed=1
}

# shadow_one <target> — validate, walk to, and mount one target.  Returns 0 for
# a refused or skipped target so the loop carries on; a failed tmpfs mount still
# aborts the run under set -e.
shadow_one() {
	local target="$1" resolved_target part i last dst_fd rc
	local -a parts
	owner=""
	chown_failed=0

	if ! resolved_target="$(realpath -m -- "$target")"; then
		echo "shadow-mounts: refusing to shadow '$target' (unable to resolve path)." >&2
		return 0
	fi

	# Validate: must resolve to a path under /workspace/.
	case "$resolved_target" in
	"$workspace_root"/*) ;;
	*)
		echo "shadow-mounts: refusing to shadow '$target' (must resolve under /workspace/)." >&2
		return 0
		;;
	esac

	# ... and must be NESTED inside a workspace, never a workspace itself. Every
	# legitimate shadow (a package's node_modules, a project's bin/obj, .worktrees,
	# .git/worktrees) lives below /workspace/<slug>, so a depth-1 target can only
	# be a mistake — and tmpfs over it masks an entire checkout for the session.
	# The producers already refuse to emit one (detect-shadows.sh rejects the
	# workspace root and any path whose newline would split into a truncated
	# ancestor), but this is the privileged end: the invariant should hold no
	# matter who calls, since a caller passes arbitrary argv and the damage is
	# whole-checkout.
	case "${resolved_target#"$workspace_root"/}" in
	*/*) ;;
	*)
		echo "shadow-mounts: refusing to shadow '$target' (resolves to the workspace '$resolved_target' itself, not a directory inside it)." >&2
		return 0
		;;
	esac

	# Walk to the target, creating what is missing.  mapfile -d / keeps a
	# newline inside a component rather than splitting on it.
	if ! enter_root; then
		echo "shadow-mounts: cannot enter the workspace root '$workspace_root'." >&2
		exit 1
	fi
	mapfile -d / -t parts < <(printf '%s' "${resolved_target#"$workspace_root"/}")
	last=$((${#parts[@]} - 1))
	for i in "${!parts[@]}"; do
		part="${parts[$i]}"
		# The held directory at the first absent component is the deepest
		# ancestor that already exists: read its owner before anything is
		# created beneath it.
		if [ -z "$owner" ] && [ "$chown_failed" = 0 ] && [ ! -e "$part" ] && [ ! -L "$part" ]; then
			owner="$(stat -c '%u:%g' . 2>/dev/null)" || {
				owner=""
				chown_failed=1
			}
		fi
		rc=0
		step_into "$part" create || rc=$?
		case "$rc" in
		0) ;;
		2)
			echo "shadow-mounts: refusing to shadow '$target' ('$held/$part' is a symlink or was swapped while being entered)." >&2
			return 0
			;;
		*)
			# Not fatal: a path whose parent is a file (e.g. a literal under a .git
			# that is itself a file in a linked worktree) must not abort the whole
			# loop and leave the remaining directories unshadowed.
			echo "shadow-mounts: skipping '$target' (cannot create directory — parent may be a file)." >&2
			return 0
			;;
		esac
		# A created ancestor of the mountpoint; the mountpoint is chowned below.
		if [ "$created" = 1 ] && [ "$i" -lt "$last" ]; then adopt_owner; fi
	done
	# The mountpoint itself, while it is still the bare directory: chowned BEFORE
	# the mount, or it would re-own the tmpfs root instead.
	if [ "$created" = 1 ]; then adopt_owner; fi

	# One warning per run, not per directory: on a Windows/FUSE bind mount chown
	# is expected to be a no-op or EPERM, and a repo full of never-built projects
	# would otherwise print dozens of identical lines at every container start.
	if [ "$chown_failed" = 1 ] && [ "${chown_warned:-0}" != 1 ]; then
		chown_warned=1
		echo "shadow-mounts: warning: could not give one or more created mountpoint directories the host ownership of their parent tree; on a native-Linux bind mount they may be left root-owned on the host after the container stops." >&2
	fi

	# Skip if already a mountpoint (handles re-runs and shadow-refresh.sh) — this
	# covers both a prior tmpfs shadow and a prior durable .git/worktrees bind.
	if mountpoint -q . 2>/dev/null; then
		return 0
	fi

	# .git/worktrees gets a durable bind from the persistent .worktrees volume
	# when one is present; otherwise fall through to the tmpfs path below.
	case "$resolved_target" in
	*/.git/worktrees)
		exec {dst_fd}<.
		if bind_git_worktrees "$resolved_target" "$dst_fd"; then
			exec {dst_fd}<&-
			mounted=$((mounted + 1))
			return 0
		fi
		# The bind attempt walked elsewhere: return to the held mountpoint
		# through its descriptor, which no path swap can redirect.
		if ! cd -P -- "/proc/self/fd/$dst_fd" 2>/dev/null; then
			exec {dst_fd}<&-
			echo "shadow-mounts: skipping '$target' (lost the held mountpoint directory)." >&2
			return 0
		fi
		exec {dst_fd}<&-
		;;
	esac

	mount --no-canonicalize -t tmpfs -o "uid=$NODE_UID,gid=$NODE_GID,mode=755,size=$TMPFS_SIZE" tmpfs .
	mounted=$((mounted + 1))
}

for target in "$@"; do
	shadow_one "$target"
done

if [ "$mounted" -gt 0 ]; then
	echo "Shadow mounts: $mounted director$([ "$mounted" -eq 1 ] && echo 'y' || echo 'ies') shadowed (tmpfs, plus any durable .git/worktrees bind)."
fi
