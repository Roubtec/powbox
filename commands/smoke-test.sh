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

# Stage 0a — sensitive-host-path predicate unit test against the BAKED library. Tier 0
# runs the /repo source on every eligible PR; this smoke entry points the suite at
# the base-layer copy at /usr/local/bin/sensitive-host-path.sh (via SENSITIVE_HOST_PATH_LIB)
# so it exercises the BAKED library that entrypoint-core.sh, fix-workspace-perms.sh, and
# heal-workspace-perms.sh actually source at runtime (they fall back to that path). Without
# it a stale or behaviorally broken baked copy in the base layer would slip through untested.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running sensitive-host-path predicate unit test (baked library in $IMAGE) ..."
	# Point LIB at the baked artifact so the in-image run validates the installed
	# /usr/local/bin/sensitive-host-path.sh containers source, not the mounted /repo source.
	docker run --rm -v "${ROOT_DIR}:/repo:ro" -e SENSITIVE_HOST_PATH_LIB=/usr/local/bin/sensitive-host-path.sh --entrypoint /bin/bash "$IMAGE" /repo/scripts/test-sensitive-host-path.sh
else
	echo "WARNING: skipping in-image sensitive-host-path baked-library test (Stage 0a) — image '$IMAGE' absent."
	skipped+=("Stage 0a: sensitive-host-path baked-library test (image absent)")
fi

# Stage 0b — gh-review-threads helper unit test. Hermetic (stubs `gh` with a PATH
# shim serving canned fixtures — no live GitHub or root needed). It guards the
# baked gh-review-threads helper: manual pagination (never `gh api graphql
# --paginate`, which under concurrent runs has returned another PR's threads)
# and the boundary-safe, repo-qualified PR-scope assertion that fails closed
# (exit 3) on a contaminated response.
#
# Run in-image so this exercises the BAKED
# /usr/local/bin/gh-review-threads on PATH — the artifact agents actually use — so a
# stale or behaviorally broken baked helper is caught here rather than waved through
# by Stage 1's `command -v` presence probe. The helper is not kept in this repo,
# so this suite is one of Tier 0's explicit Tier 1 routes.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running gh-review-threads helper unit test (baked helper in $IMAGE) ..."
	# Point HELPER at the baked artifact so the in-image run validates the installed
	# /usr/local/bin/gh-review-threads on PATH, not the mounted /repo source checkout.
	docker run --rm -v "${ROOT_DIR}:/repo:ro" -e GH_REVIEW_THREADS_HELPER=/usr/local/bin/gh-review-threads --entrypoint /bin/bash "$IMAGE" /repo/scripts/test-gh-review-threads.sh
else
	echo "WARNING: skipping gh-review-threads helper unit test (Stage 0b) — image '$IMAGE' absent."
	skipped+=("Stage 0b: gh-review-threads helper unit test (image absent)")
fi

# Stage 0d — worktree orphan-safety against the BAKED helpers. Tier 0 runs the
# /repo source; this points POWBOX_WT_ENTER/POWBOX_WT_REMOVE/POWBOX_WT_COMMON at
# the agent-layer copies at /usr/local/bin so it exercises the installed wt-enter/wt-remove and the
# wt-common.sh they source (and their exec bits) — the artifacts agents actually run.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running worktree orphan-safety unit test (baked helpers in $IMAGE) ..."
	docker run --rm -v "${ROOT_DIR}:/repo:ro" \
		-e POWBOX_WT_COMMON=/usr/local/bin/wt-common.sh \
		-e POWBOX_WT_ENTER=/usr/local/bin/wt-enter \
		-e POWBOX_WT_REMOVE=/usr/local/bin/wt-remove \
		--entrypoint /bin/bash "$IMAGE" /repo/scripts/test-wt-orphan-safety.sh
else
	echo "WARNING: skipping in-image worktree orphan-safety baked-helper test (Stage 0d) — image '$IMAGE' absent."
	skipped+=("Stage 0d: worktree orphan-safety baked-helper test (image absent)")
fi

