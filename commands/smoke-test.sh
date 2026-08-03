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
# not a baked artifact), so a host run suffices — but it needs the jq-backed
# `yq -r <filter>` interface (python-yq). Prefer the in-image run (that yq is
# guaranteed in the agent image) when the image is present; else fall back to a host
# run only when the test's own `--check-yq` capability probe passes — not a bare
# `command -v yq`, because an incompatible host implementation (e.g. mikefarah's Go
# yq v3) would fail the smoke spuriously instead of recording a skip — else skip.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running Podman Compose health-check probe unit test (in $IMAGE) ..."
	docker run --rm -v "${ROOT_DIR}:/repo:ro" --entrypoint /bin/bash "$IMAGE" /repo/scripts/test-podman-compose-healthcheck.sh
elif "${ROOT_DIR}/scripts/test-podman-compose-healthcheck.sh" --check-yq >/dev/null 2>&1; then
	echo "Running Podman Compose health-check probe unit test (host source — image '$IMAGE' absent) ..."
	"${ROOT_DIR}/scripts/test-podman-compose-healthcheck.sh"
else
	echo "WARNING: skipping Podman Compose health-check probe unit test (Stage 0e) — image '$IMAGE' absent and no compatible host 'yq' (the jq-backed 'yq -r <filter>' interface is needed to parse the embedded fixture)."
	skipped+=("Stage 0e: Podman Compose health-check probe unit test (image absent; host fallback needs a compatible jq-backed yq)")
fi

# Stage 0f — peer-review-run unit test. Hermetic (fake `claude`/`codex` binaries on
# a per-case PATH — no real providers, image, or network), so it runs up front like
# the others. It guards the bidirectional peer-review runner's contract: the versioned
# result schema, both provider directions, read-only permission flags, literal
# stdin-fed prompts, Codex progress forwarding, the six normalized outcomes, timeout
# with process-tree reaping, and retry-once. The host-source run is gated to LINUX
# hosts with jq: beyond bash + jq, the helper and test lean on a Linux userland —
# /proc/<pid>/stat, `pgrep -P`, GNU `realpath -m`, `date +%N`, plus ps/timeout/
# find/awk/sed/stat — so on macOS or another non-Linux host it is skipped and the
# test runs only inside the (Linux) image below. When the image is present the test
# also runs against the BAKED /usr/local/bin/peer-review-run so a stale installed
# helper is caught here rather than waved through by Stage 1's `command -v`
# presence probe.
stage0f_host_ran=0
if [ "$(uname -s)" = Linux ] && command -v jq >/dev/null 2>&1; then
	echo "Running peer-review-run unit test (host /repo source) ..."
	"${ROOT_DIR}/scripts/test-peer-review-run.sh"
	stage0f_host_ran=1
elif [ "$(uname -s)" != Linux ]; then
	echo "WARNING: skipping peer-review-run host unit test (Stage 0f) — non-Linux host (the test needs a Linux userland: /proc, pgrep -P, GNU realpath -m, date +%N); the in-image run covers it when the image is present."
	skipped+=("Stage 0f: peer-review-run host unit test (non-Linux host)")
else
	echo "WARNING: skipping peer-review-run host unit test (Stage 0f) — host 'jq' unavailable."
	skipped+=("Stage 0f: peer-review-run host unit test (host jq unavailable)")
fi
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running peer-review-run unit test (baked helper in $IMAGE) ..."
	# --init matters here: the test's reap assertions probe killed descendants
	# with `kill -0`, which still succeeds on an un-collected ZOMBIE. Without an
	# init, bash would be PID 1 and orphans KILLed after their parent died can
	# linger as zombies, failing the reap checks even though the helper
	# terminated them. The powbox runtime always provides a reaping PID 1
	# (`init: true` in compose.shared.yml → docker-init), so the test container
	# must match that assumption.
	docker run --rm --init -v "${ROOT_DIR}:/repo:ro" \
		-e PEER_REVIEW_RUN=/usr/local/bin/peer-review-run \
		--entrypoint /bin/bash "$IMAGE" /repo/scripts/test-peer-review-run.sh
