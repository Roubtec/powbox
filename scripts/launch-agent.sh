#!/usr/bin/env bash
set -euo pipefail

AGENT="${1:?usage: launch-agent.sh <claude|codex> [project-path | repo-spec] [--build] [--detach] [--shell] [--volatile] [--persist] [--resume] [--continue] [--exec <task> (codex only)] [--isolated [--repo <spec>] [--name <label>] [--ref <branch>] [--reclone]]}"
shift

case "$AGENT" in
claude | codex) ;;
*)
	echo "Unknown agent: $AGENT" >&2
	exit 1
	;;
esac

PROJECT_PATH="."
POSITIONAL_SET=false
BUILD=false
DETACH=false
SHELL_ONLY=false
VOLATILE=false
PERSIST=false
RESUME=false
CONTINUE=false
EXEC_TASK=""
CTX_PATH=""
# Self-hosted ("--isolated") mode: the container clones the repo into a private
# per-instance volume instead of bind-mounting a host dir. All of the following
# stay inert (and dir-mounted mode stays byte-for-byte unchanged) unless
# ISOLATED is set.
ISOLATED=false
REPO_FLAG=""
INSTANCE_NAME=""
CLONE_REF=""
RECLONE=false

while [ "$#" -gt 0 ]; do
	case "$1" in
	--build)
		BUILD=true
		;;
	--isolated)
		ISOLATED=true
		;;
	--repo)
		shift
		REPO_FLAG="${1:?missing spec for --repo}"
		;;
	--name)
		shift
		INSTANCE_NAME="${1:?missing label for --name}"
		;;
	--ref)
		shift
		CLONE_REF="${1:?missing branch for --ref}"
		;;
	--reclone | --fresh)
		RECLONE=true
		;;
	--detach)
		DETACH=true
		;;
	--shell)
		SHELL_ONLY=true
		;;
	--volatile)
		VOLATILE=true
		;;
	--persist)
		PERSIST=true
		;;
	--resume)
		RESUME=true
		;;
	--continue)
		CONTINUE=true
		;;
	--ctx)
		shift
		CTX_PATH="${1:?missing path for --ctx}"
		;;
	--exec)
		if [ "$AGENT" != "codex" ]; then
			echo "--exec is only supported for codex." >&2
			exit 1
		fi
		shift
		EXEC_TASK="${1:?missing task for --exec}"
		;;
	--*)
		echo "Unknown option: $1" >&2
		exit 1
		;;
	*)
		if [ "$POSITIONAL_SET" = true ]; then
			echo "Unexpected extra positional argument: $1" >&2
			exit 1
		fi
		PROJECT_PATH="$1"
		POSITIONAL_SET=true
		;;
	esac
	shift
done

# Reject the self-hosted-only flags when --isolated was not given, so a typo
# fails loudly instead of silently launching the unchanged dir-mounted mode.
if [ "$ISOLATED" != true ]; then
	if [ -n "$REPO_FLAG" ] || [ -n "$INSTANCE_NAME" ] || [ -n "$CLONE_REF" ] || [ "$RECLONE" = true ]; then
		echo "Error: --repo/--name/--ref/--reclone require --isolated." >&2
		exit 1
	fi
fi

# In dir-mounted mode the positional is a host project directory and must exist;
# in self-hosted mode it is re-interpreted as the repo spec (resolved below) and
# is NOT a host path, so the directory checks/canonicalisation are skipped.
if [ "$ISOLATED" != true ]; then
	if [ ! -d "$PROJECT_PATH" ]; then
		echo "Error: project path does not exist: ${PROJECT_PATH}" >&2
		exit 1
	fi
fi

if [ -n "$CTX_PATH" ] && [ ! -d "$CTX_PATH" ]; then
	echo "Error: context path does not exist: ${CTX_PATH}" >&2
	exit 1
fi
if [ -n "$CTX_PATH" ]; then
	CTX_PATH="$(cd "$CTX_PATH" && pwd -P)"
fi
if [ "$ISOLATED" != true ]; then
	PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd -P)"
	# Only strip the trailing slash when the path is not the filesystem root ("/"), since
	# stripping "/" would produce an empty string and break basename and Docker bind-mount paths.
	if [ "$PROJECT_PATH" != "/" ]; then
		PROJECT_PATH="${PROJECT_PATH%/}"
	fi
	PROJECT_BASENAME="$(basename "$PROJECT_PATH")"
fi

project_hash() {
	local input="${1:-}"
	if command -v sha256sum >/dev/null 2>&1; then
		printf '%s' "$input" | sha256sum | cut -c1-12
	elif command -v shasum >/dev/null 2>&1; then
		printf '%s' "$input" | shasum -a 256 | cut -c1-12
	elif command -v openssl >/dev/null 2>&1; then
		printf '%s' "$input" | openssl dgst -sha256 | sed 's/^.* //' | cut -c1-12
	else
		echo "Error: no hashing command found (need sha256sum, shasum, or openssl)." >&2
		echo "" >&2
		echo "A unique hash of the project path is used to generate the container name." >&2
		echo "Without it, containers for different projects may share the same name, causing" >&2
		echo "one project's container to be silently reused for another — which can be destructive." >&2
		echo "" >&2
		echo "Install one of the following and retry:" >&2
		echo "  sha256sum  — part of GNU coreutils (Linux, Git Bash, WSL)" >&2
		echo "  shasum     — bundled with Perl (macOS, many Linux distros)" >&2
		echo "  openssl    — https://www.openssl.org/" >&2
		return 1
	fi
}

