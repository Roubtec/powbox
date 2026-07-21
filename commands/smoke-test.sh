#!/usr/bin/env bash
set -euo pipefail

# The agent image is unified: both claude and codex (and codex's bwrap sandbox)
# are baked into the same image alongside the shared toolchain, so one smoke
# test validates everything in a single pass.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE="${1:-powbox-agent:latest}"

# The image-gated checks in stages 1–3 (and Stage 4's clone behavior) need the
# agent image; Stage 4's self-hosted identity contract runs without it. Detect
# the image once up front so a missing one is reported clearly here rather than
# as a raw docker error at Stage 1. POWBOX_SMOKE_REQUIRE_IMAGE=1 (used by CI)
# turns an absent image into a hard error before any stage runs; it is also
# exported so a sub-script invoked directly (e.g. the self-hosted clone stage)
# fails instead of self-skipping its image-gated checks into a false "all green".
# Track every stage we skip so the end-of-run banner can report a partial run.
skipped=()
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
	if [ -n "${POWBOX_SMOKE_REQUIRE_IMAGE:-}" ]; then
		echo "ERROR: image '$IMAGE' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set — refusing to run a partial (image-skipping) smoke test." >&2
		echo "       Build it first (./build.sh agent) or unset POWBOX_SMOKE_REQUIRE_IMAGE." >&2
		exit 1
	fi
	echo "WARNING: image '$IMAGE' not found — the image-gated stages need it. Stage 1 will fail and abort the run before any later stage (Stages 2–5) runs, so you get no partial coverage."
	echo "         Build it (./build.sh agent), or set POWBOX_SMOKE_REQUIRE_IMAGE=1 to fail fast here with a clear message instead of a raw docker error at Stage 1."
fi
export POWBOX_SMOKE_REQUIRE_IMAGE

# Stage 0 — sensitive-host-path predicate unit test. Hermetic (no image, root, or
# native-Linux host needed), so it runs unconditionally up front: it guards the predicate
# and the /proc/self/mountinfo source lookup that stop the workspace-perms heal from
# recursively chowning a mount whose host source is a system/home dir (the VPS-lockout
# incident — an accidental `cc`/`cx` from ~ re-owning the home tree and breaking sshd
# StrictModes on ~/.ssh). The live end-to-end guard is Stage 5's sensitive-skip /
# fix-mountinfo-backstop cases.
echo "Running sensitive-host-path predicate unit test ..."
"${ROOT_DIR}/scripts/test-sensitive-host-path.sh"

# Stage 0a — sensitive-host-path predicate unit test against the BAKED library. Stage 0
# above ran the test on the host against the /repo source checkout; this run points it at
# the base-layer copy at /usr/local/bin/sensitive-host-path.sh (via SENSITIVE_HOST_PATH_LIB)
# so it exercises the BAKED library that entrypoint-core.sh, fix-workspace-perms.sh, and
# heal-workspace-perms.sh actually source at runtime (they fall back to that path). Without
# it the smoke only ever validated the /repo source, so a stale or behaviorally broken baked
# copy in the base layer would slip through untested. Needs the agent image; when it is absent
# the host Stage 0 already covered the source, so this simply records a skip — no second host
# run, which would be redundant with Stage 0.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running sensitive-host-path predicate unit test (baked library in $IMAGE) ..."
	# Point LIB at the baked artifact so the in-image run validates the installed
	# /usr/local/bin/sensitive-host-path.sh containers source, not the mounted /repo source.
	docker run --rm -v "${ROOT_DIR}:/repo:ro" -e SENSITIVE_HOST_PATH_LIB=/usr/local/bin/sensitive-host-path.sh --entrypoint /bin/bash "$IMAGE" /repo/scripts/test-sensitive-host-path.sh
else
	echo "WARNING: skipping in-image sensitive-host-path baked-library test (Stage 0a) — image '$IMAGE' absent; Stage 0 already covered the /repo source on the host."
	skipped+=("Stage 0a: sensitive-host-path baked-library test (image absent)")
fi

