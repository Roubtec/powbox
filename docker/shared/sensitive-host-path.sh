#!/usr/bin/env bash
# sensitive-host-path.sh — shared predicate: is a host directory too important to
# recursively chown? SOURCED (not executed) by heal-workspace-perms.sh and
# fix-workspace-perms.sh; it only defines functions and must NOT call `set` or
# `exit` (that would leak into the sourcing shell).
#
# WHY THIS EXISTS — the incident it guards against:
#   `cc`/`cx` (launch-agent.{sh,ps1}) bind-mounts the launch directory as the
#   "project" at /workspace/<slug>. Run accidentally from `~` (e.g. /root on a
#   VPS, or /home/<you>), the WHOLE home tree becomes the mount. The entrypoint's
#   workspace-perms heal then recursively chowns a root-owned mount to node
#   (uid 1000) so the agent can write it — which, for a home directory, re-owns
#   ~/.ssh and its PARENT, breaking OpenSSH's StrictModes ownership chain. sshd
#   then refuses to read ~/.ssh/authorized_keys and locks you out of the host.
#   Recovering needs an out-of-band console. So: never chown a mount whose host
#   source is a system or home directory — only a genuine project checkout.
#
# Defines two functions:
#   powbox_mountinfo_host_src <container_mountpoint> [mountinfo_file]
#       Echo the bind-mount SOURCE (mountinfo field 4 — the directory within the
#       source filesystem that forms the root of the mount) for the mount whose
#       mountpoint (field 5) equals the argument. On a NATIVE-LINUX bind mount
#       this is the real host path (e.g. /root, /home/alice/app) — which is
#       exactly where the heal fires; on Docker Desktop / WSL it may be a
#       translated path, but the heal never runs there (those FUSE mounts honour
#       node's writes, so the write probe passes). This reads the kernel's view,
#       so an unprivileged `node` cannot forge it — which is why the privileged
#       fix-workspace-perms.sh trusts THIS over any caller-provided env. Empty
#       output = no matching mount (treated as "unknown", not sensitive). The
#       optional 2nd arg overrides /proc/self/mountinfo for unit testing.
#
#   powbox_is_sensitive_host_path <host_path> [home_dir]
#       Exit 0 (sensitive → must NOT be chowned) when host_path is the filesystem
#       root, a recognised system/home ROOT directory, a user home one level under
#       /home or /Users, or equal to the optional home_dir (the launcher forwards
#       $HOME, catching a home at a non-standard location). Exit 1 otherwise. Only
#       the BARE system/home dirs are sensitive — a real project NESTED under one
#       (/opt/app, /var/www/html, /home/alice/code/app) falls through and heals
#       normally.

# Echo the bind-mount source path (mountinfo field 4) for a given mountpoint.
powbox_mountinfo_host_src() {
	local target="${1:-}" mi="${2:-/proc/self/mountinfo}"
	[ -n "$target" ] || return 0
	# Fields 1-6 of every mountinfo line are positional (the optional fields and
	# the fs type come after the " - " separator), so $4=root and $5=mountpoint are
	# always safe to read this way. -print first match only. The `|| true` keeps the
	# function exit status 0 even if awk cannot read $mi, so a caller's `x="$(...)"`
	# assignment never trips `set -e` (an unreadable source just yields empty output).
	awk -v t="$target" '$5 == t { print $4; exit }' "$mi" 2>/dev/null || true
}

# Classify a host path as sensitive (exit 0) or a genuine project mount (exit 1).
powbox_is_sensitive_host_path() {
	local p="${1:-}" home="${2:-}"
	[ -n "$p" ] || return 1

	# The filesystem root, handled before the trailing-slash strip (which would
	# empty it).
	[ "$p" = "/" ] && return 0
	# Normalise a single trailing slash so /home/alice and /home/alice/ match alike.
	p="${p%/}"
	[ -n "$p" ] || return 0

	# A caller-supplied home directory (the launcher forwards $HOME) catches a home
	# at a non-standard location, e.g. /var/services/homes/bob.
	if [ -n "$home" ]; then
		home="${home%/}"
		[ -n "$home" ] && [ "$p" = "$home" ] && return 0
	fi

	# Exact system/home ROOT directories that must never be recursively re-owned.
	# Only the BARE directory is listed; a project nested under one (/opt/app,
	# /srv/www, /var/www/html, /mnt/data/repo) is NOT matched and heals normally.
	case "$p" in
	/root | /home | /Users | \
		/bin | /sbin | /lib | /lib32 | /lib64 | /libx32 | \
		/etc | /usr | /var | /opt | /srv | /boot | \
		/dev | /proc | /sys | /run | /mnt | /media | /tmp | /lost+found)
		return 0
		;;
	esac

	# A user's home directory: exactly ONE component below /home or /Users
	# (/home/alice, /Users/bob). A deeper path (/home/alice/code/app) is a real
	# project checkout and must fall through to "not sensitive".
	case "$p" in
	/home/*/* | /Users/*/*) : ;; # nested deeper than a home dir → not sensitive here
	/home/?* | /Users/?*) return 0 ;;
	esac

	return 1
}