# Canonical "host/owner/repo" key for a repo spec (lowercased, .git stripped, any
# userinfo removed) so that different repos sharing a basename get distinct
# identities, while the SAME repo expressed different ways (owner/repo slug, https
# URL, scp-style git@host:path) maps to one stable key. Folded into a NAMED
# instance's discriminator below; see the comment there. Must stay in lockstep
# with launch-agent.ps1's Get-Powbox-RepoIdentity so the two launchers agree.
repo_identity() {
	local spec="${1:-}" id authority rest
	case "$spec" in
	*://*)
		# scheme://[user@]host[:port]/path → host[:port]/path. Strip userinfo from
		# the AUTHORITY only (a user[:pass]@ before the first '/'), not an '@' that
		# appears later in the path — mirroring launch-agent.ps1's `^[^@/]*@`, so the
		# two launchers agree on a URL whose path happens to contain an '@'.
		id="${spec#*://}"
		authority="${id%%/*}"
		rest="${id#"$authority"}"
		id="${authority#*@}${rest}"
		;;
	*@*:*)
		# scp-style user@host:owner/repo → host/owner/repo (first ':' → '/')
		id="${spec#*@}"
		id="${id%%:*}/${id#*:}"
		;;
	*)
		# bare owner/repo slug → default host (matches the github.com default the
		# clone step applies to a slug)
		id="github.com/$spec"
		;;
	esac
	# Lowercase BEFORE stripping .git so an uppercase extension (.GIT/.Git) is also
	# removed — matching launch-agent.ps1's case-insensitive `-replace '\.git$'`, so
	# the two launchers (and repo.GIT vs repo.git here) agree on the identity.
	id="$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')"
	# Trim trailing slashes BEFORE stripping .git so a URL copied with a trailing
	# separator (https://github.com/owner/app.git/) normalises to the same identity as
	# the bare form — otherwise the .git strip misses (the suffix is '/'), the slash
	# stays, and relaunching the same --name spawns a second container instead of
	# reattaching to the existing clone. Mirrors launch-agent.ps1's `-replace '/+$'`.
	id="${id%"${id##*[!/]}"}"
	printf '%s' "${id%.git}"
}

# Normalise a path for /ctx comparison.
# On Windows (MSYS/Cygwin), Docker Desktop may report bind-mount sources using
# Linux-style prefixes rather than the native drive:/... form that the shell sees.
# Convert all known representations to a canonical drive:/... form so an unchanged
# mount compares equal regardless of which format Docker happens to report.
# On Linux/macOS paths are returned as-is (case-sensitive, trailing slash stripped).
# Backslash-to-slash conversion is Windows-only; on POSIX systems a backslash is
# a valid path character and must not be silently altered.
normalize_ctx_path() {
	local p
	p="$1"
	case "$(uname -s)" in
		MINGW* | MSYS* | CYGWIN*)
			# Normalize backslashes to forward slashes (Windows paths only).
			p="$(printf '%s' "$p" | sed 's|\\|/|g')"
			# Lowercase first so that the prefix patterns below only need to match [a-z].
			# This must stay above the sed substitutions — moving it after them would
			# leave prefixes intact when Docker reports an uppercase drive letter.
			p="$(printf '%s' "$p" | tr '[:upper:]' '[:lower:]')"
			# /run/desktop/mnt/host/c and /run/desktop/mnt/host/c/... → c: and c:/...
			p="$(printf '%s' "$p" | sed 's|^/run/desktop/mnt/host/\([a-z]\)\(/.*\)\{0,1\}$|\1:\2|')"
			# /host_mnt/c and /host_mnt/c/... → c: and c:/...
			p="$(printf '%s' "$p" | sed 's|^/host_mnt/\([a-z]\)\(/.*\)\{0,1\}$|\1:\2|')"
			# /mnt/c and /mnt/c/... → c: and c:/...
			p="$(printf '%s' "$p" | sed 's|^/mnt/\([a-z]\)\(/.*\)\{0,1\}$|\1:\2|')"
			# MSYS/Git Bash native form: /c and /c/... → c: and c:/...
			p="$(printf '%s' "$p" | sed 's|^/\([a-z]\)\(/.*\)\{0,1\}$|\1:\2|')"
			;;
	esac
	# Strip trailing slash.
	printf '%s' "${p%/}"
}

# Per-instance volume names that only exist in one mode. Declared empty up front
# so referencing them under `set -u` in the other mode is always safe.
NM_VOLUME=""
WT_VOLUME=""
WS_VOLUME=""
REPO_SPEC=""

