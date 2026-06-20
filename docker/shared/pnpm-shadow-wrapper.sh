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

# npm always unpacks a global package at lib/node_modules/<name>, so this directory
# is stable across pnpm versions. pnpm's package `bin` entry is the executable ESM
# launcher bin/pnpm.mjs (verified for the installed pnpm); some builds also ship a
# non-executable bin/pnpm.cjs shim that re-imports it for older Corepack. The exec
# block at the end prefers .mjs and falls back to .cjs so the wrapper degrades
# gracefully rather than failing every call if that layout ever shifts.
PNPM_BINDIR="/usr/local/lib/node_modules/pnpm/bin"

# pnpm subcommand classification, factored so the refresh trigger (the loop at the
# bottom of this file) and the root-node_modules warning inside refresh_shadows share
# ONE token list and can never drift apart.
#
# install-class = any subcommand worth a pre-emptive shadow refresh, because it either
# writes the project's node_modules or warms the pnpm store for a package that may
# have just been scaffolded. pnpm accepts global flags before the subcommand
# (`pnpm -w add`, `pnpm -C dir install`), so every caller scans all args.
is_install_class_subcommand() {
	case "$1" in
		install | i | install-test | it | add | update | up | upgrade | dedupe | import | rebuild | rb | fetch | link | ln) return 0 ;;
		*) return 1 ;;
	esac
}

# store-only = the install-class subset that warms the pnpm store from the lockfile
# but never writes the project's node_modules, so it must NOT raise the root-
# node_modules warning below. `pnpm fetch` ignores the package manifest and only
# populates the virtual store, so a non-dev-folder `pnpm fetch` does not litter the
# host bind mount the way an install would — warning about it would be misleading.
is_store_only_subcommand() {
	case "$1" in
		fetch) return 0 ;;
		*) return 1 ;;
	esac
}

