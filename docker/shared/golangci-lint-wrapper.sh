#!/usr/bin/env bash
# golangci-lint wrapper — scope the analysis cache per worktree *before* the
# real linter can read a sibling's stale results.
#
# Why this exists
# ---------------
# golangci-lint keeps an analysis cache under ~/.cache/golangci-lint by
# default — one cache per HOME, shared by every checkout. With parallel task
# worktrees (address-tasks / address-reviews style runs under
# .worktrees/$CONTAINER_NAME/<slug>/), that shared cache bleeds analysis
# results across siblings: a run in one worktree can surface phantom findings
# caused by another worktree's tree state. CI systems avoid this by keying the
# cache on go.sum + config; here the fix is structural — give every worktree
# its own GOLANGCI_LINT_CACHE, derived at invocation time from the git
# toplevel of $PWD. (The Go module/build caches are NOT scoped like this:
# GOMODCACHE is content-addressed with its own locking and GOCACHE is
# concurrency-safe, so the launcher shares those across worktrees on purpose.)
#
# A wrapper (the pnpm-shadow-wrapper.sh precedent — this shim owns the PATH
# name, the real binary lives off PATH) is the only mechanism that covers every
# caller: wt-enter/wt-bootstrap only print paths and cannot export env into the
# shells that later run the linter, and a skill-prompt convention would leave
# manual shells unprotected.
#
# Cache layout (all under the persistent .worktrees mount, so caches also
# survive container recreation and never dirty a worktree's `git status`):
#   * worktree <root>/.worktrees/<container>/<slug>
#       -> <root>/.worktrees/.golangci-cache/<container>/<slug>
#     (nested under the container name to mirror the worktree layout, so slugs
#     never collide across a project's Claude/Codex containers; wt-remove
#     deletes the matching cache dir so nothing accumulates)
#   * the MAIN checkout, when its .worktrees is a mountpoint (the dir-mounted
#     worktrees volume) or a self-hosted workspace subdir
#       -> <root>/.worktrees/.golangci-cache/.root
#     (dot-prefixed on purpose: wt-enter forbids leading-dot slugs, so `.root`
#     can never collide with a real worktree slug)
#   * anything else (no .worktrees mount, not a git repo, derivation failure)
#       -> untouched default (~/.cache/golangci-lint)
#
# An explicit GOLANGCI_LINT_CACHE in the environment always wins — the wrapper
# only fills the gap. And it ALWAYS execs the real binary: no derivation or
# mkdir failure may ever block the actual lint command (the pnpm-wrapper
# principle) — on failure it just warns and runs with the default cache.
set -uo pipefail

# The real binary, extracted off PATH by docker/base/Dockerfile (the wrapper
# owns /usr/local/bin/golangci-lint). Exec'd by this absolute path, never by
# name — resolving `golangci-lint` again would recurse into this wrapper.
GOLANGCI_REAL="/usr/local/libexec/golangci-lint"

run_real() {
	if [ -x "$GOLANGCI_REAL" ]; then
		exec "$GOLANGCI_REAL" "$@"
	fi
	echo "golangci-lint-wrapper: real golangci-lint not found at $GOLANGCI_REAL" >&2
	exit 127
}

# Respect an explicit caller choice.
if [ -n "${GOLANGCI_LINT_CACHE:-}" ]; then
	run_real "$@"
fi

# Derive the checkout this invocation lints. Outside a git repo (or with git
# itself missing/broken) there is nothing to scope — run with the default.
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || TOP=""
if [ -z "$TOP" ]; then
	run_real "$@"
fi

CACHE=""
case "$TOP" in
*/.worktrees/*/*)
	# A task worktree: <mainroot>/.worktrees/<container>/<slug>. The %-strip
	# matches the LAST '/.worktrees/' (shortest suffix), so a project path that
	# itself contains '.worktrees' still resolves the right main root. REL is
	# 'container/slug' in the powbox convention; kept verbatim so even a
	# nonstandard deeper layout stays collision-free.
	MAINROOT="${TOP%/.worktrees/*}"
	REL="${TOP#"$MAINROOT"/.worktrees/}"
	CACHE="$MAINROOT/.worktrees/.golangci-cache/$REL"
	;;
*)
	# A main checkout: scope into its .worktrees only when that dir is really
	# the container-local persistent mount — a mountpoint (the dir-mounted
	# agent-wt-* volume, or a tmpfs shadow), or any subdir in self-hosted mode
	# (the whole workspace is one container-local volume, so .worktrees is a
	# plain dir there). A missing mountpoint(1) degrades to trusting the dir
	# (pnpm-wrapper style). Otherwise — no .worktrees at all, or a bare host
	# dir that came through the bind mount — leave the default cache so the
	# wrapper never litters cache files onto the host.
	WTDIR="$TOP/.worktrees"
	if [ -d "$WTDIR" ]; then
		if [ "${POWBOX_SELF_HOSTED:-}" = "1" ] ||
			! command -v mountpoint >/dev/null 2>&1 ||
			mountpoint -q "$WTDIR" 2>/dev/null; then
			CACHE="$WTDIR/.golangci-cache/.root"
		fi
	fi
	;;
esac

if [ -n "$CACHE" ]; then
	if mkdir -p "$CACHE" 2>/dev/null; then
		export GOLANGCI_LINT_CACHE="$CACHE"
	else
		echo "golangci-lint-wrapper: warning: cannot create cache dir $CACHE; running with the default cache." >&2
	fi
fi

run_real "$@"