if [ "$ISOLATED" = true ]; then
	# --- Self-hosted (isolated) identity -------------------------------------
	# Resolve the repo to clone. Precedence: explicit --repo wins; else if the
	# positional is an existing directory, infer it from that dir's `origin`
	# remote (the "standing inside a repo" convenience); else the positional
	# itself is the repo spec (an owner/repo slug or a clone URL).
	if [ -n "$REPO_FLAG" ]; then
		REPO_SPEC="$REPO_FLAG"
	elif [ -d "$PROJECT_PATH" ]; then
		REPO_SPEC="$(git -C "$PROJECT_PATH" remote get-url origin 2>/dev/null || true)"
		if [ -z "$REPO_SPEC" ]; then
			echo "Error: --isolated needs a repo to clone (owner/repo or a clone URL)." >&2
			echo "None was given and 'git remote get-url origin' found nothing in ${PROJECT_PATH}." >&2
			echo "Pass it explicitly, e.g. --repo owner/repo, or --repo https://github.com/owner/repo.git" >&2
			exit 1
		fi
		# Redact any userinfo (token) from the displayed origin URL so an embedded
		# credential is not echoed to the terminal/scrollback (sed mirrors
		# seed-workspace.sh's redact_url); the real spec is still used below.
		echo "Self-hosted mode: inferred repo from origin in ${PROJECT_PATH}: $(printf '%s' "$REPO_SPEC" | sed -E 's#(://)[^/]*@#\1#')" >&2
	else
		REPO_SPEC="$PROJECT_PATH"
	fi

	# Reject a clone URL that embeds a credential in its authority (e.g. a PAT URL
	# https://<token>@github.com/owner/repo.git). Self-hosted containers are kept by
	# default, so the spec is frozen into POWBOX_CLONE_REPO in the container env where
	# `docker inspect` would expose the secret long after launch. The container
	# authenticates via gh (established before the clone), so an embedded credential is
	# never needed — fail fast. Only http(s) userinfo is a secret; an ssh:// URL's
	# `git@` is a benign SSH user (key auth) and is normalised to HTTPS in the
	# container, so it is left alone. The error never echoes the userinfo itself.
	#
	# URL schemes are case-insensitive (RFC 3986), so the scheme is lower-cased before
	# matching — otherwise HTTPS://<token>@host/… would slip past a case-sensitive
	# http(s) pattern and the secret would be frozen into the env anyway. (The
	# PowerShell launcher's -match/-replace are case-insensitive by default, so this
	# keeps the two in parity.)
	case "$REPO_SPEC" in
	*://*)
		_ru_scheme="$(printf '%s' "${REPO_SPEC%%://*}" | tr '[:upper:]' '[:lower:]')"
		case "$_ru_scheme" in
		http | https)
			_ru_authority="${REPO_SPEC#*://}"
			_ru_authority="${_ru_authority%%/*}"
			case "$_ru_authority" in
			*@*)
				echo "Error: the clone URL embeds a credential in its authority (userinfo before '@')." >&2
				echo "Self-hosted containers are kept, so this would persist the secret in the container" >&2
				echo "environment (visible via 'docker inspect'). The container authenticates via gh, so" >&2
				echo "drop the credential and pass a plain URL or slug, e.g. --repo owner/repo." >&2
				exit 1
				;;
			esac
			unset _ru_authority
			;;
		esac
		unset _ru_scheme
		;;
	esac

	# Reject control characters in any value frozen into a container label. cc-list /
	# agent-list parse the labels back with a \x1f field separator and one-container-
	# per-line reads, so a newline or a literal \x1f in --name/--repo/--ref would split
	# a record or shift fields and corrupt the listing (display quoting can't undo a real
	# newline). No legitimate repo spec, ref, or name contains a control char, so fail
	# fast here rather than at display time. The flag-name prefix is split on the FIRST
	# ':' only, so a repo spec's own ':' (https://…, git@host:path) is preserved.
	for _cc_pair in "--name:$INSTANCE_NAME" "--repo:$REPO_SPEC" "--ref:$CLONE_REF"; do
		case "${_cc_pair#*:}" in
		*[[:cntrl:]]*)
			echo "Error: ${_cc_pair%%:*} must not contain control characters (newlines, tabs, etc.)." >&2
			exit 1
			;;
		esac
	done
	unset _cc_pair

	# repo-slug: basename, strip a trailing .git, lowercase + sanitise — the same
	# shape as the dir-mounted PROJECT_BASENAME handling above. Lowercase BEFORE the
	# .git strip so an uppercase .GIT/.Git extension is removed too (POSIX %.git is
	# case-sensitive), matching the PowerShell launcher's case-insensitive strip.
	REPO_BASENAME="$(basename "$REPO_SPEC" | tr '[:upper:]' '[:lower:]')"
	REPO_BASENAME="${REPO_BASENAME%.git}"
	REPO_SLUG="$(printf '%s' "$REPO_BASENAME" | tr -cs 'a-z0-9._-' '-' | sed 's/^-//; s/-$//')"
	if [ -z "$REPO_SLUG" ]; then
		echo "Error: could not derive a repo slug from '${REPO_SPEC}'." >&2
		exit 1
	fi

	# Instance discriminator: --name <label> if given (named → deterministic →
	# reusable: same clone + session history across launches), else a
	# high-resolution timestamp + pid + random token so two same-second unnamed
	# launches never collide (unnamed → fresh every launch). The instance hash is
	# SHA256(label)[:12], reusing the dir-mounted 12-char hash shape.
	#
	# A NAMED discriminator folds in the canonical repo identity, so the same --name
	# used for two different repos that share a basename (owner1/app vs owner2/app)
	# resolves to distinct identities instead of one shared app-<hash> — which would
	# otherwise let the second launch attach to (or --reclone wipe) the first repo's
	# container and workspace. It ALSO folds in the agent, so the same repo+name under
	# both agents (cc vs cx) gets distinct PROJECT_NAMEs and therefore distinct
	# /workspace/<slug> paths — the per-instance workspace volume is already keyed per
	# container (agent-ws-<container>), so without this the two agents would share one
	# in-container cwd while holding independent clones, and a delegated peer agent
	# (both config volumes are always mounted) resumes sessions by cwd and would pick
	# up the other clone's history. The unnamed branch already gets a globally-unique
	# timestamp, so it needs no repo/agent discriminator.
	if [ -n "$INSTANCE_NAME" ]; then
		INSTANCE_LABEL="$(repo_identity "$REPO_SPEC")|$AGENT|$INSTANCE_NAME"
	else
		INSTANCE_LABEL="ts-$(date -u +%Y%m%d%H%M%S)-$$-${RANDOM}${RANDOM}"
	fi
	INSTANCE_HASH="$(project_hash "$INSTANCE_LABEL")"
	# Cosmetic, human-readable slug from --name, folded into PROJECT_NAME so the
	# container/workspace name and `cc-list` show WHICH instance without an inspect. It
	# does NOT own identity: the 12-char hash above (which hashes the RAW --name) does,
	# so two --names that slugify alike — "Feature A" and "feature/a" both → feature-a —
	# stay distinct containers (told apart by the hash and the powbox.instance-name
	# label). Sanitise to the repo-slug shape, cap the length, and drop it entirely if it
	# empties out so a punctuation-only name never weakens the hash-based identity. Empty
	# for unnamed launches (no --name → no slug, so PROJECT_NAME is unchanged there).
	NAME_SLUG="$(printf '%s' "$INSTANCE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^[-.]*//; s/[-.]*$//' | cut -c1-32 | sed 's/[-.]*$//')"
	PROJECT_NAME="${REPO_SLUG}${NAME_SLUG:+-${NAME_SLUG}}-${INSTANCE_HASH}"
else
	# --- Dir-mounted identity (unchanged) ------------------------------------
	# On Windows (MSYS/Cygwin), the filesystem is typically case-insensitive and the terminal
	# may report paths with inconsistent capitalisation, so we normalise to lowercase before
	# hashing — matching PowerShell's ToLowerInvariant() behaviour.
	# On Linux and macOS the filesystem is case-sensitive, so two paths differing only by case
	# are genuinely distinct directories; lowercasing would risk hash collisions between different
	# workspaces. We therefore preserve the path as-is on those platforms.
	case "$(uname -s)" in
	MINGW* | MSYS* | CYGWIN*)
		PROJECT_HASH_INPUT="$(printf '%s' "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]')"
		;;
	*)
		PROJECT_HASH_INPUT="$PROJECT_PATH"
		;;
	esac
	PROJECT_HASH="$(project_hash "$PROJECT_HASH_INPUT")"
	PROJECT_NAME="$(printf '%s' "$PROJECT_BASENAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-' | sed 's/^-//; s/-$//')-$PROJECT_HASH"
	NM_VOLUME="agent-nm-${PROJECT_NAME}"
	# Per-project worktrees volume. Holds the git worktrees AND the pnpm store under
	# ONE mount so pnpm hardlinks package files into per-worktree node_modules
	# instead of copying them. ext4, persistent, container-local, and shared between
	# this project's Claude and Codex containers (project-keyed, like NM_VOLUME).
	WT_VOLUME="agent-wt-${PROJECT_NAME}"