# Stage 0b — gh-review-threads helper unit test. Hermetic (stubs `gh` with a PATH
# shim serving canned fixtures — no live GitHub or root needed), so like Stage 0 it
# runs up front. It guards the baked gh-review-threads helper (vendored in
# Roubtec/agent-skills, baked from the pinned clone): manual
# pagination (never `gh api graphql --paginate`, which under concurrent runs has
# returned another PR's threads) and the boundary-safe, repo-qualified PR-scope
# assertion that fails closed (exit 3) on a contaminated response.
#
# Prefer the IN-IMAGE run whenever the agent image is present: it exercises the BAKED
# /usr/local/bin/gh-review-threads on PATH — the artifact agents actually use — so a
# stale or behaviorally broken baked helper is caught here rather than waved through
# by Stage 1's `command -v` presence probe. Fall back to a host run against the source
# only when the image is absent. Since the helper is no longer kept in-tree — it is
# vendored in Roubtec/agent-skills and materialized into .agent-skills-src only by a
# `build.sh` fetch — that host path needs both the staged clone present AND `jq` (the
# helper and its test parse JSON), which a stock host may lack — the README
# prerequisites only require Docker/buildx, and a default macOS install has no jq. If
# neither the image nor a testable host source is available, record a skip.
STAGED_HELPER="${ROOT_DIR}/.agent-skills-src/plugins/dev-skills/bin/gh-review-threads"
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running gh-review-threads helper unit test (baked helper in $IMAGE) ..."
	# Point HELPER at the baked artifact so the in-image run validates the installed
	# /usr/local/bin/gh-review-threads on PATH, not the mounted /repo source checkout.
	docker run --rm -v "${ROOT_DIR}:/repo:ro" -e GH_REVIEW_THREADS_HELPER=/usr/local/bin/gh-review-threads --entrypoint /bin/bash "$IMAGE" /repo/scripts/test-gh-review-threads.sh
elif [ -x "$STAGED_HELPER" ] && command -v jq >/dev/null 2>&1; then
	echo "Running gh-review-threads helper unit test (host source from agent-skills clone — image '$IMAGE' absent) ..."
	"${ROOT_DIR}/scripts/test-gh-review-threads.sh"
else
	echo "WARNING: skipping gh-review-threads helper unit test (Stage 0b) — image '$IMAGE' absent and the host fallback is unavailable (it needs both the staged agent-skills helper and host 'jq')."
	skipped+=("Stage 0b: gh-review-threads helper unit test (image absent; host fallback needs the staged helper and jq)")
fi

# Stage 0c — worktree orphan-safety unit test. Hermetic (a throwaway git repo in a
# tmpdir; no image, root, or volume needed), so it runs up front on the host source.
# It guards the durable-worktree-metadata safety contract (task 017): a dir that is
# no longer a live worktree (e.g. a pre-durable-metadata leftover whose tmpfs
# .git/worktrees was lost) is reaped only when EMPTY and otherwise PRESERVED (moved
# to .worktrees/.orphaned/), so wt-bootstrap/wt-enter/wt-remove never delete the sole
# surviving copy of dirty work when metadata disappears.
echo "Running worktree orphan-safety unit test ..."
"${ROOT_DIR}/scripts/test-wt-orphan-safety.sh"

# Stage 0d — the same test against the BAKED helpers. Stage 0c ran the /repo source;
# this points POWBOX_WT_ENTER/POWBOX_WT_REMOVE/POWBOX_WT_COMMON at the agent-layer
# copies at /usr/local/bin so it exercises the installed wt-enter/wt-remove and the
# wt-common.sh they source (and their exec bits) — the artifacts agents actually run.
# Needs the agent image; when absent, Stage 0c already covered the source, so record a
# skip rather than re-run on the host.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running worktree orphan-safety unit test (baked helpers in $IMAGE) ..."
	docker run --rm -v "${ROOT_DIR}:/repo:ro" \
		-e POWBOX_WT_COMMON=/usr/local/bin/wt-common.sh \
		-e POWBOX_WT_ENTER=/usr/local/bin/wt-enter \
		-e POWBOX_WT_REMOVE=/usr/local/bin/wt-remove \
		--entrypoint /bin/bash "$IMAGE" /repo/scripts/test-wt-orphan-safety.sh
else
	echo "WARNING: skipping in-image worktree orphan-safety baked-helper test (Stage 0d) — image '$IMAGE' absent; Stage 0c already covered the /repo source on the host."
	skipped+=("Stage 0d: worktree orphan-safety baked-helper test (image absent)")
fi

