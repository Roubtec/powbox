#!/usr/bin/env bash
# seed-workspace.sh — clone the repo into the per-instance workspace volume for
# self-hosted ("--isolated") launches.
#
# In self-hosted mode the launcher mounts an EMPTY per-instance named volume at the
# workspace path instead of bind-mounting a host directory; this script makes the
# container fetch the repo into it ITSELF. entrypoint-core.sh calls it AFTER gh auth
# is established (so a private clone has credentials) and BEFORE the shadow/pnpm
# steps. The egress model is push / PR — the host never sees the working tree.
#
# Inputs (env, set by the launcher at container creation; frozen for the container's
# life):
#   POWBOX_SELF_HOSTED   "1" enables this script; anything else is a no-op (exit 0)
#   POWBOX_CLONE_REPO    repo spec — an owner/repo slug or a clone URL (required)
#   POWBOX_CLONE_REF     optional branch/tag to start on (default: the repo default)
#   POWBOX_WORKSPACE_DIR target dir (the workspace mount); defaults to $PWD
#
# Reuse semantics: clone once when the workspace has no .git; on a restart of a
# named container an existing .git means the agent already owns its branches/
# worktrees, so the tree is left exactly as it was (skip). This must NOT carry any
# "always re-clone" flag, or a reused container would wipe the agent's work on
# every restart. The `--reclone` escape hatch is therefore handled launcher-side as
# a ONE-SHOT: the launcher empties the (kept) workspace volume before recreating the
# container, so this script then sees an empty dir and clones fresh.
#
# By DESIGN there is no clone/auth failsafe and no retry: gh auth is a one-time
# manual setup that holds until the token expires. On any clone failure this prints
# a loud, unmissable announcement of the three remedies and exits non-zero;
# entrypoint-core.sh then drops to a plain zsh rather than execing the agent into an
# empty workspace. The fix is done once and never again until the token expires.
set -euo pipefail

# Not self-hosted → nothing to do. Lets entrypoint-core call this unconditionally.
[ "${POWBOX_SELF_HOSTED:-}" = "1" ] || exit 0

WS="${POWBOX_WORKSPACE_DIR:-$PWD}"
REPO="${POWBOX_CLONE_REPO:-}"
REF="${POWBOX_CLONE_REF:-}"

# Resolve a clone URL from an owner/repo slug or a full URL, for display + cloning.
clone_url() {
	local spec="$1" rest
	case "$spec" in
	# Normalise any GitHub ssh:// URL to HTTPS so the in-container gh credential helper
	# authenticates it: the container has no SSH keys, and entrypoint-core.sh's insteadOf
	# rewrite covers only the unported ssh://git@github.com/ and scp git@github.com:
	# prefixes. Match the host with or without the `git@` user AND with or without an
	# explicit :port (e.g. ssh://git@github.com:22/owner/repo.git — the port form git
	# emits for a custom-SSH-port origin, which a prefix insteadOf rewrite cannot fix
	# because the :port would land in the path). The matched host is always github.com,
	# so the path is simply everything after the authority's first '/'. Non-GitHub ssh://
	# hosts fall through to the pass-through below (we only hold gh auth for github.com).
	ssh://git@github.com/* | ssh://github.com/* | ssh://git@github.com:*/* | ssh://github.com:*/*)
		rest="${spec#ssh://}"                       # drop scheme → [git@]github.com[:port]/path
		printf 'https://github.com/%s' "${rest#*/}" # path = everything after authority's first '/'
		;;
	# Normalise a GitHub scp-style remote (git@github.com:owner/repo[.git]) to HTTPS
	# for the same reason as the ssh:// cases above: the container has no SSH keys, and
	# entrypoint-core.sh's git@github.com: insteadOf rewrite is installed ONLY after
	# `gh auth status` succeeds — so a public-repo clone with no gh auth (the common
	# scp-origin case inferred from a local checkout) would otherwise fail on the bare
	# git@ URL. The scp form is host:path (a colon, not a slash) after git@github.com;
	# strip that prefix and prepend https://github.com/. Other git@host: remotes fall
	# through to the pass-through below (we hold gh auth only for github.com). Must
	# precede the git@* catch-all, which would otherwise swallow this.
	git@github.com:*) printf 'https://github.com/%s' "${spec#git@github.com:}" ;;
	*://* | git@*) printf '%s' "$spec" ;;
	*)
		# owner/repo slug → canonical HTTPS clone URL. Strip a trailing .git of ANY
		# case first — POSIX ${spec%.git} is case-sensitive, so a slug like
		# owner/repo.GIT would otherwise yield the invalid .GIT.git. Matches the
		# launchers' case-insensitive .git handling (the launcher passes the raw,
		# un-normalised spec as POWBOX_CLONE_REPO).
		case "$spec" in
		*.[Gg][Ii][Tt]) spec="${spec%.???}" ;;
		esac
		printf 'https://github.com/%s.git' "$spec"
		;;
	esac
}