elif [ "$stage0f_host_ran" = 1 ]; then
	echo "WARNING: skipping in-image peer-review-run baked-helper test (Stage 0f) — image '$IMAGE' absent; the host run already covered the /repo source."
	skipped+=("Stage 0f: peer-review-run baked-helper test (image absent)")
else
	echo "WARNING: skipping in-image peer-review-run baked-helper test (Stage 0f) — image '$IMAGE' absent, and the host run was skipped too (see above), so the peer-review-run test did not run at all."
	skipped+=("Stage 0f: peer-review-run baked-helper test (image absent; host run also skipped — no coverage)")
fi

# Stage 0g — detect-shadows unit suite (task 053). Hermetic (throwaway repos in a
# tmpdir; no image-internal state, root, or Docker daemon needed by the test
# itself). It is the repo's largest pure-shell suite and the only regression net
# for docker/shared/detect-shadows.sh's load-bearing security properties: the
# under-workspace-root validation, the symlink skip, the Git-tracked-content veto
# and its fail-closed paths, the newline rejection, and the workspace-glob
# containment — every one of which was verified to fail against the pre-fix script.
#
# The suite needs git, jq, and a JQ-BACKED yq — python-yq, since detect-shadows.sh
# issues jq filters like `.shadow[]? // empty`, which mikefarah's Go yq rejects
# outright. The agent image guarantees that toolchain and an arbitrary host does
# not, so prefer the in-image run; fall back to the host only when the suite's own
# `--check-deps` capability probe passes — not a bare `command -v yq`, because the
# WRONG yq implementation would then turn 22 assertions red instead of recording an
# honest skip — else skip.
#
# That toolchain probe is necessary but NOT sufficient: like Stage 0f/0h, the host
# fallback is additionally gated on a LINUX host, because the CODE UNDER TEST needs a
# GNU userland that `--check-deps` cannot speak for. detect-shadows.sh calls GNU-only
# `realpath -m --` and drives its .NET artifact scan through `find -H … -printf '%h\0'
# | sort -zu` — neither `realpath -m` nor `find -printf`/`sort -z` exists on BSD/macOS.
# Without the gate, a macOS host that happens to have git, jq and python-yq installed
# passes `--check-deps` and then fails the whole smoke on a toolchain difference,
# instead of recording the honest skip this stage intends. The two skips are kept
# distinct so the banner says which one actually applies.
#
# The in-image run points the suite at the BAKED /usr/local/bin copies (via
# POWBOX_DETECT_SHADOWS / POWBOX_PNPM_SHADOW_DOCTOR, the shape Stage 0c/0d uses for
# the wt-* helpers), so a STALE baked detect-shadows.sh is caught by a real suite
# instead of being waved through by Stage 1's `command -v` presence probe. The /repo
# SOURCE is covered by the host fallback below and, on every PR, by Tier 0 CI
# (.github/workflows/native-linux-ci.yml), which runs the suite unset.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running detect-shadows unit suite (baked scripts in $IMAGE) ..."
	docker run --rm -v "${ROOT_DIR}:/repo:ro" \
		-e POWBOX_DETECT_SHADOWS=/usr/local/bin/detect-shadows.sh \
		-e POWBOX_PNPM_SHADOW_DOCTOR=/usr/local/bin/pnpm-shadow-doctor \
		--entrypoint /bin/bash "$IMAGE" /repo/scripts/test-detect-shadows.sh
elif [ "$(uname -s)" != Linux ]; then
	echo "WARNING: skipping detect-shadows unit suite (Stage 0g) — image '$IMAGE' absent and this is a non-Linux host (detect-shadows.sh itself calls GNU-only 'realpath -m' and 'find -printf'/'sort -z', which BSD/macOS reject)."
	skipped+=("Stage 0g: detect-shadows unit suite (image absent; host fallback needs a GNU/Linux userland)")
elif "${ROOT_DIR}/scripts/test-detect-shadows.sh" --check-deps >/dev/null 2>&1; then
	echo "Running detect-shadows unit suite (host source — image '$IMAGE' absent) ..."
	"${ROOT_DIR}/scripts/test-detect-shadows.sh"