fi

CONTAINER_NAME="${AGENT}-${PROJECT_NAME}"
WORKSPACE_MOUNT="/workspace/${PROJECT_NAME}"
# pnpm store path under the workspace mount (same mount as .worktrees/<task> in
# both modes — a per-project volume in dir-mounted mode, the one workspace volume
# in self-hosted mode — so per-worktree `pnpm install` hardlinks from the store).
WT_STORE_DIR="${WORKSPACE_MOUNT}/.worktrees/.pnpm-store"
# Per-container rootless Podman storage (images + named volumes) so an in-sandbox
# agent's containers and their data persist across restarts. Keyed by the OUTER
# container (agent + project), NOT just the project: a project's Claude and Codex
# containers can run concurrently, and two Podman instances with separate
# runroots/namespaces sharing one graphroot corrupt each other's metadata and
# lifecycle state. A shared image cache is a separate concern (additionalimagestores).
PODMAN_VOLUME="agent-podman-${CONTAINER_NAME}"
if [ "$ISOLATED" = true ]; then
	# The one per-instance workspace volume that REPLACES the host bind mount plus
	# the dir-mounted agent-nm-*/agent-wt-* shadows: the clone, node_modules,
	# .worktrees, and the pnpm store all live inside it as ordinary subdirs (one
	# mount → pnpm hardlinks everywhere, including the root node_modules). Keyed by
	# the full container name, like PODMAN_VOLUME, so it is part of the container's
	# identity. Mounted via compose.selfhosted.yml (merged by target path).
	WS_VOLUME="agent-ws-${CONTAINER_NAME}"
fi

# Internal/testing hook: print the resolved identity and exit before touching
# Docker. Lets the self-hosted smoke test assert naming (named→deterministic,
# unnamed→fresh, repo-slug derivation) without building or launching anything.
if [ "${POWBOX_PRINT_IDENTITY:-}" = "1" ]; then
	if [ "$ISOLATED" = true ]; then printf 'mode=isolated\n'; else printf 'mode=dir-mounted\n'; fi
	printf 'PROJECT_NAME=%s\n' "$PROJECT_NAME"
	printf 'CONTAINER_NAME=%s\n' "$CONTAINER_NAME"
	printf 'WORKSPACE_MOUNT=%s\n' "$WORKSPACE_MOUNT"
	printf 'PODMAN_VOLUME=%s\n' "$PODMAN_VOLUME"
	printf 'NM_VOLUME=%s\n' "$NM_VOLUME"
	printf 'WT_VOLUME=%s\n' "$WT_VOLUME"
	printf 'WS_VOLUME=%s\n' "$WS_VOLUME"
	printf 'REPO_SPEC=%s\n' "$REPO_SPEC"
	printf 'CLONE_REF=%s\n' "$CLONE_REF"
	exit 0
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_ARGS=(-p powbox -f "${ROOT_DIR}/compose.shared.yml" -f "${ROOT_DIR}/compose.agent.yml")
# Self-hosted overlay: replaces the host workspace BIND mount in compose.shared.yml
# with the per-instance named volume (merged by target path /workspace/<slug>).
# Added after the shared file so its volume entry wins; the fuse/netdev overlays
# appended later only add devices, so ordering with them is irrelevant.
if [ "$ISOLATED" = true ]; then
	COMPOSE_ARGS+=(-f "${ROOT_DIR}/compose.selfhosted.yml")
fi

# Ensure named volumes exist (compose won't auto-create external volumes). Both
# config volumes are always created/mounted so the non-primary agent can be
# spun up in-container with its own persistent login and skills.
# agent-podman-imagestore is the single GLOBAL read-only image cache shared by
# every container across all projects (consumed via Podman additionalimagestores).
# It is infra, like the config volumes — created here, never per-container.
SHARED_VOLUMES=(agent-gh-config agent-zsh-history claude-config codex-config agent-podman-imagestore)
for vol in "${SHARED_VOLUMES[@]}"; do
	if ! docker volume inspect "$vol" >/dev/null 2>&1; then
		docker volume create "$vol" >/dev/null
	fi
done

# In dir-mounted mode WORKSPACE_PATH is the host bind source. In self-hosted mode
# the workspace mount comes from compose.selfhosted.yml (which overrides the bind
# by target path), so WORKSPACE_PATH is unused — set it to a harmless "." that
# still parses as a valid short-syntax mount source, and export the volume name
# the overlay interpolates into its external `name:`.
if [ "$ISOLATED" = true ]; then
	export WORKSPACE_PATH="."
	export POWBOX_WS_VOLUME="$WS_VOLUME"
else
	export WORKSPACE_PATH="$PROJECT_PATH"
fi
export PROJECT_NAME

GH_HOST_CONFIG_DIR="${GH_HOST_CONFIG_DIR:-$HOME/.config/gh}"
GIT_CONFIG_PATH="${GIT_CONFIG_PATH:-$HOME/.gitconfig}"

CONTAINER_EXISTS=false
CONTAINER_RUNNING=false