# Stage 0f — peer-review-run unit test against the BAKED helper. Tier 0 covers
# the /repo source. This guards the bidirectional peer-review runner's contract:
# the versioned
# result schema, both provider directions, read-only permission flags, literal
# stdin-fed prompts, Codex progress forwarding, the six normalized outcomes, timeout
# with process-tree reaping, and retry-once. It runs against the BAKED
# /usr/local/bin/peer-review-run so a stale installed helper is caught here
# rather than waved through by Stage 1's `command -v`
# presence probe.
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
else
	echo "WARNING: skipping in-image peer-review-run baked-helper test (Stage 0f) — image '$IMAGE' absent."
	skipped+=("Stage 0f: peer-review-run baked-helper test (image absent)")
fi

# Stage 0g — detect-shadows unit suite (task 053). Hermetic (throwaway repos in a
# tmpdir; no image-internal state, root, or Docker daemon needed by the test
# itself). It is the only regression net anywhere in the repo for
# docker/shared/detect-shadows.sh's load-bearing security properties: the
# under-workspace-root validation, the symlink skip, the Git-tracked-content veto
# and its fail-closed paths, the newline rejection, and the workspace-glob
# containment — every one of which was verified to fail against the pre-fix script.
#
# The in-image run points the suite at the BAKED /usr/local/bin copies (via
# POWBOX_DETECT_SHADOWS / POWBOX_PNPM_SHADOW_DOCTOR, the shape Stage 0d uses for
# the wt-* helpers), so a STALE baked detect-shadows.sh is caught by a real suite
# instead of being waved through by Stage 1's `command -v` presence probe. The /repo
# SOURCE is covered by Tier 0 CI (`.github/workflows/native-linux-ci.yml`), which
# runs the suite unset on every PR
# EXCEPT one carrying the repo's `non-code` label — that label gates the whole
# static-guards job, so a `non-code` PR gets no Tier 0 detect-shadows run at all.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running detect-shadows unit suite (baked scripts in $IMAGE) ..."
	docker run --rm -v "${ROOT_DIR}:/repo:ro" \
		-e POWBOX_DETECT_SHADOWS=/usr/local/bin/detect-shadows.sh \
		-e POWBOX_PNPM_SHADOW_DOCTOR=/usr/local/bin/pnpm-shadow-doctor \
		--entrypoint /bin/bash "$IMAGE" /repo/scripts/test-detect-shadows.sh
else
	echo "WARNING: skipping detect-shadows baked-script unit suite (Stage 0g) — image '$IMAGE' absent."
	skipped+=("Stage 0g: detect-shadows baked-script unit suite (image absent)")
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
# Like Stage 0g, the in-image run points the suite at the BAKED copy (via
# SHADOW_MOUNTS_SH), not at /repo/docker/shared/shadow-mounts.sh: /usr/local/bin/
# shadow-mounts.sh is what actually runs under sudo in a live container, so a
# STALE baked copy is caught by a real suite instead of being waved through by
# Stage 1's `command -v` presence probe. The baked file is COPY --chmod=755, so
# the unprivileged container user can read it — the suite only ever COPIES it and
# rewrites the /workspace literal, never executes the baked path itself.
#
# Tier 0's auto-discovered source runner covers the /repo source on every
# eligible PR.
#
# The privileged end-to-end counterpart (real root, real bind mount, real
# ownership on disk) is Stage 6's scripts/smoke-test-worktree-metadata.sh.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running shadow-mounts mountpoint-ownership unit test (baked script in $IMAGE) ..."
	docker run --rm -v "${ROOT_DIR}:/repo:ro" \
		-e SHADOW_MOUNTS_SH=/usr/local/bin/shadow-mounts.sh \
		--entrypoint /bin/bash "$IMAGE" /repo/scripts/test-shadow-mounts-chown.sh
else
	echo "WARNING: skipping shadow-mounts baked-script unit test (Stage 0h) — image '$IMAGE' absent."
	skipped+=("Stage 0h: shadow-mounts baked-script unit test (image absent)")
fi

