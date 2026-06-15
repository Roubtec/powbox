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
#   POWBOX_CLONE_REF     optional branch/tag/commit to start on (default: the repo
#                        default). Applied as a post-clone checkout, NOT `clone
#                        --branch`, so it accepts a raw commit SHA too and a ref that
#                        cannot be resolved degrades to "stay on the default branch
#                        with a warning" instead of failing the whole clone.
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
		# owner/repo slug → canonical HTTPS clone URL. Trim any trailing slashes
		# FIRST — a copied spec like owner/repo/ or owner/repo.git/ would otherwise
		# yield the invalid https://github.com/owner/repo/.git (the .git strip below
		# can't match a trailing-slash value either). Matches the launchers' trailing-
		# slash trim for identity reuse, so the same spec reattaches AND clones.
		# Then strip a trailing .git of ANY case — POSIX ${spec%.git} is
		# case-sensitive, so a slug like owner/repo.GIT would otherwise yield the
		# invalid .GIT.git. Matches the launchers' case-insensitive .git handling
		# (the launcher passes the raw, un-normalised spec as POWBOX_CLONE_REPO).
		while [ "${spec%/}" != "$spec" ]; do spec="${spec%/}"; done
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

# Clone the repo's DEFAULT branch unconditionally; an optional --ref is applied as a
# post-clone checkout below. This deliberately does NOT use `git clone --branch "$REF"`:
# that form rejects a raw commit SHA (only a branch/tag name), and it couples clone
# success to ref validity — a typo'd ref would abort the whole clone and drop the
# container to a plain shell. A full clone already fetches every branch and tag plus
# all reachable commits, so the post-clone checkout resolves a branch, tag, OR SHA
# uniformly, and a bad ref degrades to a benign warning (the working tree is still a
# valid default-branch checkout).
#
# Capture git's own exit status: after a completed `if git …; then …; fi` the value of
# $? is the if-statement's (0), not the failed clone's, so a failure would otherwise be
# reported as "exit 0". `|| clone_rc=$?` also keeps set -e from aborting before the loud
# announcement runs.
#
# GIT_TERMINAL_PROMPT=0 forces a missing/expired credential to FAIL rather than block: a
# self-hosted launch runs with a TTY, so a private clone reaching here without gh auth
# would otherwise hang on git's interactive username/password prompt — clone_rc never
# gets set, and the loud failure banner + plain-shell fallback below never run. Disabling
# the prompt routes that auth failure straight to announce_failure (git-scm.com documents
# this for HTTP auth terminal prompts).
clone_rc=0
GIT_TERMINAL_PROMPT=0 git clone "$URL" "$WS" || clone_rc=$?
if [ "$clone_rc" -ne 0 ]; then
	echo "seed-workspace: clone FAILED (exit $clone_rc)." >&2
	announce_failure "$URL"
	exit 1
fi
echo "seed-workspace: clone complete." >&2

# Optional starting ref. A resolved `git checkout` selects a branch (onto a local tracking
# branch, matching the old --branch behaviour), a tag, or a commit SHA (detached HEAD) from
# the objects the full clone already holds. A failure here is BENIGN by design — the tree is
# a valid default-branch checkout — so warn loudly and continue rather than dropping to the
# failure banner: the agent/user is told to confirm the ref before starting work (a
# self-hosted launch then typically cuts its own task branch anyway).
#
# Resolve the ref to a commit FIRST, then check it out via a form that can NEVER be taken as
# a pathspec. A bare `git checkout "$REF"` is ambiguous: a typo that happens to name a tracked
# PATH (e.g. "README", "docs") is taken as a path checkout — it exits 0, silently leaves the
# tree on the default branch, and we'd report success, defeating the very warning below.
# `git rev-parse --verify "<ref>^{commit}"` succeeds only for a name that resolves to a commit
# and never for a pathspec, so a path-only typo falls through to the warning; peeling to
# ^{commit} also rejects a non-commit object (a blob/tree SHA) that a bare checkout would itself
# refuse.
#
# But check BOTH the bare name AND the remote-tracking form: a fresh `git clone` only
# materializes a local head for the DEFAULT branch, so a non-default branch like `dev` exists
# only as refs/remotes/origin/dev. `git rev-parse dev` does NOT DWIM that (it checks
# refs/remotes/dev, not .../origin/dev). The default branch, tags, and SHAs resolve via the bare
# form; non-default branches resolve via the origin/ form; a path matches neither.
#
# The resolution alone is not enough — the checkout itself must also be path-immune. When the
# requested branch name ALSO exists as a tracked path (e.g. branch `docs` AND a `docs/` dir, or
# branch `README` AND a `README` file), a bare `git checkout "$REF"` aborts with "could be both
# a local file and a tracking branch" and strands the tree on the default branch even though the
# branch genuinely exists. So dispatch on WHICH form resolved and use an explicit, unambiguous
# checkout for each:
#   - bare name resolved (default branch / tag / SHA) → `git checkout "$REF" --`; the trailing
#     `--` forces ref interpretation so a same-named path can't hijack it (branch → switch,
#     tag/SHA → detached HEAD).
#   - only the origin/ form resolved (non-default branch) → `git checkout -b "$REF" --track
#     refs/remotes/origin/$REF`; an explicit start-point is never a pathspec and recreates the
#     local tracking branch the old `git clone --branch "$REF"` produced.
if [ -n "$REF" ]; then
	if { git -C "$WS" rev-parse --verify --quiet "${REF}^{commit}" >/dev/null 2>&1 &&
		git -C "$WS" checkout "$REF" --; } ||
		{ git -C "$WS" rev-parse --verify --quiet "refs/remotes/origin/${REF}^{commit}" >/dev/null 2>&1 &&
			git -C "$WS" checkout -b "$REF" --track "refs/remotes/origin/${REF}"; }; then
		echo "seed-workspace: checked out ref '$REF'." >&2
	else
		cat >&2 <<EOF

================================================================================
  POWBOX --ref WARNING: could not check out '$REF'
================================================================================
  The clone succeeded, so the workspace is on the repository's DEFAULT branch
  instead of the ref you asked for. Confirm where you are before starting work:

      git -C "$WS" status -sb

  (A --ref is applied only on the FIRST clone; pass a valid branch, tag, or
  commit SHA, or just check out what you need now that the repo is cloned.)
================================================================================

EOF
	fi
fi
exit 0