# Stage 0e — Podman Compose exec-form health-check probe invariants (task 025).
# Hermetic guard for scripts/smoke-test-podman.sh's Compose health-check block: it
# parses the embedded fixture with yq and asserts the health check stays an EXEC-form
# CMD array (not CMD-SHELL), that the probe INSPECTS+classifies the wired translation
# (so a CMD->CMD-SHELL rewrite is a detected KNOWN-XFAIL, not a silent pass), that it
# drives the check and requires "healthy" while a never-succeeding negative control
# must be driven to exactly terminal "unhealthy" (not merely "not healthy"), that cleanup
# tears down the project + only the temp dir, and
# that the Bash/PowerShell probes stay in parity — the load-bearing bits that a plain
# edit could silently neuter. It validates the /repo SOURCE probe (smoke-test-podman.sh is a repo script,
# not a baked artifact), so a host run suffices — but it needs `yq`. Prefer the
# in-image run (yq is guaranteed in the agent image) when the image is present; else
# fall back to a host run only when `yq` is available, else record a skip.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running Podman Compose health-check probe unit test (in $IMAGE) ..."
	docker run --rm -v "${ROOT_DIR}:/repo:ro" --entrypoint /bin/bash "$IMAGE" /repo/scripts/test-podman-compose-healthcheck.sh
elif command -v yq >/dev/null 2>&1; then
	echo "Running Podman Compose health-check probe unit test (host source — image '$IMAGE' absent) ..."
	"${ROOT_DIR}/scripts/test-podman-compose-healthcheck.sh"
else
	echo "WARNING: skipping Podman Compose health-check probe unit test (Stage 0e) — image '$IMAGE' absent and host 'yq' is unavailable (needed to parse the embedded fixture)."
	skipped+=("Stage 0e: Podman Compose health-check probe unit test (image absent; host fallback needs yq)")
fi