else
	echo "WARNING: skipping detect-shadows unit suite (Stage 0g) — image '$IMAGE' absent and the host toolchain is unusable (it needs git, jq, and the jq-backed python-yq; mikefarah's Go yq cannot parse the filters detect-shadows.sh issues)."
	skipped+=("Stage 0g: detect-shadows unit suite (image absent; host fallback needs git, jq and a jq-backed yq)")
fi

# Stage 0h — shadow-mounts mountpoint-ownership unit test (task 053). Fully
# hermetic: it copies docker/shared/shadow-mounts.sh with its /workspace literal
# relocated into a tmpdir and PATH-shims id/stat/chown/mount/mountpoint, so it
# needs neither root nor a real mount to assert the chown/mount decision logic —
# every created mountpoint component inherits the DEEPEST EXISTING ancestor's
# uid:gid, before the mount goes on top, with exactly one warning per run when
# that fails. Without the chown, a mountpoint shadow-mounts.sh creates outlives
# the container as a root-owned directory on the host's own checkout.
#
# The test itself needs only bash + coreutils, but the CODE UNDER TEST does not:
# the suite deliberately leaves `realpath` unshimmed so the directory walk is the
# real one, and shadow-mounts.sh calls `realpath -m --` / `realpath -e --`, which
# are GNU-only (BSD/macOS realpath has neither flag). So mirror Stage 0e/0g/0f:
# prefer the in-image run — Linux userland guaranteed — and fall back to a host
# run only on a LINUX host, recording an honest skip otherwise rather than
# failing a macOS host smoke on a toolchain difference. It stays unconditional on
# every Linux host and in CI, so it cannot decay into a permanent skip.
#
# Like Stage 0g, the in-image run points the suite at the BAKED copy (via
# SHADOW_MOUNTS_SH), not at /repo/docker/shared/shadow-mounts.sh: /usr/local/bin/
# shadow-mounts.sh is what actually runs under sudo in a live container, so a
# STALE baked copy is caught by a real suite instead of being waved through by
# Stage 1's `command -v` presence probe. The baked file is COPY --chmod=755, so
# the unprivileged container user can read it — the suite only ever COPIES it and
# rewrites the /workspace literal, never executes the baked path itself.
#
# The /repo SOURCE is covered by the host-fallback branch below (a Linux host that
# has not built the image yet) and by running the suite directly, which AGENTS.md →
# "Validating Changes" lists as an in-container gate. Unlike Stage 0g there is no
# Tier 0 CI step for it yet; wiring every hermetic scripts/test-*.sh into Tier 0 is
# tasks/059-wire-pure-shell-suites-into-ci.md, and this stage is deliberately not
# front-running it.
#
# The privileged end-to-end counterpart (real root, real bind mount, real
# ownership on disk) is Stage 6's scripts/smoke-test-worktree-metadata.sh.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running shadow-mounts mountpoint-ownership unit test (baked script in $IMAGE) ..."
	docker run --rm -v "${ROOT_DIR}:/repo:ro" \
		-e SHADOW_MOUNTS_SH=/usr/local/bin/shadow-mounts.sh \
		--entrypoint /bin/bash "$IMAGE" /repo/scripts/test-shadow-mounts-chown.sh
elif [ "$(uname -s)" = Linux ]; then
	echo "Running shadow-mounts mountpoint-ownership unit test (host source — image '$IMAGE' absent) ..."
	"${ROOT_DIR}/scripts/test-shadow-mounts-chown.sh"
else
	echo "WARNING: skipping shadow-mounts mountpoint-ownership unit test (Stage 0h) — image '$IMAGE' absent and this is a non-Linux host (shadow-mounts.sh itself calls GNU-only 'realpath -m/-e', which BSD/macOS realpath rejects)."
	skipped+=("Stage 0h: shadow-mounts mountpoint-ownership unit test (image absent; host fallback needs a GNU/Linux userland)")
fi

