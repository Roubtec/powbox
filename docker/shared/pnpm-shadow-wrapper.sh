#!/usr/bin/env bash
# pnpm wrapper — shadow workspace node_modules *before* pnpm can populate them.
#
# Why this exists
# ---------------
# In dir-mounted mode the root node_modules is a named volume and every
# workspace-package node_modules is a tmpfs shadow, so the container's installs
# never land on the host bind mount (Windows / macOS).  Those shadows are
# established at container start by shadow-mounts.sh, which only knows about the
# packages that exist *then*.  A package scaffolded mid-session (mkdir a new
# packages/foo, write its package.json, run `pnpm install`) is not shadowed yet,
# so its node_modules would be created and populated straight onto the host bind
# mount — mixing Linux-native binaries and container ownership into the host tree
# and breaking the host's own `pnpm install` with EACCES.  shadow-refresh.sh
# fixes this, but only if it runs *before* pnpm writes into the new directory,
# and scaffolding-then-installing leaves no natural gap to run it.
#
# This wrapper closes that race: before delegating to the real pnpm for any
# command that can create or populate node_modules, it re-runs shadow detection
# so a freshly added package's node_modules is tmpfs-shadowed first.  Detection
# is idempotent — already-mounted paths are skipped — so the steady-state cost is
# one cheap scan.
#
# Installed as /usr/local/bin/{pnpm,pn} (replacing the global-npm symlinks) so it
# transparently covers both the agents' non-interactive Bash and a human shell
# without depending on a shell rc file.  It *always* exec's the real pnpm, so a
# shadow-refresh failure (no mount capability, self-hosted mode, etc.) can never
# block the actual command.
set -uo pipefail

# npm always unpacks a global package at lib/node_modules/<name>, so this entry
# point is stable across pnpm versions.
REAL_PNPM="/usr/local/lib/node_modules/pnpm/bin/pnpm.mjs"

refresh_shadows() {
	# Self-hosted (--isolated) mode has no host filesystem underneath to shadow,
	# and shadow-mounts.sh is skipped there entirely; mirror that here.
	[ "${POWBOX_SELF_HOSTED:-}" = "1" ] && return 0
	# Only meaningful inside a /workspace project.
	case "$PWD" in
		/workspace/?*) ;;
		*) return 0 ;;
	esac
	command -v shadow-refresh.sh >/dev/null 2>&1 || return 0

	# Scope the scan to this project: resolve the direct child of /workspace that
	# contains $PWD by walking up until the parent is /workspace.
	local ws="$PWD"
	while [ "$(dirname "$ws")" != "/workspace" ]; do
		ws="$(dirname "$ws")"
		[ "$ws" = "/" ] && return 0
	done

	# Best-effort: a shadow failure must never block the real pnpm command.
	shadow-refresh.sh "$ws" >/dev/null 2>&1 || true
}

# Only refresh for subcommands that can create or populate node_modules.  pnpm
# accepts global flags before the subcommand (`pnpm -w add`, `pnpm --filter x i`,
# `pnpm -C dir install`), so scan every argument for an install-class token
# rather than only the first.  A false positive triggers a harmless idempotent
# refresh; a false negative would defeat the purpose, so the list errs toward
# catching everything that writes node_modules.
for arg in "$@"; do
	case "$arg" in
		install | i | add | update | up | upgrade | dedupe | import | rebuild | rb | fetch | link | ln)
			refresh_shadows
			break
			;;
	esac
done

if [ ! -x "$REAL_PNPM" ]; then
	echo "pnpm-shadow-wrapper: real pnpm not found at $REAL_PNPM" >&2
	exit 127
fi
exec "$REAL_PNPM" "$@"