# Stage 1 — tool presence + key image config: every expected CLI resolves and
# runs, and pnpm ships package-import-method=auto (not the old forced copy) so
# worktree installs can hardlink from a co-located store. The GOBIN probe
# plants a stub tool in ~/go/bin and runs it by bare name: these commands run
# under a login shell (`sh -lc`), which resets PATH from /etc/profile, so the
# probe passing proves the baked profile.d snippet restores $HOME/go/bin —
# the documented "`go install` and it's runnable" contract. The golangci-lint
# probes pin the cache-scoping wrapper contract: the PATH name resolves to the
# wrapper (real binary off PATH in /usr/local/libexec), a fixture worktree under
# .worktrees/<container>/<slug> gets its cache scoped to
# .worktrees/.golangci-cache/<container>/<slug>, the main checkout scopes to
# .root only in self-hosted mode when .worktrees is not a mountpoint (no host
# litter otherwise), and a caller-set GOLANGCI_LINT_CACHE always wins. The
# GOMODCACHE/GOCACHE probes prove go honors the plain env the launcher exports.
# The ccache probes prove the binary is baked, that it honors a CCACHE_DIR env
# (so the launcher's .worktrees/.ccache wiring lands) and — the functional check —
# that two identical `ccache gcc` compiles into a fresh cache produce a hit —
# direct or preprocessed, since either counter proves caching works — asserted via
# the machine-parsable `--print-stats` counters (stable since ccache 4.4; trixie
# bakes 4.11) instead of the version-dependent human-readable `-s` text.
# The opa probe goes past a bare version check: it writes a tiny Rego policy +
# test and runs `opa test`, exercising the exact `opa test policy/…` contract a
# policy-repo's CI runs (and that motivated baking opa in).
# shellcheck disable=SC2016  # the probes' $HOME expands in the container shell, NOT the host
"${ROOT_DIR}/scripts/smoke-test-image.sh" "$IMAGE" \
	"claude --version >/dev/null" \
	"codex --version >/dev/null" \
	"bwrap --version >/dev/null" \
	"gh --version >/dev/null" \
	"node --version >/dev/null" \
	"npm --version >/dev/null" \
	"pnpm --version >/dev/null" \
	"pnpm config get package-import-method | grep -qx auto" \
	"pip3 --version >/dev/null" \
	"python3 --version >/dev/null" \
	"sqlcmd -? >/dev/null" \
	"sqlite3 --version >/dev/null" \
	"psql --version >/dev/null" \
	"pg-dev-up check >/dev/null" \
	"command -v wt-bootstrap >/dev/null" \
	"command -v wt-enter >/dev/null" \
	"command -v wt-remove >/dev/null" \
	"[ -r /usr/local/bin/wt-common.sh ]" \
	"command -v powbox-provenance >/dev/null" \
	"command -v gitcat >/dev/null" \
	"command -v gh-review-threads >/dev/null" \
	"shellcheck --version >/dev/null" \
	"ping -V >/dev/null" \
	"nc -h >/dev/null 2>&1" \
	"bc --version >/dev/null" \
	"less --version >/dev/null" \
	"lsof -v >/dev/null 2>&1" \
	"tree --version >/dev/null" \
	"fd --version >/dev/null" \
	"fzf --version >/dev/null" \
	"bat --version >/dev/null" \
	"ssh -V >/dev/null 2>&1" \
	"rsync --version >/dev/null" \
	"strace -V >/dev/null" \
	"gpg --version >/dev/null" \
	"gcc --version >/dev/null" \
	"cmake --version >/dev/null" \
	"ninja --version >/dev/null" \
	"pkg-config --version >/dev/null" \
	"pkg-config --exists openssl zlib" \
	"ccache --version >/dev/null" \
	'CCACHE_DIR=/tmp/powbox-ccache-cfg-probe ccache --show-config | grep -q /tmp/powbox-ccache-cfg-probe' \
	'd=/tmp/powbox-ccache-fn-probe && rm -rf "$d" && mkdir -p "$d" && printf "int main(void){return 0;}\n" > "$d/t.c" && export CCACHE_DIR="$d/cache" && ccache -z >/dev/null && ccache gcc -c "$d/t.c" -o "$d/a.o" && ccache gcc -c "$d/t.c" -o "$d/b.o" && ccache --print-stats | grep -Eq "^(direct|preprocessed)_cache_hit[[:space:]]+[1-9]"' \
	"go version >/dev/null" \
	"command -v gofmt >/dev/null" \
	"golangci-lint version >/dev/null" \
	"readlink /usr/local/bin/golangci-lint | grep -q golangci-lint-wrapper" \
	"[ -x /usr/local/libexec/golangci-lint ]" \
	'GOMODCACHE=/tmp/powbox-gomod-probe go env GOMODCACHE | grep -qx /tmp/powbox-gomod-probe' \
	'GOCACHE=/tmp/powbox-gocache-probe go env GOCACHE | grep -qx /tmp/powbox-gocache-probe' \
	'GOLANGCI_LINT_CACHE=/tmp/powbox-golangci-custom golangci-lint cache status | grep -q "Dir: /tmp/powbox-golangci-custom"' \
	'mkdir -p /tmp/powbox-golangci-probe/repo && cd /tmp/powbox-golangci-probe/repo && git init -q && git -c user.email=smoke@powbox.local -c user.name=smoke commit -q --allow-empty -m init && git worktree add -q .worktrees/probe-cont/task-a -b probe-a' \
	'cd /tmp/powbox-golangci-probe/repo/.worktrees/probe-cont/task-a && golangci-lint cache status | grep -q "Dir: /tmp/powbox-golangci-probe/repo/.worktrees/.golangci-cache/probe-cont/task-a"' \
	'cd /tmp/powbox-golangci-probe/repo && golangci-lint cache status | grep -q "Dir: $HOME/.cache/golangci-lint"' \
	'cd /tmp/powbox-golangci-probe/repo && POWBOX_SELF_HOSTED=1 golangci-lint cache status | grep -q "Dir: /tmp/powbox-golangci-probe/repo/.worktrees/.golangci-cache/.root"' \
	'mkdir -p "$HOME/go/bin" && printf "%s\n" "#!/bin/sh" "echo gobin-ok" > "$HOME/go/bin/powbox-gobin-probe" && chmod +x "$HOME/go/bin/powbox-gobin-probe" && powbox-gobin-probe | grep -qx gobin-ok' \
	"opa version >/dev/null" \
	'p=/tmp/powbox-opa-probe && rm -rf "$p" && mkdir -p "$p" && printf "%s\n" "package smoke" "" "allow if { input.x == 1 }" > "$p/p.rego" && printf "%s\n" "package smoke" "" "test_allow if { allow with input as {\"x\": 1} }" > "$p/p_test.rego" && opa test "$p" | grep -q "PASS: 1/1"' \
	"file --version >/dev/null" \
	"printf test | xxd >/dev/null" \
	"envsubst --version >/dev/null" \
	"yq --version >/dev/null" \
	"shfmt --version >/dev/null" \
	"unzip -v >/dev/null" \
	"zip -v >/dev/null" \
	"wget --version >/dev/null" \
	"htop --version >/dev/null"