# Stage 1 — tool presence + key image config: every expected CLI resolves and
# runs, and pnpm ships package-import-method=auto (not the old forced copy) so
# worktree installs can hardlink from a co-located store. The GOBIN probe
# plants a stub tool in ~/go/bin and runs it by bare name: the container shell
# is a login shell (`sh -lc`), which resets PATH from /etc/profile, and each
# probe's own shell inherits that environment, so the probe passing proves the
# baked profile.d snippet restores $HOME/go/bin —
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
# Every probe below is handed to the driver (scripts/smoke-test-image.sh) as a
# separate ARGUMENT, and the driver passes it to the container the same way: as
# one element of `"$@"` for a fixed one-line runner that executes each probe in
# its own `sh -ec` and reports a failure by INDEX, with the host printing an
# index → probe manifest when the run fails. Probe text is therefore DATA, never
# part of a script the container shell parses as a whole. Two things follow, and
# both are structural rather than a matter of careful escaping: no probe can
# affect the runner, the diagnostic, or a neighbouring probe — a stray quote, a
# trailing `#` comment, a `$(…)` or a backtick have nothing to reach; and
# `set -e` is active for the WHOLE of each probe, so a failing non-final member
# of an `&&` chain, of a `;` sequence, or of a `{ …; }` group aborts the run.
# That is what makes these multi-clause assertions real. Joined the original way
# — every probe a bare line of ONE `set -e` script — POSIX `set -e` exempted a
# failing element of an `&&` list that was not the FINAL element, so
# `A && B && C` whose `A` or `B` failed neither exited the shell nor propagated:
# every non-final clause of every probe, and the overall status of every probe
# but the last (nothing followed it to discard it), were masked.
# Consequences for probe authors:
#   * do NOT hand-roll a per-probe `|| { …; exit 1; }` tail — the runner
#     supplies one, and a second is redundant;
#   * make every probe SELF-CONTAINED. Each runs in its own shell, so `cd`,
#     `export` and plain variables do NOT carry to the next probe; only
#     filesystem effects do, which is how the golangci fixture probe hands the
#     three probes after it a worktree. `cd` to an absolute path in the probe
#     that needs it;
#   * keep every probe single-line and free of a trailing line continuation —
#     the driver rejects both, so the manifest stays one line per probe and the
#     .ps1 mirror never hands `docker` a multi-line argument;
#   * an `&&` chain is still the clearest shape, but a `;` sequence is binding
#     too. The one construct that is NOT: a probe ending in `&`, whose async
#     status POSIX fixes at 0.
# Quote balance is no longer a hazard to anything but the probe itself: an
# unbalanced quote makes that probe's own shell fail with a syntax error, named
# by its index, and cannot reach any other probe.
# Because the diagnostic carries only an index, it names the probe's source text
# through the manifest and not any runtime value it saw — re-run the probe from
# the manifest to get that. Pipeline-shaped probes (`X | grep -q Y`) are
# unaffected: the runner reads the status the pipeline already reports, and
# `set -o pipefail` is deliberately not set — it is not POSIX, and it would make
# each producer's status binding, including the SIGPIPE `grep -q` provokes by
# closing the pipe on its first match, an exposure that depends on how much the
# producer emits and so could flip a probe green→141 with no code change.
# scripts/test-smoke-probe-wrapper.sh unit-tests the runner, its
# injection-proofness, the per-probe isolation, and .sh/.ps1 argv parity.
# The dotnet probes pin the two pieces of the SDK layer that can regress
# silently.
# The sentinel probe re-derives the SDK version the way the Dockerfile's warm-up
# RUN does and asserts both marker files exist under $HOME/.dotnet, are owned by
# the runtime user, and that $HOME/.dotnet is writable by it — which pins that
# the warm-up ran at all, and that it ran as `node` into the HOME the container
# actually uses (moving the RUN above `USER node` leaves root-owned markers, and
# a root-created dir `node` cannot write, so it fails here; so does changing
# HOME), and that the build-time and runtime versions agree (a bumped SDK against
# a cached sentinel layer leaves stale names and fails). Bare existence checks
# would not catch the `USER node` case at all — the Dockerfile touches the
# absolute /home/node/.dotnet path, so the files land there either way.
# Re-deriving on its own would be a tautology — whatever `dotnet --version`
# prints, both sides build the same string — so the probe also asserts the
# derived value is one well-formed version token. Without that assertion, a
# `dotnet --version` that grew a second stdout line would make the build `touch`
# a newline-bearing garbage filename, still succeed, quietly restore the
# first-build "issue was encountered verifying workloads" warning, and the probe
# would find that same garbage name and pass. The Dockerfile's RUN applies the
# identical guard, so such a build now fails outright; this probe is what keeps a
# stale cached sentinel layer honest. The env probe pins the four documented
# opt-outs (notably DOTNET_GENERATE_ASPNET_CERTIFICATE, whose loss silently
# installs an ASP.NET HTTPS dev cert). Deliberately no `dotnet new` + build
# probe: that would pull NuGet packages over the network, the same reason the
# image is not warmed that way.
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
	"command -v peer-review-run >/dev/null" \
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
	"dotnet --version >/dev/null" \
	'sdk="$(dotnet --version)" && [ -n "$sdk" ] && [ "$sdk" = "${sdk%%[!0-9A-Za-z.-]*}" ] && [ -f "$HOME/.dotnet/${sdk}.dotnetFirstUseSentinel" ] && [ -O "$HOME/.dotnet/${sdk}.dotnetFirstUseSentinel" ] && [ -f "$HOME/.dotnet/${sdk}.toolpath.sentinel" ] && [ -O "$HOME/.dotnet/${sdk}.toolpath.sentinel" ] && [ -w "$HOME/.dotnet" ]' \
	'[ "$DOTNET_CLI_TELEMETRY_OPTOUT" = 1 ] && [ "$DOTNET_NOLOGO" = 1 ] && [ "$DOTNET_GENERATE_ASPNET_CERTIFICATE" = false ] && [ "$DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE" = 1 ]' \
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
# The DSN must state sslmode=disable: the cluster has no SSL and Go lib/pq
# refuses to connect when the parameter is absent (task 035). Assert it
# on the BAKED copy, and again after the eval so the %q escaping of `?` still
# round-trips.
case "$url" in *"?sslmode=disable") : ;; *) echo "FAIL: URL missing ?sslmode=disable: $url" >&2; exit 1 ;; esac
eval "$(pg-dev-up url --export)"
[ "$DATABASE_URL" = "$url" ] || { echo "FAIL: url --export did not round-trip through eval: $DATABASE_URL" >&2; exit 1; }
out=$(psql "$DATABASE_URL" -tAc "SELECT current_user, current_database()")
echo "psql SELECT -> $out"
printf %s "$out" | grep -qxF "t|app" || { echo "FAIL: unexpected psql result: $out" >&2; exit 1; }
pg-dev-up down >/dev/null
# Scoped worktree isolation: two LINKED worktrees of ONE repo (they share a
# common Git dir but have distinct toplevels — the real identity case) each get
# an isolated cluster on a distinct allocated port, connect to their own db, and
# stop independently.
rm -rf /tmp/smk-sa /tmp/smk-sb
git -C /tmp init -q smk-sa && git -C /tmp/smk-sa -c user.email=s@s -c user.name=s commit -q --allow-empty -m i
git -C /tmp/smk-sa -c user.email=s@s -c user.name=s worktree add -q -b smk-wt /tmp/smk-sb >/dev/null
ua=$(cd /tmp/smk-sa && POSTGRES_DB=sa pg-dev-up --worktree up | tail -1)
ub=$(cd /tmp/smk-sb && POSTGRES_DB=sb pg-dev-up --worktree up | tail -1)
pa=${ua##*:}; pa=${pa%%/*}; pb=${ub##*:}; pb=${pb%%/*}
{ [ -n "$pa" ] && [ "$pa" != "$pb" ]; } || { echo "FAIL: scoped ports collided ($pa vs $pb)" >&2; exit 1; }
[ "$(psql "$ua" -tAc "SELECT current_database()")" = sa ] || { echo "FAIL: scoped A wrong db" >&2; exit 1; }
[ "$(psql "$ub" -tAc "SELECT current_database()")" = sb ] || { echo "FAIL: scoped B wrong db" >&2; exit 1; }
(cd /tmp/smk-sa && pg-dev-up --worktree down >/dev/null)
(cd /tmp/smk-sb && pg-dev-up --worktree status >/dev/null 2>&1) || { echo "FAIL: scoped B stopped by A down" >&2; exit 1; }
(cd /tmp/smk-sb && pg-dev-up --worktree down >/dev/null)
echo "scoped isolation OK ($pa vs $pb)"
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