refresh_shadows() {
	# Self-hosted (--isolated) mode has no host filesystem underneath to shadow,
	# and shadow-mounts.sh is skipped there entirely; mirror that here. It also
	# always mounts an isolated workspace volume (and sets PNPM_STORE_DIR), so the
	# unmounted-root warning below never applies to it either.
	[ "${POWBOX_SELF_HOSTED:-}" = "1" ] && return 0

	# Resolve pnpm's EFFECTIVE directory, honoring `-C, --dir <dir>` ("Change to
	# directory <dir>", per `pnpm install --help`). A `pnpm -C /workspace/<repo>
	# install` (or `--dir`) invoked from OUTSIDE /workspace still writes node_modules
	# into that project, so the /workspace guard and the project-scoping walk below
	# must key off that target rather than the raw $PWD — otherwise the early return
	# here would skip the very refresh this wrapper exists to do. pnpm accepts
	# `-C <dir>`, `--dir <dir>`, and the `=`-joined forms; a later flag wins.
	local effdir="$PWD" prev="" a
	for a in "$@"; do
		case "$prev" in
			-C | --dir) effdir="$a" ;;
		esac
		case "$a" in
			-C=* | --dir=*) effdir="${a#*=}" ;;
		esac
		prev="$a"
	done
	# Canonicalize: resolve a relative `-C` (pnpm interprets it against $PWD), strip
	# `..`, and confirm the target exists — all in a subshell, so the wrapper's own
	# cwd is untouched. A bogus `-C` is pnpm's error to report, so just skip here.
	effdir="$(cd "$effdir" 2>/dev/null && pwd -P)" || return 0

	# Only meaningful inside a /workspace project.
	case "$effdir" in
		/workspace/?*) ;;
		*) return 0 ;;
	esac

	# Scope the scan to this project: resolve the direct child of /workspace that
	# contains $effdir by walking up until the parent is /workspace.
	local ws="$effdir"
	while [ "$(dirname "$ws")" != "/workspace" ]; do
		ws="$(dirname "$ws")"
		[ "$ws" = "/" ] && return 0
	done

	# This refresh runs for the whole install-class (see the trigger loop), which
	# includes store-only commands like `pnpm fetch` that only warm the pnpm store from
	# the lockfile and never write the project's node_modules. The warning below is
	# about node_modules landing on the host bind mount, so it must fire only for a
	# subcommand that actually writes node_modules. writes_root_node_modules is true iff
	# some arg is an install-class token that is NOT store-only — derived from the same
	# shared classifiers as the trigger, so the gate can never drift from it.
	local writes_root_node_modules=0 wa
	for wa in "$@"; do
		if is_install_class_subcommand "$wa" && ! is_store_only_subcommand "$wa"; then
			writes_root_node_modules=1
			break
		fi
	done

	# Regression guard (PR #59 follow-up, task 002b). In dir-mounted mode the launcher
	# mounts the isolated root node_modules volume — and sets PNPM_STORE_DIR — ONLY when
	# the folder already declared a JS/powbox project at launch. A folder launched as
	# non-dev gets neither, so if the user scaffolds a project mid-session (pnpm init,
	# then install) the ROOT install lands node_modules straight on the host bind mount —
	# the exact host litter / Linux-native-binary pollution the launch-time gate exists to
	# prevent. The wrapper can re-shadow a new SUBPACKAGE but cannot retrofit the missing
	# root mount, so warn loudly (once) and proceed: relaunching now that the folder has a
	# package.json mounts an isolated volume on the next start. Fire only for a node_modules-
	# writing ROOT install (writes_root_node_modules above, and effdir is the workspace root,
	# matching how this wrapper scopes the install target) so a store-only command like
	# `pnpm fetch` or a subpackage install never trips it. Detect "should have been mounted
	# but wasn't" via the launcher's own contract — PNPM_STORE_DIR is set iff it mounted the
	# volume — plus `mountpoint`, so a self-hosted run (returned above), an already-mounted
	# dir-mounted dev project (PNPM_STORE_DIR set), and a genuinely self-hosted layout never
	# warn. Guard on `command -v mountpoint` so a missing tool degrades to silence rather
	# than a false alarm.
	if [ "$writes_root_node_modules" = 1 ] &&
		[ "$effdir" = "$ws" ] &&
		[ -z "${PNPM_STORE_DIR:-}" ] &&
		command -v mountpoint >/dev/null 2>&1 &&
		! mountpoint -q "$ws/node_modules" 2>/dev/null; then
		echo "pnpm-shadow-wrapper: WARNING: '$ws' was launched as a non-dev folder, so its root node_modules is NOT an isolated volume — this install writes node_modules onto the host bind mount (host litter / Linux-native binaries). Relaunch the agent now that this folder has a package.json to get an isolated per-container node_modules volume." >&2
	fi

	# Best-effort re-shadow of any freshly added subpackage. A shadow failure — or no
	# shadow-refresh.sh at all (e.g. an older base image) — must never block the real pnpm
	# command, and never gates the warning above (which is independent of it).
	command -v shadow-refresh.sh >/dev/null 2>&1 || return 0
	shadow-refresh.sh "$ws" >/dev/null 2>&1 || true
}

# Only refresh for install-class subcommands — anything that can create or populate
# node_modules, plus store-only commands like `fetch` that warm the pnpm store for a
# possibly-just-scaffolded package.  pnpm accepts global flags before the subcommand
# (`pnpm -w add`, `pnpm --filter x i`, `pnpm -C dir install`), so scan every argument
# rather than only the first.  A false positive triggers a harmless idempotent refresh;
# a false negative would defeat the purpose, so the list errs toward catching everything
# that writes node_modules.  The root-node_modules warning inside refresh_shadows is
# gated more narrowly to the node_modules-writing subset (see is_store_only_subcommand).
for arg in "$@"; do
	if is_install_class_subcommand "$arg"; then
		refresh_shadows "$@"
		break
	fi
done

# Delegate to the real pnpm. Keep the proven happy path (exec the executable .mjs)
# and add fallbacks: run a non-executable entry via `node` (the .cjs shim isn't
# chmod +x), and try the .cjs shim if the .mjs is absent. node is always on PATH in
# this image, just as the .mjs's `#!/usr/bin/env node` shebang already requires.
if [ -x "$PNPM_BINDIR/pnpm.mjs" ]; then
	exec "$PNPM_BINDIR/pnpm.mjs" "$@"
elif [ -f "$PNPM_BINDIR/pnpm.mjs" ]; then
	exec node "$PNPM_BINDIR/pnpm.mjs" "$@"
elif [ -f "$PNPM_BINDIR/pnpm.cjs" ]; then
	exec node "$PNPM_BINDIR/pnpm.cjs" "$@"
fi
echo "pnpm-shadow-wrapper: real pnpm not found under $PNPM_BINDIR" >&2
exit 127