# Stage 2 — pg-dev-up functional test: stand up a real throwaway cluster and
# connect through the emitted DATABASE_URL. Unlike `pg-dev-up check` (binary
# presence only) this exercises role/db creation, URL percent-encoding, the
# 127.0.0.1 host binding, and the eval round-trip. Deliberately nasty
# credentials prove the SQL-quoting and URL-encoding paths. Skip the daemon
# bring-up with POWBOX_SMOKE_SKIP_DB=1 (Stage 3 below still runs unless
# POWBOX_SMOKE_SKIP_PODMAN is also set; set both for a Stage 1 presence-only run).
if [ -n "${POWBOX_SMOKE_SKIP_DB:-}" ]; then
	echo "Skipping pg-dev-up functional test (POWBOX_SMOKE_SKIP_DB is set)."
	skipped+=("Stage 2: pg-dev-up functional (POWBOX_SMOKE_SKIP_DB)")
else
	echo "Running pg-dev-up functional test against $IMAGE ..."
	docker run --rm \
		-e POSTGRES_USER=t \
		-e POSTGRES_PASSWORD='p@s/s&w#d' \
		-e POSTGRES_DB=app \
		--entrypoint /bin/sh "$IMAGE" -lc '
set -e
pg-dev-up up >/dev/null
url=$(pg-dev-up url)
echo "DATABASE_URL=$url"
printf %s "$url" | grep -qF "p%40s%2Fs%26w%23d" || { echo "FAIL: password not percent-encoded in URL" >&2; exit 1; }
printf %s "$url" | grep -qF "@127.0.0.1:" || { echo "FAIL: URL host is not 127.0.0.1" >&2; exit 1; }
eval "$(pg-dev-up url --export)"
out=$(psql "$DATABASE_URL" -tAc "SELECT current_user, current_database()")
echo "psql SELECT -> $out"
printf %s "$out" | grep -qxF "t|app" || { echo "FAIL: unexpected psql result: $out" >&2; exit 1; }
pg-dev-up down >/dev/null
'
	echo "pg-dev-up functional test passed."
fi

# Stage 3 — rootless Podman engine: the agent image bakes podman + a docker shim
# (docs/rootless-podman.md). This is the automated guard that follow-up asked for —
# a base/Podman bump that regresses the engine (a dropped containers.conf drop-in,
# a Podman without the `compose` subcommand, a nested run that no longer starts, or
# a Compose exec-form health check that no longer reaches healthy) is
# caught here. The helper runs the image with the launch-time device + security
# wiring the launcher normally supplies via the compose overlays. On a host that
# cannot expose /dev/net/tun it still validates the static engine wiring and skips
# only the nested-run checks; a genuinely broken image fails on any host. Skip the
# whole stage explicitly with POWBOX_SMOKE_SKIP_PODMAN=1; see
# scripts/smoke-test-podman.sh for what it covers.
if [ -n "${POWBOX_SMOKE_SKIP_PODMAN:-}" ]; then
	echo "Skipping Podman smoke test (POWBOX_SMOKE_SKIP_PODMAN is set)."
	skipped+=("Stage 3: rootless Podman engine (POWBOX_SMOKE_SKIP_PODMAN)")