if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
	CONTAINER_EXISTS=true
	if [ "$(docker container inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]; then
		CONTAINER_RUNNING=true
	fi
fi

if [ "$BUILD" = true ]; then
	"${ROOT_DIR}/scripts/build-image.sh" agent
fi

if [ "$RESUME" = true ]; then
	if [ "$CONTAINER_EXISTS" != true ]; then
		echo "No persisted container named ${CONTAINER_NAME} was found. Start it once normally, or with --persist if you want to be explicit." >&2
		exit 1
	fi
	if [ -n "$CTX_PATH" ]; then
		echo "Note: --ctx is ignored with --resume; container will resume with its existing mounts. Omit --resume to apply ctx changes." >&2
	fi
	if [ "$CONTINUE" = true ]; then
		echo "Note: --continue is ignored with --resume; container will restart with the CMD it was originally created with. Omit --resume to apply a continue-flag change." >&2
	fi
	if [ "$RECLONE" = true ]; then
		echo "Note: --reclone is ignored with --resume; the existing checkout is left untouched. Omit --resume to wipe and re-clone." >&2
	fi
	if [ -n "$CLONE_REF" ]; then
		echo "Note: --ref is ignored on resume; the existing checkout is left untouched." >&2
	fi
	exec docker start -ai "$CONTAINER_NAME"
fi

# Self-hosted --reclone: wipe and re-seed an existing named container's clone.
# A reused container is started in place (reuse block below) and never re-runs the
# prep/create flow, so --reclone removes the stopped container to force that flow;
# the prep step then empties the (kept) agent-ws-* volume and the entrypoint clones
# fresh. The wipe is one-shot — nothing about it is frozen into the container.
if [ "$ISOLATED" = true ] && [ "$RECLONE" = true ] && [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	if [ "$CONTAINER_RUNNING" = true ]; then
		echo "Container ${CONTAINER_NAME} is running; stop it before --reclone (it re-clones on recreate)." >&2
		exit 1
	fi
	echo "--reclone: recreating ${CONTAINER_NAME} so it re-seeds its workspace from a fresh clone."
	if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
		if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
			echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
			exit 1
		fi
	fi
	CONTAINER_EXISTS=false
fi

# --ref only takes effect when seed-workspace actually CLONES, and it clones only when
# the per-instance workspace volume holds no checkout: a brand-new instance, or a
# --reclone (whose prep empties the volume). Whenever that volume is already populated,
# seed-workspace keeps the existing checkout and --ref is silently ignored — so WARN.
# Gate on the VOLUME, not CONTAINER_EXISTS: that also covers a container pruned while its
# agent-ws-* volume survived (e.g. agent-prune-stopped), and stays correct when a later
# block recreates the container (the kept volume is reused, so --ref still won't apply).
# The volume is created by the prep step further below, so on a genuine first launch it
# does not exist yet here and no warning fires. Benign by design — these are attended
# launches and the agent/user can switch refs in-container.
if [ "$ISOLATED" = true ] && [ -n "$CLONE_REF" ] && [ "$RECLONE" != true ] &&
	docker volume inspect "$WS_VOLUME" >/dev/null 2>&1; then
	echo "Note: --ref '${CLONE_REF}' applies only to a fresh clone; ${CONTAINER_NAME} keeps the existing checkout in its workspace volume. Use --reclone to re-clone at this ref, or switch branches inside the container." >&2
fi

if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	# Detect whether the requested /ctx mount differs from the existing container.
	# If it does, remove the stopped container so it gets recreated with the correct mounts.
	# When --ctx is omitted, keep whatever is already mounted (or not) — the user can add
	# --volatile to force a clean slate.
	EXISTING_CTX="$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/ctx"}}{{.Source}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"

	if [ -n "$CTX_PATH" ]; then
		EXISTING_NORM="$(normalize_ctx_path "$EXISTING_CTX")"
		WANT_NORM="$(normalize_ctx_path "$CTX_PATH")"
		if [ "$EXISTING_NORM" != "$WANT_NORM" ]; then
			if [ "$CONTAINER_RUNNING" = true ]; then
				echo "Container ${CONTAINER_NAME} is running with a different /ctx mount. Stop the container first, then relaunch with the new --ctx path." >&2
				exit 1
			fi
			echo "Context mount changed (was '${EXISTING_CTX}', now '${CTX_PATH}'); recreating container."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	elif [ -n "$EXISTING_CTX" ]; then
		echo "Note: container has /ctx mounted from a previous session (${EXISTING_CTX}). Use --volatile to start fresh or --ctx to change it."
	fi
fi

# Resolve which host devices rootless Podman will receive this launch into a
# normalised set string ("fuse,tun" / "fuse" / "tun" / "none"). The device list is
# frozen at container creation — `docker start` can't add /dev/fuse or /dev/net/tun
# to an existing container — so this is recorded as a label and a change recreates a
# stopped container (mirrors the /ctx and --continue handling). 'auto' resolves
# against the launcher host's /dev here, so the same host yields a stable value;
# 'on' forces both devices, 'off' neither. The compose-file selection below derives
# from the same value, so the label and the actual attach never disagree.
case "${POWBOX_PODMAN:-${POWBOX_FUSE:-auto}}" in
on) PODMAN_DEVICE_MODE="fuse,tun" ;;
off) PODMAN_DEVICE_MODE="none" ;;
*)
	PODMAN_DEVICE_MODE=""
	[ -e /dev/fuse ] && PODMAN_DEVICE_MODE="fuse"
	[ -e /dev/net/tun ] && PODMAN_DEVICE_MODE="${PODMAN_DEVICE_MODE:+${PODMAN_DEVICE_MODE},}tun"
	[ -n "$PODMAN_DEVICE_MODE" ] || PODMAN_DEVICE_MODE="none"
	;;
esac

# Detect whether the --continue flag state differs from what the container was created with.
# The CMD is frozen at container creation, so a flag change only takes effect after recreation.
# Missing label on an existing container predates this flag — treat it as "true" so the old
# auto-resume default remains in effect for reused containers until the user explicitly opts out,
# at which point this branch recycles the container to honour the new intent.
if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	EXISTING_CONTINUE="$(docker inspect --format '{{with .Config.Labels}}{{with index . "powbox.continue"}}{{.}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
	if [ -z "$EXISTING_CONTINUE" ]; then
		EXISTING_CONTINUE="true"
	fi
	WANT_CONTINUE="false"
	if [ "$CONTINUE" = true ]; then
		WANT_CONTINUE="true"
	fi
	if [ "$EXISTING_CONTINUE" != "$WANT_CONTINUE" ]; then
		if [ "$CONTAINER_RUNNING" = true ]; then
			echo "Note: container ${CONTAINER_NAME} is running; --continue=${WANT_CONTINUE} is ignored because the existing process was started with --continue=${EXISTING_CONTINUE}. Attaching to the running process. Stop it and relaunch to apply the flag change." >&2
		else
			echo "Continue flag changed (was '${EXISTING_CONTINUE}', now '${WANT_CONTINUE}'); recreating container."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	fi
fi