# Strip any userinfo (user[:secret]@) from a URL so an embedded credential — e.g.
# https://<token>@github.com/owner/repo.git — never leaks into logs or terminal
# scrollback. Specs with no scheme (owner/repo slugs, scp-style git@host:path)
# carry no secret userinfo and pass through unchanged.
redact_url() {
	printf '%s' "$1" | sed -E 's#(://)[^/]*@#\1#'
}

announce_failure() {
	local url repo_safe
	url="$(redact_url "$1")"
	repo_safe="$(redact_url "${REPO:-}")"
	cat >&2 <<EOF

================================================================================
  POWBOX SELF-HOSTED CLONE FAILED
================================================================================
  Could not clone the repository into this container's private workspace:

      repo:   ${repo_safe:-(unset)}
      url:    ${url}
      target: ${WS}

  This is almost always because GitHub CLI (gh) is not authenticated in the
  shared agent-gh-config volume, so a private clone has no credentials.

  No agent was started. You are now in a plain shell. Pick ONE remedy:

    1. Use NORMAL (dir-mounted) mode instead — drop --isolated and launch
       against a host checkout.

    2. Fix it ONCE, here, in this shell:
           gh auth login
       then exit and relaunch the same --isolated command (it clones again).

    3. Seed the shared agent-gh-config volume from a machine that is already
       authenticated.

  gh auth is a one-time setup that holds until the token expires; there is no
  retry loop by design.
================================================================================

EOF
}

URL="$(clone_url "$REPO")"

if [ -z "$REPO" ]; then
	echo "seed-workspace: POWBOX_SELF_HOSTED=1 but POWBOX_CLONE_REPO is empty." >&2
	announce_failure "$URL"
	exit 1
fi

mkdir -p "$WS"

# Reuse: an existing checkout is left exactly as the agent left it. (A --reclone
# launch empties the volume launcher-side, so this branch is not taken then.)
if [ -e "$WS/.git" ]; then
	echo "seed-workspace: existing checkout in $WS — reusing it (skipping clone)." >&2
	exit 0
fi

# The launcher pre-seeds a fresh per-instance volume with a placeholder file so
# Docker keeps the volume root node-owned (an EMPTY volume mounted at the nested
# /workspace/<slug> is re-initialised root-owned, which would block this clone).
# Empty the workspace so `git clone` sees a clean target: the reuse check above
# already returned for a real checkout, so anything left here is that placeholder
# (or a failed partial clone) and is safe to clear.
find "$WS" -mindepth 1 -delete 2>/dev/null || true

echo "seed-workspace: cloning $(redact_url "$URL") into $WS ..." >&2
clone_args=(clone)
[ -n "$REF" ] && clone_args+=(--branch "$REF")
clone_args+=("$URL" "$WS")

# Capture git's own exit status: after a completed `if git …; then …; fi` the
# value of $? is the if-statement's (0), not the failed clone's, so a failure
# would otherwise be reported as "exit 0". `|| clone_rc=$?` also keeps set -e
# from aborting before the loud announcement runs.
#
# GIT_TERMINAL_PROMPT=0 forces a missing/expired credential to FAIL rather than
# block: a self-hosted launch runs with a TTY, so a private clone reaching here
# without gh auth would otherwise hang on git's interactive username/password
# prompt — clone_rc never gets set, and the loud failure banner + plain-shell
# fallback below never run. Disabling the prompt routes that auth failure straight
# to announce_failure (git-scm.com documents this for HTTP auth terminal prompts).
clone_rc=0
GIT_TERMINAL_PROMPT=0 git "${clone_args[@]}" || clone_rc=$?
if [ "$clone_rc" -eq 0 ]; then
	echo "seed-workspace: clone complete." >&2
	exit 0
fi

echo "seed-workspace: clone FAILED (exit $clone_rc)." >&2
announce_failure "$URL"
exit 1