else
	# smoke-test-podman.sh also treats POWBOX_PODMAN=off (deprecated alias
	# POWBOX_FUSE=off) as a whole-stage skip and exits 0 with its own notice; and
	# under auto (the default) on a host without /dev/net/tun it runs the static
	# engine checks but exits 0 after self-skipping the nested-run + published-port
	# checks (e.g. Docker Desktop / a hosted runner with no tun device). Mirror both
	# gates so the banner records the partial run instead of claiming all stages ran
	# — the child evaluates the same host /dev/net/tun condition before its docker
	# run, so the two agree. The child still prints the skip message; we track it here.
	podman_gate="${POWBOX_PODMAN:-${POWBOX_FUSE:-auto}}"
	# The child self-skips one nested scenario at RUNTIME — the distroless (shell-less)
	# Compose XFAIL reproduction, when its image cannot be pulled — which the parent
	# cannot predict. Hand it a marker (like Stages 5/6): the child writes the reason
	# there and we surface it in the banner so the partial coverage is not hidden.
	podman_marker="$(mktemp "${TMPDIR:-/tmp}/powbox-smoke-podman-skip.XXXXXX")"
	# Remove the marker even if the child smoke FAILS: under `set -e` a non-zero child
	# exit aborts this script before the rm below, so a plain trailing rm would leak the
	# temp file on failure. The trap fires on EXIT (success or failure); it is cleared
	# once the marker is consumed so later stages' EXIT handling is untouched.
	trap 'rm -f "$podman_marker"' EXIT
	POWBOX_SMOKE_SKIP_MARKER="$podman_marker" "${ROOT_DIR}/scripts/smoke-test-podman.sh" "$IMAGE"
	if [ "$podman_gate" = "off" ]; then
		skipped+=("Stage 3: rootless Podman engine (POWBOX_PODMAN=off)")
	elif [ "$podman_gate" != "on" ] && [ ! -e /dev/net/tun ]; then
		skipped+=("Stage 3: rootless Podman nested-run checks (no /dev/net/tun)")
	elif [ -s "$podman_marker" ]; then
		skipped+=("Stage 3: $(cat "$podman_marker")")
	fi
	rm -f "$podman_marker"
	trap - EXIT
fi

# Stage 4 - self-hosted ("--isolated") launch mode. Validates the launcher's
# self-hosted identity contract (always, no image needed) and the baked
# seed-workspace.sh clone/reuse/reclone/failure + single-mount hardlink behavior
# against the image (self-skips when the image is absent). Skip the whole stage
# with POWBOX_SMOKE_SKIP_SELFHOSTED=1; see scripts/smoke-test-selfhosted.sh.
if [ -n "${POWBOX_SMOKE_SKIP_SELFHOSTED:-}" ]; then
	echo "Skipping self-hosted smoke test (POWBOX_SMOKE_SKIP_SELFHOSTED is set)."
	skipped+=("Stage 4: self-hosted launch mode (POWBOX_SMOKE_SKIP_SELFHOSTED)")
else
	"${ROOT_DIR}/scripts/smoke-test-selfhosted.sh" "$IMAGE"
	# POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE=1 runs Stage A (launcher identity) but skips
	# Stage B (clone behavior) inside the child, which still exits 0. Record that
	# partial coverage so the banner does not claim all stages ran.
	if [ -n "${POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE:-}" ]; then
		skipped+=("Stage 4: self-hosted clone behavior (POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE)")
	fi
fi

# Stage 5 - native-Linux dir-mount ownership. A bind-mounted root-owned repo is
# root:root inside the container, which the node agent (uid 1000) cannot write;
# entrypoint-core.sh's write probe + the sudo-allowlisted fix-workspace-perms.sh
# helper (PR #55) chown it to node so git/edits work. This stage runs two cases: the
# all-root-owned mount (PR #55) and a mixed-ownership mount (task 007) — a node-owned
# root that hides nested root-owned files from a host `sudo git pull` that the helper's
# uid-0 re-own heals. BOTH cases (tasks 005a + 007a) drive the GENUINE extracted entrypoint
# decision unit heal-workspace-perms.sh — the byte-for-byte probe-and-call code
# entrypoint-core.sh runs — so they guard the probe/decision path (does the probe still detect
# the unwritable mount and hand it to the helper?), not only the helper; that unit still
# ultimately invokes fix-workspace-perms.sh by the same allowlisted path/sudo mechanism, so
# the in-isolation helper + sudoers coverage is preserved. The all-root case exercises the
# root-level write probe; the mixed case (node-owned root + nested uid-0 entries) exercises
# the nested-uid-0 DETECTION scan task 007 added that the root-level probe misses, so
# reverting ONLY that scan now fails the smoke (task 007a). Neither case boots the full
# entrypoint chain (firewall/gh/shadow need
# the launcher's compose wiring, out of scope here). It asserts node can
# write + git-commit each after the fix. It self-skips (exit 0) when the image is absent (honouring
# POWBOX_SMOKE_REQUIRE_IMAGE), when it cannot create a root-owned fixture (no root /
# passwordless sudo — the local-dev case; it runs for real on a CI runner), or when
# the host masks the native-Linux uid bug. Skip the whole stage with
# POWBOX_SMOKE_SKIP_DIRMOUNT=1; see scripts/smoke-test-dirmount.sh.
if [ -n "${POWBOX_SMOKE_SKIP_DIRMOUNT:-}" ]; then
	echo "Skipping dir-mount ownership smoke test (POWBOX_SMOKE_SKIP_DIRMOUNT is set)."
	skipped+=("Stage 5: dir-mount ownership (POWBOX_SMOKE_SKIP_DIRMOUNT)")
