#!/usr/bin/env bash
# Bind-mount a tmpfs-backed copy of an agent config file over the volume
# original, so per-container TUI edits (e.g. /model, /effort) do not leak
# into other containers sharing the same Claude/Codex config volume.
#
# Called via sudo from entrypoint-{claude,codex}-hook.sh.  Each invocation
# takes a (src, dst) pair; dst must be one of the small allowlist of known
# agent config files below.  Already-mounted paths are silently skipped.
#
# Security: root-owned, immutable inside the image, listed in
# /etc/sudoers.d/node.  The node user can only invoke it through sudo, and
# it refuses to shadow anything outside the allowlist or to source from
# anywhere but the /dev/shm/agent-shadow tmpfs.  Bind mounts are
# container-namespace-scoped and invisible to the host — not an escape
# vector.
#
# Caveat: bind-mounting a file makes rename(2) over it return EBUSY, so
# this approach assumes the agent CLI persists settings via in-place
# writeFileSync rather than write-temp-then-rename.  Disable by unsetting
# AGENT_SETTINGS_EPHEMERAL if a future agent version breaks that
# assumption.
set -euo pipefail

if [ "$#" -ne 2 ]; then
	echo "Usage: $0 <src-tmpfs-file> <dst-config-file>" >&2
	exit 2
fi

src="$1"
dst="$2"

case "$dst" in
	/home/node/.claude/settings.json|/home/node/.codex/config.toml)
		;;
	*)
		echo "shadow-agent-config: refusing dst '$dst' (not in allowlist)." >&2
		exit 1
		;;
esac

case "$src" in
	/dev/shm/agent-shadow/*)
		;;
	*)
		echo "shadow-agent-config: refusing src '$src' (must live under /dev/shm/agent-shadow/)." >&2
		exit 1
		;;
esac

if [ ! -f "$src" ]; then
	echo "shadow-agent-config: src '$src' missing." >&2
	exit 1
fi

if [ ! -f "$dst" ]; then
	echo "shadow-agent-config: dst '$dst' missing." >&2
	exit 1
fi

# Idempotent: re-running on an already-shadowed path is a no-op.
if mountpoint -q "$dst" 2>/dev/null; then
	exit 0
fi

mount --bind "$src" "$dst"