# Stage 0i — pnpm shadow-wrapper source unit test. The test shims every mount and
# sudo interaction, but the wrapper's production contract hard-requires a writable
# /workspace fixture. An arbitrary Tier 0 host checkout does not provide that root,
# while the agent image does, so this is one of the pure-shell runner's explicit
# Tier 1 routes. It validates the /repo source (the wrapper has no test override for
# a baked path) and needs no daemon, network, or privileged operation once inside
# the image. The explicit POWBOX_TEST_REQUIRE_WORKSPACE guard promotes the suite's
# generic-host self-skip to a failure here: an image that cannot provide its promised
# writable production root is broken, not partial coverage. POWBOX_SMOKE_REQUIRE_IMAGE
# separately makes an absent image fatal in CI; a local partial smoke records that skip.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running pnpm shadow-wrapper unit test (source in $IMAGE) ..."
	docker run --rm -v "${ROOT_DIR}:/repo:ro" \
		-e POWBOX_TEST_REQUIRE_WORKSPACE=1 \
		--entrypoint /bin/bash "$IMAGE" /repo/scripts/test-pnpm-shadow-wrapper.sh
else
	echo "WARNING: skipping pnpm shadow-wrapper unit test (Stage 0i) — image '$IMAGE' absent; the suite needs the image's writable /workspace production root."
	skipped+=("Stage 0i: pnpm shadow-wrapper unit test (image absent; needs a writable /workspace root)")
fi

# Stage 0j — disposable-clone helper unit test (dc-enter/dc-remove). Hermetic: every
# fixture is a throwaway git repo under one mktemp -d root and no helper is ever run
# against the mounted /repo, so it needs no network, daemon or privileged operation.
# Like Stage 0b it guards helpers vendored in agent-skills rather than kept here, so
# it is one of the pure-shell runner's explicit Tier 1 routes — and like Stage 0b it
# runs in-image with DC_ENTER_HELPER/DC_REMOVE_HELPER pointed at the BAKED
# /usr/local/bin artifacts, which is the whole point: Stage 1's `command -v` probes
# only prove the two files resolve, while this proves the isolation guarantee they
# exist for (refs, commits and `gc --prune=now` in the clone cannot touch the source)
# and dc-remove's inverse guarantee that it deletes only what dc-enter marked.
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
	echo "Running disposable-clone helper unit test (baked helpers in $IMAGE) ..."
	docker run --rm -v "${ROOT_DIR}:/repo:ro" \
		-e DC_ENTER_HELPER=/usr/local/bin/dc-enter \
		-e DC_REMOVE_HELPER=/usr/local/bin/dc-remove \
		--entrypoint /bin/bash "$IMAGE" /repo/scripts/test-dc-helpers.sh