else
	# The child still exits 0 when it self-skips at runtime (non-Linux host, no
	# root/passwordless sudo, or a host that masks the uid bug), so its exit code
	# alone cannot distinguish a real pass from a skip. Hand it a marker file: it
	# records the skip reason there and we surface it in the banner below, so a
	# partial run is not reported as "all stages ran". An empty marker means the
	# stage actually ran.
	dirmount_marker="$(mktemp "${TMPDIR:-/tmp}/powbox-smoke-dirmount-skip.XXXXXX")"
	POWBOX_SMOKE_SKIP_MARKER="$dirmount_marker" "${ROOT_DIR}/scripts/smoke-test-dirmount.sh" "$IMAGE"
	if [ -s "$dirmount_marker" ]; then
		skipped+=("Stage 5: dir-mount ownership ($(cat "$dirmount_marker"))")
	fi
	rm -f "$dirmount_marker"
fi

# Stage 6 — durable worktree-metadata recreate lifecycle (task 017). The headline
# acceptance criterion: in dir-mounted mode a linked git worktree and its
# per-worktree admin metadata survive a container stop/recreate, because the
# metadata is bound from the persistent .worktrees volume over .git/worktrees rather
# than living in the tmpfs shadow that vanishes on recycle. It launches two
# throwaway containers on ONE named agent-wt-style volume: the first establishes the
# durable bind (via the real shadow-mounts.sh) and leaves a linked worktree DIRTY
# (tracked mod + untracked file); the second recreates on the same volume and
# asserts git status still works, the branch/HEAD is intact, both dirty changes
# survived, and the host checkout's real .git/worktrees gained no registrations.
# scripts/test-wt-orphan-safety.sh (Stage 0c/0d) only unit-tests the orphan-reaping
# SAFETY net, not this central bind/survive path, so this stage is what guards it.
# Needs the image AND a runtime that can grant the container CAP_SYS_ADMIN for the
# `mount --bind` — it self-skips (exit 0) when the image is absent (honouring
# POWBOX_SMOKE_REQUIRE_IMAGE) or the mount privilege is unavailable, running for real
# on native-Linux CI. Skip the whole stage with POWBOX_SMOKE_SKIP_WORKTREE_META=1;
# see scripts/smoke-test-worktree-metadata.sh.
if [ -n "${POWBOX_SMOKE_SKIP_WORKTREE_META:-}" ]; then
	echo "Skipping worktree durable-metadata smoke test (POWBOX_SMOKE_SKIP_WORKTREE_META is set)."
	skipped+=("Stage 6: worktree durable-metadata (POWBOX_SMOKE_SKIP_WORKTREE_META)")
else
	# Like Stage 5, the child exits 0 when it self-skips at runtime (image absent or
	# no mount privilege), so its exit code alone cannot distinguish a real pass from
	# a skip. Hand it the same marker mechanism and surface any skip in the banner.
	wtmeta_marker="$(mktemp "${TMPDIR:-/tmp}/powbox-smoke-wtmeta-skip.XXXXXX")"
	POWBOX_SMOKE_SKIP_MARKER="$wtmeta_marker" "${ROOT_DIR}/scripts/smoke-test-worktree-metadata.sh" "$IMAGE"
	if [ -s "$wtmeta_marker" ]; then
		skipped+=("Stage 6: worktree durable-metadata ($(cat "$wtmeta_marker"))")
	fi
	rm -f "$wtmeta_marker"
fi

if [ "${#skipped[@]}" -gt 0 ]; then
	echo
	echo "================ SMOKE TEST: STAGES SKIPPED ================"
	for s in "${skipped[@]}"; do
		echo "  - $s"
	done
	echo "This was a PARTIAL smoke test — the stages above did not run."
	echo "For a full run (e.g. in CI) unset the POWBOX_SMOKE_SKIP_* vars; set"
	echo "POWBOX_SMOKE_REQUIRE_IMAGE=1 to also fail on a missing image."
	echo "==========================================================="
else
	echo "Smoke test complete (all stages ran)."
fi
