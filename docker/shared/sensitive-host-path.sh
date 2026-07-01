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
# Defines these functions:
#   powbox_mountinfo_host_src <container_mountpoint> [mountinfo_file]
#       Echo the bind-mount SOURCE (mountinfo field 4 — the directory within the
#       source filesystem that forms the root of the mount) for the mount whose
#       mountpoint (field 5) equals the argument. On a NATIVE-LINUX bind mount whose
#       source shares the root filesystem this is the real host path (e.g. /root,
#       /home/alice/app) — which is exactly where the heal fires; but field 4 is only
#       the mount's root WITHIN its source filesystem, so on a SEPARATE-mount layout it
#       is NOT the absolute host path (a /home/alice bind on a dedicated /home reads
#       back as /alice; a whole-filesystem mount reads back as /). Because of that gap the
#       consumers no longer classify on THIS value directly: they call
#       powbox_resolve_host_src (below), which prefers the launcher's TRUE absolute source
#       (recorded per mountpoint in the startup marker map) and falls back to THIS mountinfo
#       value only when no launcher signal was recorded (task 009). On Docker Desktop / WSL
#       it may be a translated path, but the heal never runs there (those FUSE mounts
#       honour node's writes, so the write probe passes). This reads the kernel's view, so an
#       unprivileged `node` cannot forge it — which is why it remains a trustworthy FALLBACK
#       for the privileged fix-workspace-perms.sh (whose marker input is itself written by the
#       un-sudo'd trusted startup, not a caller env). Empty output = no matching mount (treated
#       as "unknown", not sensitive). The optional 2nd arg overrides /proc/self/mountinfo for
#       unit testing.
#
#   powbox_is_sensitive_host_path <host_path> [home_dir]
#       Exit 0 (sensitive → must NOT be chowned) when host_path is the filesystem
#       root, a recognised system/home ROOT directory, a user home one level under
#       /home or /Users, an SSH config directory (any path ending in /.ssh), or equal
#       to the optional home_dir (the launcher forwards $HOME, catching a home at a
#       non-standard location). Exit 1 otherwise. Apart from the .ssh case, only the
#       BARE system/home dirs are sensitive — a real project NESTED under one
#       (/opt/app, /var/www/html, /home/alice/code/app) falls through and heals
#       normally.
#
# The remaining functions implement the task-009 marker map: a small, per-boot,
# node-writable file (/run/powbox/workspace-sources) mapping each container mountpoint
# (/workspace/<slug>) to the launcher's TRUE absolute host bind-mount source. It exists
# because mountinfo field 4 (above) is only the mount root within its source filesystem,
# so on a separate-mount layout it under-/over-detects sensitivity; the launcher knows the
# real absolute path (pwd -P) and records it here at startup. Both the heal and the
# privileged helper classify on the recorded true source, using mountinfo only as a
# fallback. The map is NOT root-owned or write-once: the threat model is accidental user
# oversight, not an adversarial `node` (the container is the trust boundary; `node` can
# already sudo the helper on any /workspace path), so a plain node-writable per-boot file
# is sufficient — see tasks/009 "Threat model".
#
#   powbox_marker_host_src <container_mountpoint> [map_file]
#       Echo the TRUE host source recorded for a mountpoint in the marker map, or empty
#       when there is no entry / the map is missing or unreadable (best-effort, never
#       errors). The optional 2nd arg overrides the map path for unit testing.
#
#   powbox_resolve_host_src <container_mountpoint>
#       Echo a mountpoint's resolved true host source, most-authoritative first: (1) the
#       marker map; (2) the launcher env POWBOX_WORKSPACE_HOST_PATH, but ONLY for the mount
#       it names via POWBOX_WORKSPACE_DIR (a fallback if the marker could not be written —
#       and inert under sudo's env_reset, so the privileged helper relies on the marker +
#       mountinfo); (3) powbox_mountinfo_host_src as the env-independent last resort. Both
#       heal-workspace-perms.sh and fix-workspace-perms.sh feed the result to
#       powbox_is_sensitive_host_path. Empty only when none can be determined (callers fail
#       closed / treat as unknown).
#
#   powbox_record_workspace_source <container_mountpoint> <host_source> [map_file]
#       Record (replacing any prior content) the single mountpoint→true-source mapping in
#       the marker map, creating its directory if needed. Called at trusted startup (the
#       entrypoint, as node) and by the dir-mount smoke. Best-effort: a marker it cannot
#       write just falls the consumers back to mountinfo, so it never errors.