# Detect whether the existing container predates the per-project .worktrees volume
# (and its co-located pnpm store). Such a container was created before this change,
# so it still has a tmpfs .worktrees shadow and points pnpm at the old shared store —
# it never gets the hardlinking store-dir, even after the image is rebuilt. Recreate a
# stopped container that lacks the agent-wt-* mount so the new mount + PNPM_STORE_DIR
# take effect; warn (don't disrupt) if it is currently running. Self-hosted mode has
# no separate .worktrees mount (it is a subdir of the one workspace volume), so this
# guard is dir-mounted-only — otherwise it would wrongly recreate every reuse.
if [ "$ISOLATED" != true ] && [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	HAS_WT_MOUNT="$(docker inspect --format "{{range .Mounts}}{{if eq .Destination \"${WORKSPACE_MOUNT}/.worktrees\"}}yes{{end}}{{end}}" "$CONTAINER_NAME" 2>/dev/null || true)"
	if [ -z "$HAS_WT_MOUNT" ]; then
		if [ "$CONTAINER_RUNNING" = true ]; then
			echo "Note: container ${CONTAINER_NAME} predates the per-project .worktrees volume; it is still using a tmpfs .worktrees and the old pnpm store, so worktree installs won't hardlink. Stop it and relaunch (or use --volatile) to enable hardlinked worktree node_modules." >&2
		else
			echo "Container ${CONTAINER_NAME} predates the per-project .worktrees volume; recreating it so worktree node_modules hardlink from the co-located pnpm store."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	fi
fi

# Detect whether the existing container predates the per-container Podman storage
# volume. Such a container was created before rootless-Podman support, so its
# /home/node/.local/share/containers is ephemeral (no agent-podman-* mount) and
# it was launched without /dev/fuse — pulled images and podman volumes would not
# persist, even after the image is rebuilt. Recreate a stopped container that
# lacks the mount so the new volume + device attach; warn (don't disrupt) if it
# is currently running.
if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	HAS_PODMAN_MOUNT="$(docker inspect --format "{{range .Mounts}}{{if eq .Destination \"/home/node/.local/share/containers\"}}yes{{end}}{{end}}" "$CONTAINER_NAME" 2>/dev/null || true)"
	if [ -z "$HAS_PODMAN_MOUNT" ]; then
		if [ "$CONTAINER_RUNNING" = true ]; then
			echo "Note: container ${CONTAINER_NAME} predates the per-container Podman storage volume; nested-container images and volumes won't persist and the podman devices (/dev/fuse, /dev/net/tun) aren't attached. Stop it and relaunch (or use --volatile) to enable persistent rootless Podman storage." >&2
		else
			echo "Container ${CONTAINER_NAME} predates the per-container Podman storage volume; recreating it so rootless Podman images and volumes persist."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	fi
fi

# Detect whether the existing container was created with a different rootless-Podman
# device set than this launch resolves (POWBOX_PODMAN changed, or the host's /dev
# visibility changed under `auto`). The device list is frozen at creation, so a
# stopped container first created with POWBOX_PODMAN=off — or under `auto` on a host
# that couldn't see the devices — can't gain /dev/fuse or /dev/net/tun on `docker
# start`: nested Podman would stay on vfs with no default networking. Recreate a
# stopped mismatch so the new device set attaches; warn (don't disrupt) a running
# one. A container with no recorded label predates this check — leave it alone, since
# we can't know what it was created with and the storage-mount check above already
# recreates truly pre-Podman containers.
if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	EXISTING_PODMAN_DEVICES="$(docker inspect --format '{{with .Config.Labels}}{{with index . "powbox.podman-devices"}}{{.}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
	if [ -n "$EXISTING_PODMAN_DEVICES" ] && [ "$EXISTING_PODMAN_DEVICES" != "$PODMAN_DEVICE_MODE" ]; then
		if [ "$CONTAINER_RUNNING" = true ]; then
			echo "Note: container ${CONTAINER_NAME} is running with Podman devices '${EXISTING_PODMAN_DEVICES}'; this launch resolves to '${PODMAN_DEVICE_MODE}'. The device set is fixed at container creation — stop it and relaunch (or use --volatile) to apply the change." >&2
		else
			echo "Podman device set changed (was '${EXISTING_PODMAN_DEVICES}', now '${PODMAN_DEVICE_MODE}'); recreating container."
			if ! docker rm "$CONTAINER_NAME" >/dev/null 2>&1; then
				if docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
					echo "Failed to remove existing container ${CONTAINER_NAME}." >&2
					exit 1
				fi
			fi
			CONTAINER_EXISTS=false
		fi
	fi
fi

if [ "$VOLATILE" != true ] && [ "$CONTAINER_EXISTS" = true ]; then
	if [ "$CONTAINER_RUNNING" = true ]; then
		if [ "$DETACH" = true ]; then
			echo "Container ${CONTAINER_NAME} is already running."
			exit 0
		fi
		exec docker attach "$CONTAINER_NAME"
	fi

	if [ "$DETACH" = true ]; then
		exec docker start "$CONTAINER_NAME"
	fi

	exec docker start -ai "$CONTAINER_NAME"
fi

if [ "$SHELL_ONLY" = true ]; then
	CMD=(zsh)
	if [ "$CONTINUE" = true ]; then
		echo "Note: --continue has no effect with --shell; this launch opens a plain zsh." >&2
	fi
elif [ "$AGENT" = "codex" ] && [ -n "$EXEC_TASK" ]; then
	CMD=(codex exec "$EXEC_TASK")
	if [ "$CONTINUE" = true ]; then
		echo "Note: --continue has no effect with --exec; codex exec always starts a fresh non-interactive session." >&2
	fi
elif [ "$AGENT" = "claude" ]; then
	if [ "$CONTINUE" = true ]; then
		# Pre-flight check: only pass --continue if a session history exists for this
		# working directory. Claude stores sessions in ~/.claude/projects/<slug>/,
		# where <slug> is the cwd with every non-alphanumeric, non-dash character
		# replaced by '-' (verified empirically against '/', '.', '_', spaces, '+',
		# and uppercase; case is preserved and adjacent dashes are not collapsed).
		# Passing --continue when no session exists makes claude print "No
		# conversation found" and exit instead of falling back to a fresh session.
		# The check runs inside the container where claude-config is mounted.
		CMD=(sh -c 'slug=$(printf %s "$PWD" | sed "s/[^a-zA-Z0-9-]/-/g"); if ls "$HOME/.claude/projects/$slug"/*.jsonl >/dev/null 2>&1; then exec claude --dangerously-skip-permissions --continue; else exec claude --dangerously-skip-permissions; fi')
	else
		CMD=(claude --dangerously-skip-permissions)
	fi
else
	if [ "$CONTINUE" = true ]; then
		# Codex resume --last already filters to the current cwd and falls through to
		# a fresh interactive session when nothing resumable exists there.
		CMD=(codex resume --last --dangerously-bypass-approvals-and-sandbox)
	else
		CMD=(codex --dangerously-bypass-approvals-and-sandbox)
	fi
fi

GIT_CONFIG_ARGS=()
if [ -f "$GIT_CONFIG_PATH" ]; then
	GIT_CONFIG_ARGS=(-v "${GIT_CONFIG_PATH}:/home/node/.gitconfig-host:ro")
fi

GH_CONFIG_ARGS=()
if [ -d "$GH_HOST_CONFIG_DIR" ]; then
	GH_CONFIG_ARGS=(-v "${GH_HOST_CONFIG_DIR}:/home/node/.config/gh-host:ro")
fi

CTX_ARGS=()
if [ -n "$CTX_PATH" ]; then
	CTX_ARGS=(-v "${CTX_PATH}:/ctx:ro")
fi

# Pre-create and chown the per-instance volumes to node so the entrypoint (which
# runs as node) can write into them. Self-hosted mode has ONE workspace volume
# (it must be node-owned before the entrypoint clones into it) and no nm/wt
# shadows; dir-mounted mode has the separate node_modules + worktrees shadows.
if [ "$ISOLATED" = true ]; then
	# The per-instance workspace volume is declared external in compose.selfhosted.yml,
	# and compose validates external volumes (erroring if absent) BEFORE it would honour
	# the ad-hoc `-v "${WS_VOLUME}:/mnt/workspace"` below — so on a first launch the prep
	# run would die with "External volume does not exist" and never create the container
	# (making even the loud-clone-failure drop-to-zsh path unreachable). Pre-create the
	# volume here so the prep step can chown it to node and clone into it. The dir-mounted
	# nm/wt/podman volumes need no such step because nothing declares them external (the
	# ad-hoc `-v` auto-creates them). Idempotent via the inspect guard, like SHARED_VOLUMES.
	if ! docker volume inspect "$WS_VOLUME" >/dev/null 2>&1; then
		docker volume create "$WS_VOLUME" >/dev/null
	fi
	# Seed the workspace volume so the entrypoint (running as node) can clone into
	# it. Two things are required:
	#   - chown it to node, and
	#   - leave it NON-EMPTY (a single placeholder file) WHEN IT WOULD OTHERWISE BE
	#     EMPTY. Docker re-initialises an EMPTY named volume from the image on every
	#     mount; because the workspace mounts at the nested /workspace/<slug> (a path
	#     absent from the image), that re-init recreates the volume root as root:root
	#     on the real run, clobbering this chown and leaving node unable to write the
	#     clone. Docker leaves a NON-empty volume untouched, so the placeholder makes
	#     the chown stick. seed-workspace.sh empties the dir again just before cloning.
	#     Only write it when the volume is empty: a REUSED instance (recreated for a
	#     non-reclone reason — a /ctx or Podman-device change, or the stopped
	#     container pruned while its agent-ws-* volume remains) already holds a .git
	#     checkout, which is non-empty (so the chown sticks without help) and which
	#     seed-workspace.sh's reuse path does NOT clean — writing the placeholder there
	#     would leave a stray untracked .powbox-ws-init in the agent's working tree.
	# --reclone is a one-shot, launcher-driven wipe: empty the workspace volume here
	# (the container was recreated above) so the entrypoint re-clones into a clean
	# dir; the now-empty volume then gets the placeholder below. The volume itself is
	# kept. Nothing persists the wipe, so a later restart of a named instance never
	# re-wipes the agent's work.
	WS_PREP_CMD='mkdir -p /mnt/workspace /mnt/containers /mnt/podman-imagestore && chown node:node /mnt/workspace /mnt/containers /mnt/podman-imagestore && { [ -n "$(ls -A /mnt/workspace 2>/dev/null)" ] || : > /mnt/workspace/.powbox-ws-init; }'
	if [ "$RECLONE" = true ]; then
		WS_PREP_CMD='find /mnt/workspace -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; '"$WS_PREP_CMD"
	fi
	docker compose "${COMPOSE_ARGS[@]}" run --rm --no-deps --user root --entrypoint /bin/sh \
		-v "${WS_VOLUME}:/mnt/workspace" \
		-v "${PODMAN_VOLUME}:/mnt/containers" \
		-v "agent-podman-imagestore:/mnt/podman-imagestore" \
		agent \
		-lc "$WS_PREP_CMD"
else
	docker compose "${COMPOSE_ARGS[@]}" run --rm --no-deps --user root --entrypoint /bin/sh \
		-v "${NM_VOLUME}:/mnt/node_modules" \
		-v "${WT_VOLUME}:/mnt/worktrees" \
		-v "${PODMAN_VOLUME}:/mnt/containers" \
		-v "agent-podman-imagestore:/mnt/podman-imagestore" \
		agent \
		-lc 'mkdir -p /mnt/node_modules /mnt/worktrees /mnt/containers /mnt/podman-imagestore && chown node:node /mnt/node_modules /mnt/worktrees /mnt/containers /mnt/podman-imagestore'
fi

RUN_ARGS=()
if [ "$DETACH" = true ]; then
	RUN_ARGS+=(-d)
elif [ "$VOLATILE" = true ] && [ "$PERSIST" != true ]; then
	RUN_ARGS+=(--rm)
fi

# Pass the host devices rootless Podman needs through to the agent, each in its
# own compose overlay (`docker compose run` has no --device flag, only `docker
# run` does, so a device must be declared in a compose file added to the -f chain):
#   compose.fuse.yml   -> /dev/fuse    (fuse-overlayfs overlay storage driver;
#                                       absence just falls back to the vfs driver)
#   compose.netdev.yml -> /dev/net/tun (slirp4netns/pasta nested networking;
#                                       absence breaks every default `podman run`)
# POWBOX_PODMAN gates both (POWBOX_FUSE is the deprecated alias):
#   on   -> force both. Use on Docker Desktop / WSL2, where the devices live in the
#          Docker VM and the launcher's host shell cannot see them to auto-detect.
#          If the Docker host cannot expose a forced device the run hard-fails —
#          intentional for callers who demand a working nested runtime.
#   off  -> neither (Podman still runs: vfs storage, networking only via
#          --network=host/none).
#   auto -> attach each device independently when the launcher's host shell can see
#          it (reliable where /dev is shared, e.g. native Linux / WSL; under-detects
#          on Docker Desktop — use `on` there). The two are detected separately so a
#          host exposing /dev/net/tun but not /dev/fuse still gets networking on vfs.
if [ -z "${POWBOX_PODMAN:-}" ] && [ -n "${POWBOX_FUSE:-}" ]; then
	echo "Note: POWBOX_FUSE is deprecated; use POWBOX_PODMAN (it now gates both /dev/fuse and /dev/net/tun)." >&2
fi
# Attach each compose overlay from the already-resolved PODMAN_DEVICE_MODE so the
# devices actually passed match the powbox.podman-devices label recorded below.
case ",${PODMAN_DEVICE_MODE}," in
*,fuse,*) COMPOSE_ARGS+=(-f "${ROOT_DIR}/compose.fuse.yml") ;;
esac
case ",${PODMAN_DEVICE_MODE}," in
*,tun,*) COMPOSE_ARGS+=(-f "${ROOT_DIR}/compose.netdev.yml") ;;
esac

# PRIMARY_AGENT selects which agent the unified image runs and seeds as primary.
# Both API keys flow through via compose.agent.yml so a delegated peer agent can
# authenticate too.
EXTRA_ENV=(-e "CONTAINER_NAME=$CONTAINER_NAME" -e "PRIMARY_AGENT=$AGENT" -e "PNPM_STORE_DIR=$WT_STORE_DIR")

# Self-hosted clone inputs. The entrypoint (after gh auth) clones POWBOX_CLONE_REPO
# at POWBOX_CLONE_REF into POWBOX_WORKSPACE_DIR, and skips the clone when a .git
# already exists (reuse — the agent owns its tree). These env vars are frozen at
# container creation; --reclone is NOT one of them on purpose — it is a one-shot
# launcher action (the prep step below empties the volume so the entrypoint clones
# fresh), so a reused container never re-wipes the agent's work on a later restart.
SELFHOSTED_LABEL=()
if [ "$ISOLATED" = true ]; then
	EXTRA_ENV+=(
		-e "POWBOX_SELF_HOSTED=1"
		-e "POWBOX_CLONE_REPO=$REPO_SPEC"
		-e "POWBOX_CLONE_REF=$CLONE_REF"
		-e "POWBOX_WORKSPACE_DIR=$WORKSPACE_MOUNT"
	)
	# Label self-hosted containers so tooling/lists can distinguish them from
	# dir-mounted ones (they already share the claude-/codex- name prefix). The
	# instance-name label stores the --name verbatim (as entered, pre-slugify) so
	# cc-list/agent-list can tell apart two names that slugify alike; repo + ref give
	# the list enough to reconstruct the exact resume command. ref records what was
	# REQUESTED at creation and is not re-applied on resume (see the --ref warning).
	SELFHOSTED_LABEL=(
		--label "powbox.self-hosted=true"
		--label "powbox.instance-name=${INSTANCE_NAME}"
		--label "powbox.repo=${REPO_SPEC}"
		--label "powbox.ref=${CLONE_REF}"
	)
fi

# In dir-mounted mode the root node_modules and .worktrees are separate per-project
# named volumes mounted over the bind mount. In self-hosted mode they are ordinary
# subdirs of the one workspace volume (mounted via compose.selfhosted.yml), so no
# extra -v args are added here.
WORKSPACE_VOL_ARGS=()
if [ "$ISOLATED" != true ]; then
	WORKSPACE_VOL_ARGS=(
		-v "${NM_VOLUME}:${WORKSPACE_MOUNT}/node_modules"
		-v "${WT_VOLUME}:${WORKSPACE_MOUNT}/.worktrees"
	)
fi

CONTINUE_LABEL="false"
if [ "$CONTINUE" = true ]; then
	CONTINUE_LABEL="true"
fi

# Seed the GLOBAL shared image store from a dedicated, short-lived, DETACHED
# writer — the ONLY container that mounts agent-podman-imagestore read-write. The
# agent container below mounts the same volume read-only, so a runaway process in
# one project can't poison the cache every other project resolves images from.
# Detached so the launch never blocks on pulls; idempotent and quick once
# populated (seed-image-store.sh skips images already present, and its flock
# serializes concurrent writers). Only meaningful on the overlay path — an
# additionalimagestores entry must match the consumer's driver, and consumers
# only enable overlay when /dev/fuse is present — so gate it on the resolved fuse
# device. Best-effort: a writer that can't start must never abort the agent launch.
case ",${PODMAN_DEVICE_MODE}," in
*,fuse,*)
	# Go straight to entrypoint-core.sh (firewall + XDG + the writer-role Podman
	# setup) instead of the default entrypoint-agent.sh, so the writer skips the
	# per-agent skill/config seeding and stays lean — it only needs egress and a
	# Podman that can pull. AGENT_CONFIG_DIR is required by core but unused here, so
	# point it at a throwaway path; AGENT_SETUP_HOOK is cleared so no agent hook runs.
	docker compose "${COMPOSE_ARGS[@]}" run --rm -d --no-deps \
		--entrypoint /usr/local/bin/entrypoint-core.sh \
		-e POWBOX_IMAGE_STORE_ROLE=writer \
		-e AGENT_CONFIG_DIR=/tmp/powbox-imgstore-writer \
		-e AGENT_SETUP_HOOK= \
		-v "agent-podman-imagestore:/mnt/podman-imagestore" \
		agent \
		seed-image-store.sh seed >/dev/null 2>&1 || true
	;;
esac

docker compose "${COMPOSE_ARGS[@]}" run "${RUN_ARGS[@]}" \
	--name "$CONTAINER_NAME" \
	--label "powbox.continue=${CONTINUE_LABEL}" \
	--label "powbox.podman-devices=${PODMAN_DEVICE_MODE}" \
	"${SELFHOSTED_LABEL[@]}" \
	"${EXTRA_ENV[@]}" \
	"${GIT_CONFIG_ARGS[@]}" \
	"${GH_CONFIG_ARGS[@]}" \
	"${CTX_ARGS[@]}" \
	"${WORKSPACE_VOL_ARGS[@]}" \
	-v "${PODMAN_VOLUME}:/home/node/.local/share/containers" \
	-v "agent-podman-imagestore:/mnt/podman-imagestore:ro" \
	-w "${WORKSPACE_MOUNT}" \
	agent \
	"${CMD[@]}"
