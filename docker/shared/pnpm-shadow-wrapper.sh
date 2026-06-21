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

# name-arg subcommands take a following NAME (a script, a binary, a package) that can
# itself be an install-class word: `pnpm run install`, `pnpm exec add`, `pnpm dlx
# create-foo`, `pnpm create vite`. The subcommand resolver below must STOP at one of
# these so the trailing word is read as its argument, never as the subcommand — the
# false positive that made the root-node_modules warning noisy.
is_name_arg_subcommand() {
	case "$1" in
		run | exec | dlx | create) return 0 ;;
		*) return 1 ;;
	esac
}

# Every pnpm subcommand the resolver below must be able to RECOGNIZE so it stops at the
# real subcommand rather than skipping past it. It is the union of three sets: install-
# class and name-arg (defined above — reused here so this can never drift from them) plus
# the management/query/misc subcommands that are neither. The last group does not write
# node_modules, but it MUST be listed: many of these take a following positional that can
# be an install-class word (`pnpm why install`, `pnpm list add`, `pnpm remove update`,
# `pnpm config get install`), and if the resolver did not recognize `why`/`list`/… it
# would skip them and latch the trailing install-class word, falsely warning. Keep this
# in sync with `pnpm help` (pnpm 11); an unlisted brand-new subcommand only degrades to
# the same latching, never to a crash.
is_known_subcommand() {
	is_install_class_subcommand "$1" && return 0
	is_name_arg_subcommand "$1" && return 0
	case "$1" in
		remove | rm | uninstall | un | unlink | prune | \
			audit | licenses | list | ls | ll | outdated | why | \
			patch | patch-commit | patch-remove | \
			store | cache | config | c | doctor | env | deploy | server | \
			root | bin | setup | pack | publish | init | stage | \
			start | test | t | restart | clean | runtime | rt | self-update | \
			approve-builds | ignored-builds | cat-file | cat-index | find-hash) return 0 ;;
		*) return 1 ;;
	esac
}

# Resolve pnpm's actual SUBCOMMAND so a classifier decision can key off what pnpm will
# really run rather than any install-class word that merely appears somewhere in the
# args. pnpm accepts global flags (some value-taking) before the subcommand, so we
# CANNOT just take the first non-`-` token: that token might be a flag's value. Rather
# than chase an ever-growing list of value-taking globals (the gap that let `pnpm
# --reporter silent install` resolve its subcommand as `silent` and silently skip the
# task-002b warning — `--reporter`/`--loglevel`/… were not in the old skip list), the
# subcommand is resolved as the FIRST token that NAMES a real subcommand
# (is_known_subcommand). A flag's value (`silent`, `debug`, …) is not a subcommand name,
# so it is skipped for free — making resolution robust to value-taking globals we do not
# special-case. Stopping at the first REAL subcommand (not the first install-class word)
# is also what keeps `pnpm run install` resolving to `run` (with `install` as its script
# name) and `pnpm why install` to `why`, never to `install`.
#
# Residual ambiguity: an arbitrary-string global flag whose VALUE happens to equal a
# subcommand name (a directory named `run`: `pnpm -C run install`; a package named `add`:
# `pnpm --filter add install`). Those values are user-controlled and CAN collide, so we
# explicitly step over the value of the arbitrary-string / selector globals — `-C/--dir`,
# `--filter/-F/--filter-prod`, `--store-dir/--virtual-store-dir`, `--modules-dir/
# --lockfile-dir` (their `=`-joined forms are self-contained) — pnpm 11's dir/selector-
# valued globals per `pnpm install --help`. An omitted value-taking global matters only
# if its value is EXACTLY a subcommand name (a directory or selector literally named
# `run`/`install`/…), which is exotic; then resolution mis-fires in whichever direction
# the collision points — a value equal to an install-class word warns identically
# (benign), but a value equal to a non-install subcommand (`run`, `why`) would make a
# real root install resolve to that word and stay silent. Enum-valued globals
# (`--reporter`, `--loglevel`) can never collide and are skipped for free by the
# recognizer. Prints the subcommand, or nothing for a bare `pnpm`.
pnpm_subcommand() {
	local prev="" a
	for a in "$@"; do
		# A preceding arbitrary-string global flag consumed this token as its value — it
		# is the flag's argument (a path/package selector that could collide with a
		# subcommand name), never the subcommand, so skip it.
		case "$prev" in
			-C | --dir | --filter | -F | --filter-prod | \
				--store-dir | --virtual-store-dir | --modules-dir | --lockfile-dir)
				prev="$a"
				continue
				;;
		esac
		prev="$a"
		# The subcommand is the first token that names a real subcommand. Everything
		# else — flags and their (enum or otherwise non-colliding) values — is skipped.
		if is_known_subcommand "$a"; then
			printf '%s' "$a"
			return 0
		fi
	done
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
	# subcommand that actually writes node_modules. Key it off the RESOLVED pnpm
	# subcommand (not any token in the args) so `pnpm run install` / `pnpm exec install`
	# — where `install` is a script/command name, not the subcommand — are never misread
	# as a root install. writes_root_node_modules is true iff that subcommand is
	# install-class and NOT store-only, using the same shared classifiers as the trigger
	# so the gate can never drift from it.
	local subcmd writes_root_node_modules=0
	subcmd="$(pnpm_subcommand "$@")"
	if [ -n "$subcmd" ] &&
		is_install_class_subcommand "$subcmd" &&
		! is_store_only_subcommand "$subcmd"; then
		writes_root_node_modules=1
	fi

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
# gated more narrowly — to the RESOLVED subcommand (not any arg) and to the node_modules-
# writing subset (see pnpm_subcommand and is_store_only_subcommand) — so an install-class
# word that is merely an argument (`pnpm run install`) refreshes but never warns.
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