# Echo the bind-mount source path (mountinfo field 4) for a given mountpoint.
powbox_mountinfo_host_src() {
	local target="${1:-}" mi="${2:-/proc/self/mountinfo}"
	[ -n "$target" ] || return 0
	# Fields 1-6 of every mountinfo line are positional (the optional fields and
	# the fs type come after the " - " separator), so $4=root and $5=mountpoint are
	# always safe to read this way. The kernel OCTAL-ESCAPES space (\040), tab (\011),
	# newline (\012) and backslash (\134) inside both fields, so a source like
	# "/home/has space" appears as "/home/has\040space" — decode field 4 back to the
	# real host path before returning. Otherwise a sensitive home or system dir whose
	# name contains one of those bytes slips past powbox_is_sensitive_host_path's exact
	# comparisons (and the privileged fix-workspace-perms.sh backstop, which trusts
	# ONLY this value), and the user-facing skip/refuse warnings print the escaped
	# gibberish. The match side ($5 == t) needs no decode: the /workspace/<slug>
	# mountpoints we look up are sanitized and never contain those characters. The
	# decoder walks left-to-right and consumes each "\NNN" as ONE escape, so an escaped
	# backslash (\134) is not re-interpreted together with the digits that follow it.
	# First match only (exit). The `|| true` keeps the function exit status 0 even if
	# awk cannot read $mi, so a caller's `x="$(...)"` assignment never trips `set -e`
	# (an unreadable source just yields empty output).
	awk -v t="$target" '
		$5 == t {
			s = $4; out = ""; n = length(s)
			for (i = 1; i <= n; i++) {
				c = substr(s, i, 1)
				if (c == "\\" && i + 3 <= n && substr(s, i + 1, 3) ~ /^[0-7][0-7][0-7]$/) {
					o = substr(s, i + 1, 3)
					out = out sprintf("%c", (substr(o, 1, 1) + 0) * 64 + (substr(o, 2, 1) + 0) * 8 + (substr(o, 3, 1) + 0))
					i += 3
				} else {
					out = out c
				}
			}
			print out
			exit
		}' "$mi" 2>/dev/null || true
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

	# An SSH config directory as the mount ROOT (/root/.ssh, /home/alice/.ssh, and — on a
	# separate-/home layout where the bind reads field 4 back shallow — /alice/.ssh). Chowning
	# just ~/.ssh and its authorized_keys to node is enough to trip sshd's StrictModes and lock
	# the user out, even when the home directory itself stays root-owned — so an accidental
	# `cc`/`cx` launched from inside ~/.ssh must be refused too. Matching the trailing `.ssh`
	# component (not an absolute prefix) catches it on every mount layout; a genuine project is
	# never launched from inside a .ssh directory. Checked BEFORE the /home/*/* fall-through
	# below, which would otherwise wave /home/alice/.ssh through as a "nested project".
	case "$p" in
	*/.ssh) return 0 ;;
	esac

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

# Echo the TRUE host source recorded for a container mountpoint in the marker map.
powbox_marker_host_src() {
	# Default the map to the fixed per-boot path. It is NOT env-overridable in
	# production on purpose: fix-workspace-perms.sh reads it under sudo, whose
	# env_reset would strip any override, so an override would silently apply to the
	# node-side heal but not the root-side helper. The optional 2nd arg is for unit
	# tests only (a synthetic map), mirroring powbox_mountinfo_host_src's testability.
	local target="${1:-}" map="${2:-/run/powbox/workspace-sources}"
	[ -n "$target" ] || return 0
	[ -r "$map" ] || return 0
	# Format is one "<mountpoint>\t<source>" line per mount. Split on the FIRST tab:
	# the mountpoint key (/workspace/<slug>) is sanitized and never contains a tab, so
	# everything after it is the source — verbatim, so spaces and backslashes in a host
	# path survive (a value tab would be preserved too; a newline in a path would land on
	# its own record and simply never match a key, falling the caller back to mountinfo).
	# index/substr avoid depending on awk's -F escape handling (mawk vs gawk); the "\t"
	# string literal is standard awk. First match only (exit). `|| true` keeps exit 0 even
	# if awk cannot read the map, so a caller's `x="$(...)"` never trips `set -e`.
	awk -v t="$target" '
		{
			p = index($0, "\t")
			if (p > 0 && substr($0, 1, p - 1) == t) {
				print substr($0, p + 1)
				exit
			}
		}' "$map" 2>/dev/null || true
}

# Echo a mountpoint's resolved true host source (marker → launcher env → mountinfo).
powbox_resolve_host_src() {
	local target="${1:-}"
	[ -n "$target" ] || return 0
	local src
	# (1) The recorded true source is authoritative — a safe true source is never
	# overridden by a degenerate mountinfo value (that is the Gap B fix), and a sensitive
	# true source is caught even where mountinfo under-detects it (that is the Gap A fix).
	src="$(powbox_marker_host_src "$target")"
	# (2) Fallback to the launcher env directly, but ONLY for the mount it names — a safety
	# net if the marker could not be written. POWBOX_WORKSPACE_HOST_PATH is a SINGLE value,
	# so it is only trustworthy for the one mount POWBOX_WORKSPACE_DIR identifies; the heal
	# loops over every /workspace/* and must not misattribute it to another mount. Under
	# sudo's env_reset both vars are empty, so this branch is inert for the privileged
	# helper (which then relies on the marker + mountinfo below).
	if [ -z "$src" ] &&
		[ -n "${POWBOX_WORKSPACE_DIR:-}" ] && [ "${POWBOX_WORKSPACE_DIR}" = "$target" ] &&
		[ -n "${POWBOX_WORKSPACE_HOST_PATH:-}" ]; then
		src="$POWBOX_WORKSPACE_HOST_PATH"
	fi
	# (3) Env-independent last resort: the mountinfo source (the true path on a same-fs
	# native-Linux bind; a shallow / degenerate value on a separate-mount layout).
	[ -n "$src" ] || src="$(powbox_mountinfo_host_src "$target")"
	printf '%s' "$src"
}

# Record a mountpoint→true-source mapping in the marker map (best-effort, never errors).
powbox_record_workspace_source() {
	local mountpoint="${1:-}" source="${2:-}" map="${3:-/run/powbox/workspace-sources}"
	[ -n "$mountpoint" ] && [ -n "$source" ] || return 0
	local dir
	dir="$(dirname "$map")"
	# /run/powbox is created node-owned at image build; mkdir -p is a no-op there and a
	# silent best-effort elsewhere. Replace (not append) the file: exactly one project
	# workspace is mounted per launch, so the map holds a single line, and a fresh write
	# each boot avoids accumulating stale entries in a restarted persistent container.
	mkdir -p "$dir" 2>/dev/null || return 0
	printf '%s\t%s\n' "$mountpoint" "$source" >"$map" 2>/dev/null || return 0
	return 0
}
