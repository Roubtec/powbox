#!/usr/bin/env bash
# golangci-lint wrapper — scope the analysis cache and the run lock per
# worktree *before* the real linter can read a sibling's stale results or
# collide with a sibling's run.
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
# Run lock: `golangci-lint run` refuses to start while another run holds an
# exclusive flock on golangci-lint.lock in os.TempDir() — $TMPDIR, else /tmp —
# giving up after 5s with exit 3 "parallel golangci-lint is running" (observed
# on v2.12.2 with strace). With TMPDIR unset that is ONE lock for the whole
# container, so parallel worktrees failed each other's lint. The wrapper
# re-roots TMPDIR at a per-toplevel subdir of the same temp root:
#       ${TMPDIR:-/tmp}/golangci-lint-<euid><toplevel>
# so runs on one tree still exclude each other, as the linter intends, while
# different toplevels never meet. It applies to every git toplevel, main
# checkout included, since nothing lands on the host mount. The guard is kept
# rather than passing --allow-parallel-runners, which would drop it on one
# tree too. TMPDIR is the lock's only knob, so the exported value also reaches
# the linter's children (go list's go-build work dirs); those are ephemeral
# and stay on the caller's temp filesystem.
#
# The lock is keyed by toplevel, independently of the cache scoping above, so
# toplevels that share a cache run concurrently against it: worktrees outside
# .worktrees/<container>/<slug> (e.g. .claude/worktrees/<name>, or
# `git worktree add ../x`), main checkouts without a .worktrees mount (all of
# these share the default cache), and runs that export one GOLANGCI_LINT_CACHE.
# That is safe: the cache is a copy of cmd/go's (internal/go/cache), whose
# Open documents that processes on one machine "will coordinate using
# operating system file locks and may duplicate effort but will not corrupt
# the cache". Keying the lock on the cache instead would bring the collision
# back for exactly those harness-native worktrees.
#
# A caller's TMPDIR is deliberately NOT passed through verbatim: the scope dir
# is nested inside it. TMPDIR is a general temp-root variable that shells and
# harnesses export for reasons unrelated to lint, so passing it through would
# silently restore the shared lock for every such shell. The caller's value
# still picks the temp root, and the guard's own settings
# (--allow-parallel-runners/--allow-serial-runners, run.allow-*-runners in the
# project config) win untouched: the wrapper never adds flags. To run with
# TMPDIR exactly as given, invoke the real binary at $GOLANGCI_REAL.
#
# An explicit GOLANGCI_LINT_CACHE in the environment always wins — the wrapper
# only fills the gap. And it ALWAYS execs the real binary: no derivation or
# mkdir failure may ever block the actual lint command (the pnpm-wrapper
# principle) — on failure it just warns and runs with the default.
set -uo pipefail

# The real binary, extracted off PATH by docker/layers/full/Dockerfile (the
# wrapper owns /usr/local/bin/golangci-lint). Exec'd by this absolute path,
# never by name — resolving `golangci-lint` again would recurse into this
# wrapper.
GOLANGCI_REAL="/usr/local/libexec/golangci-lint"

run_real() {
	if [ -x "$GOLANGCI_REAL" ]; then
		exec "$GOLANGCI_REAL" "$@"
	fi
	echo "golangci-lint-wrapper: real golangci-lint not found at $GOLANGCI_REAL" >&2
	exit 127
}

# Derive the checkout this invocation lints. Outside a git repo (or with git
# itself missing/broken) there is nothing to scope — run with the defaults.
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || TOP=""
if [ -z "$TOP" ]; then
	run_real "$@"
fi

# Run lock (see the header). The 0700 per-euid base keeps another user's
# pre-created dir in a shared /tmp from being trusted.
LOCKBASE="${TMPDIR:-/tmp}"
LOCKBASE="${LOCKBASE%/}/golangci-lint-$EUID"
LOCKDIR="$LOCKBASE$TOP"
mkdir -m 700 "$LOCKBASE" 2>/dev/null
if [ -O "$LOCKBASE" ] && mkdir -p "$LOCKDIR" 2>/dev/null && [ -w "$LOCKDIR" ]; then
	export TMPDIR="$LOCKDIR"
else
	echo "golangci-lint-wrapper: warning: cannot create lock dir $LOCKDIR; running with the shared run lock." >&2
fi

# Respect an explicit caller cache choice.
if [ -n "${GOLANGCI_LINT_CACHE:-}" ]; then
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