else
	echo "WARNING: skipping disposable-clone helper unit test (Stage 0j) — image '$IMAGE' absent."
	skipped+=("Stage 0j: disposable-clone helper unit test (image absent)")
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
# The actionlint probe captures the whole multi-line version output successfully
# before comparing its first line exactly. markdownlint-cli2 has no dedicated
# `--version` option: it treats that token as an input glob while its human-facing
# startup banner happens to show a version. Rather than parse that presentation
# output without exercising linting, its probe invokes the PATH binary on a real
# temporary Markdown file, asserts the lint status reports exactly that one file,
# and separately reads the exact installed pin from npm's machine-readable global
# package metadata. It does not interpret the startup banner. A pin bump must
# update this inventory and its PowerShell mirror.
# Every probe below is handed to the driver (scripts/smoke-test-image.sh) as a
# separate ARGUMENT, and the driver passes it to the container the same way: as
# one element of `"$@"` for a fixed one-line runner that executes each probe in
# its own `sh -ec` and reports a failure by INDEX, with the host printing an
# index → probe manifest when the run fails. Probe text is therefore DATA, never
# part of a script the container shell parses as a whole. Two things follow, and
# both are structural rather than a matter of careful escaping: no probe's TEXT
# can affect the runner, the diagnostic, or a neighbouring probe — a stray
# quote, a trailing `#` comment, a `$(…)` or a backtick have nothing to reach
# (TEXT, not OUTPUT: a probe can still PRINT a line that mimics the diagnostic,
# but it cannot make the run report one — the verdict is the exit status);
# and a probe fails the run exactly when its own shell exits non-zero, which
# nothing discards any more. That second point is worth stating precisely,
# because it is the rule you write probes against, so learn the general rule
# rather than a list of shapes. POSIX (XCU 2.14) EXEMPTS a failing command in
# several positions — a non-final member of an `&&`/`||` list, a `!`-negated
# pipeline, and the condition of an `if`/`elif`/`while`/`until` — and the probe
# being the shell's whole input does not change that. What the exemption turns
# on is POSITION: an exempt construct is BINDING as the probe's LAST command,
# because its own status then becomes the probe's exit status and the runner's
# `||` guard sees it, and UNENFORCED when anything follows it, which overwrites
# that status. (`! X` inverts as POSIX says; an `if` whose condition is false
# with no `else` is 0 by definition, as is a `while`/`until` whose body never
# runs, so an `if`/`while`/`until` condition never fails a probe.)
# Nothing outside that exempt set is suspended at all — a failing member of a
# bare `;` sequence or of a `{ …; }` group aborts the probe outright ("bare" is
# load-bearing: a `{ …; }` group in a NON-FINAL `&&`/`||` position inherits the
# exemption throughout — `{ false; echo X; } && true` exits 0). That is what
# makes these multi-clause assertions real. Joined the original way — every
# probe a bare line of ONE `set -e` script — the same exemption applied, but
# nothing caught the status it left behind, so the non-final `&&`/`||` members
# of every probe, and the overall status of every probe but the last (nothing
# followed it to discard it), were masked; bare `;` sequences and `{ …; }`
# groups were already enforced then, so that shape is not something this change
# restored.
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
#   * an `&&` chain is still the clearest shape; a pipeline and a `;` sequence
#     are binding too. What is NOT enforceable is any `set -e`-exempt construct
#     that is not the probe's LAST command, because the command after it
#     overwrites the status — `A && B; C` and `! X; Y` are the instances — plus
#     a probe ending in `&`, whose async status POSIX fixes at 0. All are
#     equally unenforceable in the original join; no shipped probe uses any of
#     them, and section L of scripts/test-smoke-probe-wrapper.sh pins each with
#     a characterization check.
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
# The dotnet probes pin the SDK layer pieces that can regress silently, including
# an offline `dotnet nuget locals` check that the NUGET_PACKAGES override resolves
# to the exact requested path after tolerating the command's label and trailing
# separator formatting.
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
	"command -v dc-enter >/dev/null" \
	"command -v dc-remove >/dev/null" \
	"command -v peer-review-run >/dev/null" \
	'wf_check_file="$(mktemp --suffix=.js)" && printf "%s\n" "export const meta = { name: \"smoke\", description: \"parser\" };" "return null;" > "$wf_check_file" && wf-check "$wf_check_file" >/dev/null && rm -- "$wf_check_file" && test "$(jq -r .version /usr/local/lib/wf-check/node_modules/acorn/package.json)" = 8.15.0 && test "$(jq -r .version /usr/local/lib/wf-check/node_modules/acorn-walk/package.json)" = 8.3.4' \
	"wf-status --help >/dev/null" \
	"shellcheck --version >/dev/null" \
	'actionlint_output="$(actionlint --version)" && test "$(printf "%s\n" "$actionlint_output" | sed -n "1p")" = 1.7.12' \
	'markdownlint_file="$(mktemp --suffix=.md)" && printf "# Smoke test\n" > "$markdownlint_file" && markdownlint_output="$(markdownlint-cli2 "$markdownlint_file")" && test "$(printf "%s\n" "$markdownlint_output" | grep -Fxc "Linting: 1 file")" -eq 1 && rm -- "$markdownlint_file" && test "$(npm list --global --depth=0 --json | jq -r ".dependencies[\"markdownlint-cli2\"].version")" = 0.23.2' \
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
	'NUGET_PACKAGES=/tmp/powbox-nuget-packages-probe dotnet nuget locals global-packages --list | sed "s/^[^:]*:[[:space:]]*//; s:/*$::" | grep -Fqx /tmp/powbox-nuget-packages-probe' \
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

	# The scoped suite starts several real PostgreSQL daemons on loopback and needs
	# the server binaries baked into the image, so it is deliberately routed out of
	# Tier 0's Docker-free source runner and into this database stage. It tests the
	# /repo pg-dev-up source against the baked server toolchain.
	echo "Running pg-dev-up scoped unit/integration suite in $IMAGE ..."
	docker run --rm -v "${ROOT_DIR}:/repo:ro" \
		--entrypoint /bin/bash "$IMAGE" /repo/scripts/test-pg-dev-up-scoped.sh
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
# smoke-test-podman.sh also treats POWBOX_PODMAN=off (deprecated alias
# POWBOX_FUSE=off) as a whole-stage skip and exits 0 with its own notice; and
# under auto (the default) on a host without /dev/net/tun it runs the static
# engine checks but exits 0 after self-skipping the nested-run + published-port
# checks (e.g. Docker Desktop / a hosted runner with no tun device). Mirror both
# gates so the banner records the partial run instead of claiming all stages ran
# — the child evaluates the same host /dev/net/tun condition before its docker
# run, so the two agree. Where the child runs at all it still prints its own skip
# message; we track it here.
podman_gate="${POWBOX_PODMAN:-${POWBOX_FUSE:-auto}}"
# Record WHICH variables hold the stage off, because the banner's remedy is
# "unset the variable this entry names": with only the deprecated alias set, an
# entry naming POWBOX_PODMAN sends the reader to unset a variable that was never
# set, leaving POWBOX_FUSE=off skipping the stage exactly as before. With BOTH
# set to off the same remedy is incomplete for the opposite reason — unsetting
# the governing POWBOX_PODMAN exposes the alias, also off — so name both there.
# Derived ABOVE the whole-stage gate below, not inside its else branch, because
# that gate is an OUTER one: POWBOX_SMOKE_SKIP_PODMAN and an off env gate can
# both be set, and an entry naming only the former sends the reader to unset it
# and hit the env gate underneath, with the stage still skipped.
if [ -z "${POWBOX_PODMAN:-}" ]; then
	podman_gate_off=POWBOX_FUSE=off
elif [ "${POWBOX_FUSE:-}" = "off" ]; then
	podman_gate_off="POWBOX_PODMAN=off and POWBOX_FUSE=off"
else
	podman_gate_off=POWBOX_PODMAN=off
fi
if [ -n "${POWBOX_SMOKE_SKIP_PODMAN:-}" ]; then
	echo "Skipping Podman smoke test (POWBOX_SMOKE_SKIP_PODMAN is set)."
	if [ "$podman_gate" = "off" ]; then
		skipped+=("Stage 3: rootless Podman engine (POWBOX_SMOKE_SKIP_PODMAN and ${podman_gate_off})")
	else
		skipped+=("Stage 3: rootless Podman engine (POWBOX_SMOKE_SKIP_PODMAN)")
	fi
else
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
		skipped+=("Stage 3: rootless Podman engine (${podman_gate_off})")
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
# scripts/test-wt-orphan-safety.sh (Tier 0 / Stage 0d) only unit-tests the orphan-reaping
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

# Entries reach this banner from two different places — whole stages that never ran,
# and stages that ran with only a portion self-skipped — so nothing here may assert
# that a listed stage produced no coverage, or prescribe a variable as the remedy for
# a host-decided partial that no variable governs (task 002g).
# commands/smoke-test.ps1 mirrors this banner and must be kept in step, EXCEPT for
# the punctuation and the platform's control vocabulary. It uses a hyphen where this
# file uses an em dash, because that file is ASCII-only and a non-ASCII byte would
# force it to carry a UTF-8 BOM (AGENTS.md → "File Conventions").
if [ "${#skipped[@]}" -gt 0 ]; then
	echo
	echo "============== SMOKE TEST: SKIPPED OR PARTIAL =============="
	for s in "${skipped[@]}"; do
		echo "  - $s"
	done
	echo "This was a PARTIAL smoke test — each entry above either did not"
	echo "run at all, or ran only in part."
	echo "Entries naming an environment variable were skipped on request:"
	echo "unset it to run them, and set POWBOX_SMOKE_REQUIRE_IMAGE=1 to also"
	echo "fail on a missing image. The rest were decided by the host at"
	echo "runtime — nothing was set to skip them, and unsetting a variable"
	echo "will not recover them: hosted CI has no /dev/net/tun, so Stage 3's"
	echo "nested half self-skips there. See docs/smoke-tests.md."
	echo "==========================================================="
else
	echo "Smoke test complete (all stages ran)."
fi
