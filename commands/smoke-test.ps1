param(
  [string]$Image = "powbox-agent:latest",
  [switch]$SkipDb,
  [switch]$SkipPodman,
  [switch]$SkipSelfHosted,
  [switch]$SkipDirMount,
  [switch]$SkipWorktreeMeta,
  [switch]$RequireImage
)

# The agent image is unified: both claude and codex (and codex's bwrap sandbox)
# are baked into the same image alongside the shared toolchain, so one smoke
# test validates everything in a single pass.
$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir

# The image-gated checks in stages 1-3 (and Stage 4's clone behavior) need the
# agent image; Stage 4's self-hosted identity contract runs without it. Detect
# the image once up front so a missing one is reported clearly here rather than as
# a raw docker error at Stage 1. -RequireImage (or POWBOX_SMOKE_REQUIRE_IMAGE=1,
# used by CI) turns an absent image into a hard error before any stage runs; the
# env var is also set so a sub-script invoked directly (e.g. the self-hosted clone
# stage) fails instead of self-skipping its image-gated checks into a false "all
# green". $skipped collects every stage we skip so the end-of-run banner can
# report that the run was partial.
# -RequireImage writes the *process* environment ($env:), which in an interactive
# session persists after this script returns (unlike the bash wrapper, whose
# exported var dies with the child process). Save the prior value and restore it in
# the finally below so later direct calls to the smoke sub-scripts in the same
# session behave as before instead of inheriting a sticky REQUIRE_IMAGE=1.
$prevRequireImage = $env:POWBOX_SMOKE_REQUIRE_IMAGE
if ($RequireImage) { $env:POWBOX_SMOKE_REQUIRE_IMAGE = '1' }
try {
$skipped = [System.Collections.Generic.List[string]]::new()
docker image inspect $Image *> $null
$imagePresent = ($LASTEXITCODE -eq 0)
if (-not $imagePresent) {
  if ($env:POWBOX_SMOKE_REQUIRE_IMAGE) {
    throw "image '$Image' not found and POWBOX_SMOKE_REQUIRE_IMAGE is set - refusing to run a partial (image-skipping) smoke test. Build it first (./build.ps1 agent) or drop -RequireImage."
  }
  Write-Warning "image '$Image' not found - the image-gated stages need it. Stage 1 will fail and abort the run before any later stage (Stages 2-5) runs, so you get no partial coverage. Build it (./build.ps1 agent), or pass -RequireImage to fail fast here with a clear message instead of a raw docker error at Stage 1."
}

# Stage 0a - sensitive-host-path predicate unit test against the BAKED library. Tier 0
# runs the /repo source; this runs the same Bash test INSIDE the agent image - which
# ships bash and the base-image mawk the mountinfo
# parser is verified against - with the repo mounted read-only. Like the Bash Stage 0a, it
# points the test at the BAKED /usr/local/bin/sensitive-host-path.sh (via SENSITIVE_HOST_PATH_LIB,
# below) - the library entrypoint-core.sh / fix-workspace-perms.sh / heal-workspace-perms.sh
# actually source at runtime - so a stale or behaviorally broken baked copy is caught here.
# This covers the predicate and the /proc/self/mountinfo source lookup that stop the
# workspace-perms heal from recursively chowning a mount whose host source is a system/home
# dir (the VPS-lockout incident - an accidental cc/cx from ~ re-owning the home tree and
# breaking sshd StrictModes on ~/.ssh). It self-skips - recorded in $skipped - when the
# image is absent; the
# live end-to-end guard is Stage 5.
if (-not $imagePresent) {
  Write-Warning "Skipping sensitive-host-path predicate unit test (Stage 0a) - image '$Image' not found (no native bash on Windows to run it hermetically)."
  $skipped.Add("Stage 0a: sensitive-host-path predicate unit test (image absent)")
}
else {
  Write-Host "Running sensitive-host-path predicate unit test (in $Image) ..."
  # Point LIB at the baked artifact so the in-image run validates the installed
  # /usr/local/bin/sensitive-host-path.sh that containers source, not the mounted /repo source.
  docker run --rm -v "${rootDir}:/repo:ro" -e SENSITIVE_HOST_PATH_LIB=/usr/local/bin/sensitive-host-path.sh --entrypoint /bin/bash $Image /repo/scripts/test-sensitive-host-path.sh
  if ($LASTEXITCODE -ne 0) {
    throw "sensitive-host-path predicate unit test failed. See container output above."
  }
}

# Stage 0b - gh-review-threads helper unit test. Like Stage 0a, the hermetic Bash test
# (it stubs `gh` with a PATH shim serving canned fixtures - no live GitHub) has no host
# bash on Windows, so run the SAME test INSIDE the agent image (which ships bash, jq, and
# the baked helper) with the repo mounted read-only; the stub and its fixtures are written
# to a container temp dir, so the read-only repo mount is fine. It guards the baked
# gh-review-threads helper: manual pagination (never `gh api graphql --paginate`,
# which under concurrent runs has returned another PR's threads) and the
# boundary-safe, repo-qualified PR-scope assertion that fails closed (exit 3) on a
# contaminated response. Self-skips (recorded in $skipped) when the image is absent.
if (-not $imagePresent) {
  Write-Warning "Skipping gh-review-threads helper unit test (Stage 0b) - image '$Image' not found (no native bash on Windows to run it hermetically)."
  $skipped.Add("Stage 0b: gh-review-threads helper unit test (image absent)")
}
else {
  Write-Host "Running gh-review-threads helper unit test (in $Image) ..."
  # Point HELPER at the baked artifact so the in-image run validates the installed
  # /usr/local/bin/gh-review-threads on PATH, not the mounted /repo source checkout.
  docker run --rm -v "${rootDir}:/repo:ro" -e GH_REVIEW_THREADS_HELPER=/usr/local/bin/gh-review-threads --entrypoint /bin/bash $Image /repo/scripts/test-gh-review-threads.sh
  if ($LASTEXITCODE -ne 0) {
    throw "gh-review-threads helper unit test failed. See container output above."
  }
}

# Stage 0d - worktree orphan-safety unit test. The hermetic Bash test (a throwaway git
# repo in a tmpdir; no host bash on Windows) runs INSIDE the agent image with the repo
# mounted read-only. It points POWBOX_WT_ENTER/POWBOX_WT_REMOVE/POWBOX_WT_COMMON at the
# BAKED /usr/local/bin copies, so it exercises the installed wt-enter/wt-remove and the
# wt-common.sh they source (task 017's durable-metadata safety contract: a dir that is no
# longer a live worktree is reaped only when empty, otherwise PRESERVED under
# .worktrees/.orphaned/, so the sole copy of dirty work is never deleted when metadata is
# lost). Self-skips (recorded in $skipped) when the image is absent.
if (-not $imagePresent) {
  Write-Warning "Skipping worktree orphan-safety unit test (Stage 0d) - image '$Image' not found (no native bash on Windows to run it hermetically)."
  $skipped.Add("Stage 0d: worktree orphan-safety unit test (image absent)")
}
else {
  Write-Host "Running worktree orphan-safety unit test (baked helpers in $Image) ..."
  docker run --rm -v "${rootDir}:/repo:ro" -e POWBOX_WT_COMMON=/usr/local/bin/wt-common.sh -e POWBOX_WT_ENTER=/usr/local/bin/wt-enter -e POWBOX_WT_REMOVE=/usr/local/bin/wt-remove --entrypoint /bin/bash $Image /repo/scripts/test-wt-orphan-safety.sh
  if ($LASTEXITCODE -ne 0) {
    throw "worktree orphan-safety unit test failed. See container output above."
  }
}

# Stage 0f - peer-review-run unit test. The hermetic Bash test (fake `claude`/`codex`
# binaries on a per-case PATH - no real providers, image, or network) has no host bash
# on Windows, so run it INSIDE the agent image against the BAKED
# /usr/local/bin/peer-review-run (via PEER_REVIEW_RUN) with the repo mounted read-only.
# It guards the bidirectional peer-review runner: the versioned result schema, both
# provider directions, read-only permission flags, literal stdin-fed prompts, Codex
# progress forwarding, the six normalized outcomes, timeout with process-tree reaping,
# and retry-once. Self-skips (recorded in $skipped) when the image is absent.
if (-not $imagePresent) {
  Write-Warning "Skipping peer-review-run unit test (Stage 0f) - image '$Image' not found (no native bash on Windows to run it hermetically)."
  $skipped.Add("Stage 0f: peer-review-run unit test (image absent)")
}
else {
  Write-Host "Running peer-review-run unit test (baked helper in $Image) ..."
  # --init: the test's reap assertions probe killed descendants with `kill -0`, which
  # still succeeds on an un-collected zombie; without an init, bash would be PID 1 and
  # KILLed orphans could linger as zombies and fail the checks. The powbox runtime
  # always provides a reaping PID 1 (init: true in compose.shared.yml), so match it.
  docker run --rm --init -v "${rootDir}:/repo:ro" -e PEER_REVIEW_RUN=/usr/local/bin/peer-review-run --entrypoint /bin/bash $Image /repo/scripts/test-peer-review-run.sh
  if ($LASTEXITCODE -ne 0) {
    throw "peer-review-run unit test failed. See container output above."
  }
}

# Stage 0g - detect-shadows unit suite (task 053). The only regression net anywhere in
# the repo for docker/shared/detect-shadows.sh's load-bearing security properties: the
# under-workspace-root validation, the symlink skip, the Git-tracked-content veto and
# its fail-closed paths, the newline rejection, and the workspace-glob containment.
# It needs git, jq and a JQ-BACKED yq (python-yq -
# detect-shadows.sh issues jq filters such as `.shadow[]? // empty`, which mikefarah's
# Go yq rejects), none of which a Windows host has natively, so run it INSIDE the agent
# image with the repo mounted read-only, pointed at the BAKED /usr/local/bin copies
# (POWBOX_DETECT_SHADOWS / POWBOX_PNPM_SHADOW_DOCTOR - the shape Stage 0d uses for the
# wt-* helpers) so a stale baked detect-shadows.sh is caught by a real suite rather than
# by Stage 1's presence probe. Self-skips (recorded in $skipped) when the image is absent;
# Tier 0 CI runs the same suite against the /repo source on every PR except one carrying
# the repo's `non-code` label, which gates the whole static-guards job off.
if (-not $imagePresent) {
  Write-Warning "Skipping detect-shadows unit suite (Stage 0g) - image '$Image' not found (no native bash/yq/jq on Windows to run it hermetically)."
  $skipped.Add("Stage 0g: detect-shadows unit suite (image absent)")
}
else {
  Write-Host "Running detect-shadows unit suite (baked scripts in $Image) ..."
  docker run --rm -v "${rootDir}:/repo:ro" -e POWBOX_DETECT_SHADOWS=/usr/local/bin/detect-shadows.sh -e POWBOX_PNPM_SHADOW_DOCTOR=/usr/local/bin/pnpm-shadow-doctor --entrypoint /bin/bash $Image /repo/scripts/test-detect-shadows.sh
  if ($LASTEXITCODE -ne 0) {
    throw "detect-shadows unit suite failed. See container output above."
  }
}

# Stage 0h - shadow-mounts mountpoint-ownership unit test (task 053). Fully hermetic:
# it copies docker/shared/shadow-mounts.sh with its /workspace literal relocated into a
# tmpdir and PATH-shims id/stat/chown/mount/mountpoint, so it needs neither root nor a
# real mount to assert that every mountpoint component shadow-mounts.sh creates
# inherits the DEEPEST EXISTING ancestor's uid:gid before the mount goes on top, with
# exactly one warning per run when that fails. Without the chown, a created mountpoint
# outlives the container as a root-owned directory on the host's own checkout. Like
# Stage 0g the in-image run is pointed at the BAKED copy
# (SHADOW_MOUNTS_SH=/usr/local/bin/shadow-mounts.sh) - that is the file sudo actually runs in a
# live container, so a stale baked copy is caught here rather than by Stage 1's presence probe.
# The /repo source is covered by Tier 0's auto-discovered source runner.
if (-not $imagePresent) {
  Write-Warning "Skipping shadow-mounts mountpoint-ownership unit test (Stage 0h) - image '$Image' not found (no native bash on Windows to run it hermetically)."
  $skipped.Add("Stage 0h: shadow-mounts mountpoint-ownership unit test (image absent)")
}
else {
  Write-Host "Running shadow-mounts mountpoint-ownership unit test (baked script in $Image) ..."
  docker run --rm -v "${rootDir}:/repo:ro" -e SHADOW_MOUNTS_SH=/usr/local/bin/shadow-mounts.sh --entrypoint /bin/bash $Image /repo/scripts/test-shadow-mounts-chown.sh
  if ($LASTEXITCODE -ne 0) {
    throw "shadow-mounts mountpoint-ownership unit test failed. See container output above."
  }
}

# Stage 0i - pnpm shadow-wrapper source unit test. The test shims every mount and
# sudo interaction, but its production contract requires a writable /workspace
# fixture. The image guarantees that root; an arbitrary host and Tier 0 do not. The
# explicit requirement promotes the suite's direct-run self-skip to a failure here,
# because an image that lost its writable production root is broken.
if (-not $imagePresent) {
  Write-Warning "Skipping pnpm shadow-wrapper unit test (Stage 0i) - image '$Image' not found (the suite needs the image's writable /workspace production root)."
  $skipped.Add("Stage 0i: pnpm shadow-wrapper unit test (image absent; needs a writable /workspace root)")
}
else {
  Write-Host "Running pnpm shadow-wrapper unit test (source in $Image) ..."
  docker run --rm -v "${rootDir}:/repo:ro" -e POWBOX_TEST_REQUIRE_WORKSPACE=1 --entrypoint /bin/bash $Image /repo/scripts/test-pnpm-shadow-wrapper.sh
  if ($LASTEXITCODE -ne 0) {
    throw "pnpm shadow-wrapper unit test failed. See container output above."
  }
}

# Stage 0j - disposable-clone helper unit test (dc-enter/dc-remove). Like Stage 0b,
# the hermetic Bash test (throwaway git repos under one mktemp -d root; no host bash
# on Windows) runs INSIDE the agent image with the repo mounted read-only, and points
# DC_ENTER_HELPER/DC_REMOVE_HELPER at the BAKED /usr/local/bin copies so it exercises
# the artifacts agents actually run: dc-enter's isolation guarantee (ref surgery,
# commits and gc in the clone cannot reach the invoking repository) and dc-remove's
# inverse guarantee that it deletes only a directory dc-enter created and marked.
# The helpers are vendored in agent-skills rather than kept here, so this suite is
# one of the pure-shell runner's explicit Tier 1 routes. Self-skips (recorded in
# $skipped) when the image is absent.
if (-not $imagePresent) {
  Write-Warning "Skipping disposable-clone helper unit test (Stage 0j) - image '$Image' not found (no native bash on Windows to run it hermetically)."
  $skipped.Add("Stage 0j: disposable-clone helper unit test (image absent)")
}
else {
  Write-Host "Running disposable-clone helper unit test (baked helpers in $Image) ..."
  docker run --rm -v "${rootDir}:/repo:ro" -e DC_ENTER_HELPER=/usr/local/bin/dc-enter -e DC_REMOVE_HELPER=/usr/local/bin/dc-remove --entrypoint /bin/bash $Image /repo/scripts/test-dc-helpers.sh
  if ($LASTEXITCODE -ne 0) {
    throw "disposable-clone helper unit test failed. See container output above."
  }
}

# Stage 1 - tool presence + key image config: every expected CLI resolves and
# runs, and pnpm ships package-import-method=auto (not the old forced copy) so
# worktree installs can hardlink from a co-located store. The GOBIN probe
# plants a stub tool in ~/go/bin and runs it by bare name: the container shell
# is a login shell (`sh -lc`), which resets PATH from /etc/profile, and each
# probe's own shell inherits that environment, so the probe passing proves the
# baked profile.d snippet restores $HOME/go/bin -
# the documented "`go install` and it's runnable" contract. The golangci-lint
# probes pin the cache-scoping wrapper contract: the PATH name resolves to the
# wrapper (real binary off PATH in /usr/local/libexec), a fixture worktree under
# .worktrees/<container>/<slug> gets its cache scoped to
# .worktrees/.golangci-cache/<container>/<slug>, the main checkout scopes to
# .root only in self-hosted mode when .worktrees is not a mountpoint (no host
# litter otherwise), and a caller-set GOLANGCI_LINT_CACHE always wins. The
# GOMODCACHE/GOCACHE probes prove go honors the plain env the launcher exports.
# The ccache probes prove the binary is baked, that it honors a CCACHE_DIR env
# (so the launcher's .worktrees/.ccache wiring lands) and - the functional check -
# that two identical `ccache gcc` compiles into a fresh cache produce a hit -
# direct or preprocessed, since either counter proves caching works - asserted via
# the machine-parsable `--print-stats` counters (stable since ccache 4.4; trixie
# bakes 4.11) instead of the version-dependent human-readable `-s` text.
# The opa probe goes past a bare version check: it writes a tiny Rego policy +
# test and runs `opa test`, exercising the exact `opa test policy/...` contract a
# policy-repo's CI runs (and that motivated baking opa in).
# The actionlint probe captures the whole multi-line version output successfully
# before comparing its first line exactly. markdownlint-cli2 has no dedicated
# `--version` option: it treats that token as an input glob while its human-facing
# startup banner happens to show a version. Rather than parse that presentation
# output without exercising linting, its probe invokes the PATH binary on a real
# temporary Markdown file, asserts the lint status reports exactly that one file,
# and separately reads the exact installed pin from npm's machine-readable global
# package metadata. It does not interpret the startup banner. A pin bump must
# update this inventory and its Bash mirror.
# Every probe below is handed to the driver (scripts/smoke-test-image.ps1) as a
# separate ARGUMENT, and the driver passes it to the container the same way: as
# one element of `"$@"` for a fixed one-line runner that executes each probe in
# its own `sh -ec` and reports a failure by INDEX, with the host printing an
# index -> probe manifest when the run fails. Probe text is therefore DATA, never
# part of a script the container shell parses as a whole. Two things follow, and
# both are structural rather than a matter of careful escaping: no probe's TEXT
# can affect the runner, the diagnostic, or a neighbouring probe - a stray
# quote, a trailing `#` comment, a `$(...)` or a backtick have nothing to reach
# (TEXT, not OUTPUT: a probe can still PRINT a line that mimics the diagnostic,
# but it cannot make the run report one - the verdict is the exit status);
# and a probe fails the run exactly when its own shell exits non-zero, which
# nothing discards any more. That second point is worth stating precisely,
# because it is the rule you write probes against, so learn the general rule
# rather than a list of shapes. POSIX (XCU 2.14) EXEMPTS a failing command in
# several positions - a non-final member of an `&&`/`||` list, a `!`-negated
# pipeline, and the condition of an `if`/`elif`/`while`/`until` - and the probe
# being the shell's whole input does not change that. What the exemption turns
# on is POSITION: an exempt construct is BINDING as the probe's LAST command,
# because its own status then becomes the probe's exit status and the runner's
# `||` guard sees it, and UNENFORCED when anything follows it, which overwrites
# that status. (`! X` inverts as POSIX says; an `if` whose condition is false
# with no `else` is 0 by definition, as is a `while`/`until` whose body never
# runs, so an `if`/`while`/`until` condition never fails a probe.)
# Nothing outside that exempt set is suspended at all - a failing member of a
# bare `;` sequence or of a `{ ...; }` group aborts the probe outright ("bare" is
# load-bearing: a `{ ...; }` group in a NON-FINAL `&&`/`||` position inherits the
# exemption throughout - `{ false; echo X; } && true` exits 0). That is what
# makes these multi-clause assertions real. Joined the original way - every
# probe a bare line of ONE `set -e` script - the same exemption applied, but
# nothing caught the status it left behind, so the non-final `&&`/`||` members
# of every probe, and the overall status of every probe but the last (nothing
# followed it to discard it), were masked; bare `;` sequences and `{ ...; }`
# groups were already enforced then, so that shape is not something this change
# restored.
# Consequences for probe authors:
#   * do NOT hand-roll a per-probe `|| { ...; exit 1; }` tail - the runner
#     supplies one, and a second is redundant;
#   * make every probe SELF-CONTAINED. Each runs in its own shell, so `cd`,
#     `export` and plain variables do NOT carry to the next probe; only
#     filesystem effects do, which is how the golangci fixture probe hands the
#     three probes after it a worktree. `cd` to an absolute path in the probe
#     that needs it;
#   * keep every probe single-line and free of a trailing line continuation -
#     the driver rejects both, so the manifest stays one line per probe and this
#     driver never hands `docker` a multi-line argument;
#   * an `&&` chain is still the clearest shape; a pipeline and a `;` sequence
#     are binding too. What is NOT enforceable is any `set -e`-exempt construct
#     that is not the probe's LAST command, because the command after it
#     overwrites the status - `A && B; C` and `! X; Y` are the instances - plus
#     a probe ending in `&`, whose async status POSIX fixes at 0. All are
#     equally unenforceable in the original join; no shipped probe uses any of
#     them, and section L of scripts/test-smoke-probe-wrapper.sh pins each with
#     a characterization check.
# Quote balance is no longer a hazard to anything but the probe itself: an
# unbalanced quote makes that probe's own shell fail with a syntax error, named
# by its index, and cannot reach any other probe.
# Because the diagnostic carries only an index, it names the probe's source text
# through the manifest and not any runtime value it saw - re-run the probe from
# the manifest to get that. Pipeline-shaped probes (`X | grep -q Y`) are
# unaffected: the runner reads the status the pipeline already reports, and
# `set -o pipefail` is deliberately not set - it is not POSIX, and it would make
# each producer's status binding, including the SIGPIPE `grep -q` provokes by
# closing the pipe on its first match, an exposure that depends on how much the
# producer emits and so could flip a probe green->141 with no code change.
# scripts/test-smoke-probe-wrapper.sh unit-tests the runner, its
# injection-proofness, the per-probe isolation, and .sh/.ps1 argv parity.
# The dotnet probes pin the SDK layer pieces that can regress silently, including
# an offline `dotnet nuget locals` check that the NUGET_PACKAGES override resolves
# to the exact requested path after tolerating the command's label and trailing
# separator formatting.
# The sentinel probe re-derives the SDK version the way the Dockerfile's warm-up
# RUN does and asserts both marker files exist under $HOME/.dotnet, are owned by
# the runtime user, and that $HOME/.dotnet is writable by it - which pins that
# the warm-up ran at all, and that it ran as `node` into the HOME the container
# actually uses (moving the RUN above `USER node` leaves root-owned markers, and
# a root-created dir `node` cannot write, so it fails here; so does changing
# HOME), and that the build-time and runtime versions agree (a bumped SDK against
# a cached sentinel layer leaves stale names and fails). Bare existence checks
# would not catch the `USER node` case at all - the Dockerfile touches the
# absolute /home/node/.dotnet path, so the files land there either way.
# Re-deriving on its own would be a tautology - whatever `dotnet --version`
# prints, both sides build the same string - so the probe also asserts the
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
& (Join-Path $rootDir "scripts/smoke-test-image.ps1") `
  -Image $Image `
  -Commands @(
    'claude --version >/dev/null'
    'codex --version >/dev/null'
    'bwrap --version >/dev/null'
    'gh --version >/dev/null'
    'node --version >/dev/null'
    'npm --version >/dev/null'
    'pnpm --version >/dev/null'
    'pnpm config get package-import-method | grep -qx auto'
    'pip3 --version >/dev/null'
    'python3 --version >/dev/null'
    'sqlcmd -? >/dev/null'
    'sqlite3 --version >/dev/null'
    'psql --version >/dev/null'
    'pg-dev-up check >/dev/null'
    'command -v wt-bootstrap >/dev/null'
    'command -v wt-enter >/dev/null'
    'command -v wt-remove >/dev/null'
    '[ -r /usr/local/bin/wt-common.sh ]'
    'command -v powbox-provenance >/dev/null'
    'command -v gitcat >/dev/null'
    'command -v gh-review-threads >/dev/null'
    'command -v dc-enter >/dev/null'
    'command -v dc-remove >/dev/null'
    'command -v peer-review-run >/dev/null'
    'wf_check_file="$(mktemp --suffix=.js)" && printf "%s\n" "export const meta = { name: \"smoke\", description: \"parser\" };" "return null;" > "$wf_check_file" && wf-check "$wf_check_file" >/dev/null && rm -- "$wf_check_file" && test "$(jq -r .version /usr/local/lib/wf-check/node_modules/acorn/package.json)" = 8.15.0 && test "$(jq -r .version /usr/local/lib/wf-check/node_modules/acorn-walk/package.json)" = 8.3.4'
    'wf-status --help >/dev/null'
    'shellcheck --version >/dev/null'
    'actionlint_output="$(actionlint --version)" && test "$(printf "%s\n" "$actionlint_output" | sed -n "1p")" = 1.7.12'
    'markdownlint_file="$(mktemp --suffix=.md)" && printf "# Smoke test\n" > "$markdownlint_file" && markdownlint_output="$(markdownlint-cli2 "$markdownlint_file")" && test "$(printf "%s\n" "$markdownlint_output" | grep -Fxc "Linting: 1 file")" -eq 1 && rm -- "$markdownlint_file" && test "$(npm list --global --depth=0 --json | jq -r ".dependencies[\"markdownlint-cli2\"].version")" = 0.23.2'
    'ping -V >/dev/null'
    'nc -h >/dev/null 2>&1'
    'bc --version >/dev/null'
    'less --version >/dev/null'
    'lsof -v >/dev/null 2>&1'
    'tree --version >/dev/null'
    'fd --version >/dev/null'
    'fzf --version >/dev/null'
    'bat --version >/dev/null'
    'ssh -V >/dev/null 2>&1'
    'rsync --version >/dev/null'
    'strace -V >/dev/null'
    'gpg --version >/dev/null'
    'gcc --version >/dev/null'
    'cmake --version >/dev/null'
    'ninja --version >/dev/null'
    'pkg-config --version >/dev/null'
    'pkg-config --exists openssl zlib'
    'ccache --version >/dev/null'
    'CCACHE_DIR=/tmp/powbox-ccache-cfg-probe ccache --show-config | grep -q /tmp/powbox-ccache-cfg-probe'
    'd=/tmp/powbox-ccache-fn-probe && rm -rf "$d" && mkdir -p "$d" && printf "int main(void){return 0;}\n" > "$d/t.c" && export CCACHE_DIR="$d/cache" && ccache -z >/dev/null && ccache gcc -c "$d/t.c" -o "$d/a.o" && ccache gcc -c "$d/t.c" -o "$d/b.o" && ccache --print-stats | grep -Eq "^(direct|preprocessed)_cache_hit[[:space:]]+[1-9]"'
    'go version >/dev/null'
    'command -v gofmt >/dev/null'
    'golangci-lint version >/dev/null'
    'readlink /usr/local/bin/golangci-lint | grep -q golangci-lint-wrapper'
    '[ -x /usr/local/libexec/golangci-lint ]'
    'GOMODCACHE=/tmp/powbox-gomod-probe go env GOMODCACHE | grep -qx /tmp/powbox-gomod-probe'
    'GOCACHE=/tmp/powbox-gocache-probe go env GOCACHE | grep -qx /tmp/powbox-gocache-probe'
    'GOLANGCI_LINT_CACHE=/tmp/powbox-golangci-custom golangci-lint cache status | grep -q "Dir: /tmp/powbox-golangci-custom"'
    'mkdir -p /tmp/powbox-golangci-probe/repo && cd /tmp/powbox-golangci-probe/repo && git init -q && git -c user.email=smoke@powbox.local -c user.name=smoke commit -q --allow-empty -m init && git worktree add -q .worktrees/probe-cont/task-a -b probe-a'
    'cd /tmp/powbox-golangci-probe/repo/.worktrees/probe-cont/task-a && golangci-lint cache status | grep -q "Dir: /tmp/powbox-golangci-probe/repo/.worktrees/.golangci-cache/probe-cont/task-a"'
    'cd /tmp/powbox-golangci-probe/repo && golangci-lint cache status | grep -q "Dir: $HOME/.cache/golangci-lint"'
    'cd /tmp/powbox-golangci-probe/repo && POWBOX_SELF_HOSTED=1 golangci-lint cache status | grep -q "Dir: /tmp/powbox-golangci-probe/repo/.worktrees/.golangci-cache/.root"'
    'mkdir -p "$HOME/go/bin" && printf "%s\n" "#!/bin/sh" "echo gobin-ok" > "$HOME/go/bin/powbox-gobin-probe" && chmod +x "$HOME/go/bin/powbox-gobin-probe" && powbox-gobin-probe | grep -qx gobin-ok'
    'opa version >/dev/null'
    'p=/tmp/powbox-opa-probe && rm -rf "$p" && mkdir -p "$p" && printf "%s\n" "package smoke" "" "allow if { input.x == 1 }" > "$p/p.rego" && printf "%s\n" "package smoke" "" "test_allow if { allow with input as {\"x\": 1} }" > "$p/p_test.rego" && opa test "$p" | grep -q "PASS: 1/1"'
    'dotnet --version >/dev/null'
    'NUGET_PACKAGES=/tmp/powbox-nuget-packages-probe dotnet nuget locals global-packages --list | sed "s/^[^:]*:[[:space:]]*//; s:/*$::" | grep -Fqx /tmp/powbox-nuget-packages-probe'
    'sdk="$(dotnet --version)" && [ -n "$sdk" ] && [ "$sdk" = "${sdk%%[!0-9A-Za-z.-]*}" ] && [ -f "$HOME/.dotnet/${sdk}.dotnetFirstUseSentinel" ] && [ -O "$HOME/.dotnet/${sdk}.dotnetFirstUseSentinel" ] && [ -f "$HOME/.dotnet/${sdk}.toolpath.sentinel" ] && [ -O "$HOME/.dotnet/${sdk}.toolpath.sentinel" ] && [ -w "$HOME/.dotnet" ]'
    '[ "$DOTNET_CLI_TELEMETRY_OPTOUT" = 1 ] && [ "$DOTNET_NOLOGO" = 1 ] && [ "$DOTNET_GENERATE_ASPNET_CERTIFICATE" = false ] && [ "$DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE" = 1 ]'
    'file --version >/dev/null'
    'printf test | xxd >/dev/null'
    'envsubst --version >/dev/null'
    'yq --version >/dev/null'
    'shfmt --version >/dev/null'
    'unzip -v >/dev/null'
    'zip -v >/dev/null'
    'wget --version >/dev/null'
    'htop --version >/dev/null'
  )

# Stage 2 - pg-dev-up functional test: stand up a real throwaway cluster and
# connect through the emitted DATABASE_URL. Unlike `pg-dev-up check` (binary
# presence only) this exercises role/db creation, URL percent-encoding, the
# 127.0.0.1 host binding, and the eval round-trip. Deliberately nasty
# credentials prove the SQL-quoting and URL-encoding paths. Skip the daemon
# bring-up with -SkipDb (the Podman stage below still runs unless -SkipPodman is
# also supplied; pass both for a Stage 1 presence-only run).
if ($SkipDb) {
  Write-Host "Skipping pg-dev-up functional test (-SkipDb)."
  $skipped.Add("Stage 2: pg-dev-up functional (-SkipDb)")
}
else {
  Write-Host "Running pg-dev-up functional test against $Image ..."
# Build the in-container script with explicit LF joins (single-quoted lines so
# PowerShell leaves the shell $vars alone). A here-string would inherit this
# file's CRLF endings (.gitattributes pins *.ps1 to eol=crlf), and the stray
# ^M would break parsing under /bin/sh -lc on a Windows checkout.
$dbScript = @(
  'set -e'
  'pg-dev-up up >/dev/null'
  'url=$(pg-dev-up url)'
  'echo "DATABASE_URL=$url"'
  'printf %s "$url" | grep -qF "p%40s%2Fs%26w%23d" || { echo "FAIL: password not percent-encoded in URL" >&2; exit 1; }'
  'printf %s "$url" | grep -qF "@127.0.0.1:" || { echo "FAIL: URL host is not 127.0.0.1" >&2; exit 1; }'
  '# The DSN must state sslmode=disable: the cluster has no SSL and Go lib/pq'
  '# refuses to connect when the parameter is absent (task 035). Assert'
  '# it on the BAKED copy, and again after the eval so the %q escaping of the ?'
  '# still round-trips.'
  'case "$url" in *"?sslmode=disable") : ;; *) echo "FAIL: URL missing ?sslmode=disable: $url" >&2; exit 1 ;; esac'
  'eval "$(pg-dev-up url --export)"'
  '[ "$DATABASE_URL" = "$url" ] || { echo "FAIL: url --export did not round-trip through eval: $DATABASE_URL" >&2; exit 1; }'
  'out=$(psql "$DATABASE_URL" -tAc "SELECT current_user, current_database()")'
  'echo "psql SELECT -> $out"'
  'printf %s "$out" | grep -qxF "t|app" || { echo "FAIL: unexpected psql result: $out" >&2; exit 1; }'
  'pg-dev-up down >/dev/null'
  '# Scoped worktree isolation: two LINKED worktrees of ONE repo (they share a'
  '# common Git dir but have distinct toplevels - the real identity case) each get'
  '# an isolated cluster on a distinct allocated port, connect to their own db, and'
  '# stop independently.'
  'rm -rf /tmp/smk-sa /tmp/smk-sb'
  'git -C /tmp init -q smk-sa && git -C /tmp/smk-sa -c user.email=s@s -c user.name=s commit -q --allow-empty -m i'
  'git -C /tmp/smk-sa -c user.email=s@s -c user.name=s worktree add -q -b smk-wt /tmp/smk-sb >/dev/null'
  'ua=$(cd /tmp/smk-sa && POSTGRES_DB=sa pg-dev-up --worktree up | tail -1)'
  'ub=$(cd /tmp/smk-sb && POSTGRES_DB=sb pg-dev-up --worktree up | tail -1)'
  'pa=${ua##*:}; pa=${pa%%/*}; pb=${ub##*:}; pb=${pb%%/*}'
  '{ [ -n "$pa" ] && [ "$pa" != "$pb" ]; } || { echo "FAIL: scoped ports collided ($pa vs $pb)" >&2; exit 1; }'
  '[ "$(psql "$ua" -tAc "SELECT current_database()")" = sa ] || { echo "FAIL: scoped A wrong db" >&2; exit 1; }'
  '[ "$(psql "$ub" -tAc "SELECT current_database()")" = sb ] || { echo "FAIL: scoped B wrong db" >&2; exit 1; }'
  '(cd /tmp/smk-sa && pg-dev-up --worktree down >/dev/null)'
  '(cd /tmp/smk-sb && pg-dev-up --worktree status >/dev/null 2>&1) || { echo "FAIL: scoped B stopped by A down" >&2; exit 1; }'
  '(cd /tmp/smk-sb && pg-dev-up --worktree down >/dev/null)'
  'echo "scoped isolation OK ($pa vs $pb)"'
) -join "`n"

docker run --rm `
  -e POSTGRES_USER=t `
  -e "POSTGRES_PASSWORD=p@s/s&w#d" `
  -e POSTGRES_DB=app `
  --entrypoint /bin/sh $Image -lc $dbScript

if ($LASTEXITCODE -ne 0) {
  throw "pg-dev-up functional test failed. See container output above."
}

  Write-Host "pg-dev-up functional test passed."

  # The scoped suite starts real PostgreSQL daemons on loopback and needs the
  # server binaries baked into the image, so Tier 1's database stage owns it.
  Write-Host "Running pg-dev-up scoped unit/integration suite in $Image ..."
  docker run --rm -v "${rootDir}:/repo:ro" --entrypoint /bin/bash $Image /repo/scripts/test-pg-dev-up-scoped.sh
  if ($LASTEXITCODE -ne 0) {
    throw "pg-dev-up scoped unit/integration suite failed. See container output above."
  }
}

# Stage 3 - rootless Podman engine: the agent image bakes podman + a docker shim
# (docs/rootless-podman.md). This is the automated guard that follow-up asked for -
# a base/Podman bump that regresses the engine (a dropped containers.conf drop-in, a
# Podman without the `compose` subcommand, a nested run that no longer starts) is
# caught here. The helper runs the image with the launch-time device + security
# wiring the launcher normally supplies via the compose overlays. On a host that
# cannot expose /dev/net/tun it still validates the static engine wiring and skips
# only the nested-run checks; a genuinely broken image fails on any host. Skip the
# whole stage explicitly with -SkipPodman; see scripts/smoke-test-podman.ps1 for
# what it covers. The helper throws on failure, so $ErrorActionPreference = "Stop"
# propagates that up.
if ($SkipPodman) {
  Write-Host "Skipping Podman smoke test (-SkipPodman)."
  $skipped.Add("Stage 3: rootless Podman engine (-SkipPodman)")
}
else {
  # smoke-test-podman.ps1 also treats POWBOX_PODMAN=off (deprecated alias
  # POWBOX_FUSE=off) as a whole-stage skip and returns with its own notice; and
  # under auto (the default) on a host without /dev/net/tun it runs the static
  # engine checks but returns after self-skipping the nested-run + published-port
  # checks (e.g. Docker Desktop / a hosted runner with no tun device). Mirror both
  # gates so the banner records the partial run instead of claiming all stages ran -
  # the child evaluates the same host /dev/net/tun condition before its docker run,
  # so the two agree. The child still prints the skip message; we track it here.
  $podmanRequest = if ($env:POWBOX_PODMAN) { $env:POWBOX_PODMAN } elseif ($env:POWBOX_FUSE) { $env:POWBOX_FUSE } else { "auto" }
  # Record WHICH variable supplied that value, because the banner's remedy is
  # "unset the variable this entry names": with only the deprecated alias set, an
  # entry naming POWBOX_PODMAN sends the reader to unset a variable that was never
  # set, leaving POWBOX_FUSE=off skipping the stage exactly as before.
  $podmanGateVar = if ($env:POWBOX_PODMAN) { "POWBOX_PODMAN" } else { "POWBOX_FUSE" }
  # The child self-skips one nested scenario at RUNTIME - the distroless (shell-less)
  # Compose XFAIL reproduction, when its image cannot be pulled - which the parent
  # cannot predict. Hand it a marker (like Stages 5/6): the child writes the reason
  # there and we surface it in the banner so the partial coverage is not hidden.
  $podmanMarker = New-TemporaryFile
  $podmanSkip = $null
  # Read the marker AND remove it inside the finally so a child-smoke failure (which
  # throws with $ErrorActionPreference=Stop) still cleans up the temp file -- a
  # Remove-Item placed after the try/finally would be skipped when the child throws.
  try {
    $env:POWBOX_SMOKE_SKIP_MARKER = $podmanMarker.FullName
    & (Join-Path $rootDir "scripts/smoke-test-podman.ps1") -Image $Image
  }
  finally {
    Remove-Item Env:\POWBOX_SMOKE_SKIP_MARKER -ErrorAction SilentlyContinue
    $podmanSkip = Get-Content -LiteralPath $podmanMarker.FullName -Raw -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $podmanMarker.FullName -ErrorAction SilentlyContinue
  }
  if ($podmanRequest -eq "off") {
    $skipped.Add("Stage 3: rootless Podman engine ($podmanGateVar=off)")
  }
  elseif ($podmanRequest -ne "on" -and -not (Test-Path "/dev/net/tun")) {
    $skipped.Add("Stage 3: rootless Podman nested-run checks (no /dev/net/tun)")
  }
  elseif ($podmanSkip) {
    $skipped.Add("Stage 3: $($podmanSkip.Trim())")
  }
}

# Stage 4 - self-hosted ("-Isolated") launch mode. Validates the launcher's
# self-hosted identity contract (always, no image needed) and the baked
# seed-workspace.sh clone/reuse/reclone/failure + single-mount hardlink behavior
# against the image (self-skips when the image is absent). Skip the whole stage
# with -SkipSelfHosted; see scripts/smoke-test-selfhosted.ps1. The helper throws
# on failure, so $ErrorActionPreference = "Stop" propagates that up.
if ($SkipSelfHosted) {
  Write-Host "Skipping self-hosted smoke test (-SkipSelfHosted)."
  $skipped.Add("Stage 4: self-hosted launch mode (-SkipSelfHosted)")
}
else {
  & (Join-Path $rootDir "scripts/smoke-test-selfhosted.ps1") -Image $Image
  # POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE=1 runs Stage A (launcher identity) but skips
  # Stage B (clone behavior) inside the child, which still returns success. Record
  # that partial coverage so the banner does not claim all stages ran.
  if ($env:POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE) {
    $skipped.Add("Stage 4: self-hosted clone behavior (POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE)")
  }
}

# Stage 5 - native-Linux dir-mount ownership. A bind-mounted root-owned repo is
# root:root inside the container, which the node agent (uid 1000) cannot write;
# entrypoint-core.sh's write probe + the sudo-allowlisted fix-workspace-perms.sh
# helper (PR #55) chown it to node so git/edits work. This stage runs two cases: the
# all-root-owned mount (PR #55) and a mixed-ownership mount (task 007) - a node-owned
# root that hides nested root-owned files from a host `sudo git pull` that the helper's
# uid-0 re-own heals. BOTH cases (tasks 005a + 007a) drive the GENUINE extracted entrypoint
# decision unit heal-workspace-perms.sh - the byte-for-byte probe-and-call code
# entrypoint-core.sh runs - so they guard the probe/decision path (does the probe still
# detect the unwritable mount and hand it to the helper?), not only the helper; that unit
# still ultimately invokes fix-workspace-perms.sh by the same allowlisted path/sudo
# mechanism, so the in-isolation helper + sudoers coverage is preserved. The all-root case
# exercises the root-level write probe; the mixed case (node-owned root + nested uid-0
# entries) exercises the nested-uid-0 DETECTION scan task 007 added that the root-level
# probe misses, so reverting ONLY that scan now fails the smoke (task 007a). Neither case
# boots the full entrypoint chain
# (firewall/gh/shadow need the launcher's compose wiring, out of scope here). It asserts
# node can
# write + git-commit each after the fix. It self-skips when the image is absent (honouring -RequireImage /
# POWBOX_SMOKE_REQUIRE_IMAGE), when the host is not native Linux, when it cannot
# create a root-owned fixture (no root / passwordless sudo - the local-dev case; it
# runs for real on a CI runner), or when the host masks the native-Linux uid bug.
# Skip the whole stage with -SkipDirMount; see scripts/smoke-test-dirmount.ps1. The
# helper throws on failure, so $ErrorActionPreference = "Stop" propagates that up.
if ($SkipDirMount) {
  Write-Host "Skipping dir-mount ownership smoke test (-SkipDirMount)."
  $skipped.Add("Stage 5: dir-mount ownership (-SkipDirMount)")
}
else {
  # The child still returns success when it self-skips at runtime (non-Linux host,
  # no root/passwordless sudo, or a host that masks the uid bug), so completion
  # alone cannot distinguish a real pass from a skip. Hand it a marker file: it
  # records the skip reason there and we surface it in the banner below, so a
  # partial run is not reported as "all stages ran". An empty marker means the
  # stage actually ran.
  $dirmountMarker = New-TemporaryFile
  try {
    $env:POWBOX_SMOKE_SKIP_MARKER = $dirmountMarker.FullName
    & (Join-Path $rootDir "scripts/smoke-test-dirmount.ps1") -Image $Image
  }
  finally {
    Remove-Item Env:\POWBOX_SMOKE_SKIP_MARKER -ErrorAction SilentlyContinue
  }
  $dirmountSkip = Get-Content -LiteralPath $dirmountMarker.FullName -Raw -ErrorAction SilentlyContinue
  if ($dirmountSkip) { $skipped.Add("Stage 5: dir-mount ownership ($($dirmountSkip.Trim()))") }
  Remove-Item -LiteralPath $dirmountMarker.FullName -ErrorAction SilentlyContinue
}

# Stage 6 - durable worktree-metadata recreate lifecycle (task 017). The headline
# acceptance criterion: in dir-mounted mode a linked git worktree and its
# per-worktree admin metadata survive a container stop/recreate, because the metadata
# is bound from the persistent .worktrees volume over .git/worktrees rather than
# living in the tmpfs shadow that vanishes on recycle. It launches two throwaway
# containers on ONE named agent-wt-style volume: the first establishes the durable
# bind (via the real shadow-mounts.sh) and leaves a linked worktree DIRTY (tracked
# mod + untracked file); the second recreates on the same volume and asserts git
# status still works, the branch/HEAD is intact, both dirty changes survived, and the
# host checkout's real .git/worktrees gained no registrations. Tier 0 / Stage 0d only
# unit-tests the orphan-reaping SAFETY net, not this central bind/survive path, so
# this stage is what guards it. Needs the image AND a runtime that can grant the
# container CAP_SYS_ADMIN for the `mount --bind`; it self-skips when the image is
# absent (honouring -RequireImage / POWBOX_SMOKE_REQUIRE_IMAGE) or the mount
# privilege is unavailable, running for real on native-Linux CI. Skip the whole stage
# with -SkipWorktreeMeta; see scripts/smoke-test-worktree-metadata.ps1. The helper
# throws on failure, so $ErrorActionPreference = "Stop" propagates that up.
if ($SkipWorktreeMeta) {
  Write-Host "Skipping worktree durable-metadata smoke test (-SkipWorktreeMeta)."
  $skipped.Add("Stage 6: worktree durable-metadata (-SkipWorktreeMeta)")
}
else {
  # Like Stage 5, the child returns success when it self-skips at runtime (image
  # absent or no mount privilege), so completion alone cannot distinguish a real pass
  # from a skip. Hand it the same marker mechanism and surface any skip in the banner.
  $wtmetaMarker = New-TemporaryFile
  try {
    $env:POWBOX_SMOKE_SKIP_MARKER = $wtmetaMarker.FullName
    & (Join-Path $rootDir "scripts/smoke-test-worktree-metadata.ps1") -Image $Image
  }
  finally {
    Remove-Item Env:\POWBOX_SMOKE_SKIP_MARKER -ErrorAction SilentlyContinue
  }
  $wtmetaSkip = Get-Content -LiteralPath $wtmetaMarker.FullName -Raw -ErrorAction SilentlyContinue
  if ($wtmetaSkip) { $skipped.Add("Stage 6: worktree durable-metadata ($($wtmetaSkip.Trim()))") }
  Remove-Item -LiteralPath $wtmetaMarker.FullName -ErrorAction SilentlyContinue
}

# The banner collects TWO kinds of entry - whole stages that never ran, and stages
# that ran with only a portion self-skipped (Stage 3's nested half is the standing
# example, reachable on every hosted-CI run) - so nothing here may assert that a
# listed stage produced no coverage, or prescribe a switch as the remedy for a
# host-decided partial that no switch governs (task 002g).
# commands/smoke-test.sh mirrors this banner and must be kept in step, EXCEPT for
# the punctuation: it uses an em dash where this file uses a hyphen, because this
# file is ASCII-only and a non-ASCII byte would force it to carry a UTF-8 BOM
# (AGENTS.md -> "File Conventions").
if ($skipped.Count -gt 0) {
  Write-Host ""
  Write-Host "============== SMOKE TEST: SKIPPED OR PARTIAL =============="
  foreach ($s in $skipped) { Write-Host "  - $s" }
  Write-Host "This was a PARTIAL smoke test - each entry above either did not"
  Write-Host "run at all, or ran only in part."
  Write-Host "Entries naming a -Skip* switch or an environment variable were"
  Write-Host "skipped on request: drop or unset it to run them, and pass"
  Write-Host "-RequireImage to also fail on a missing image. The rest were"
  Write-Host "decided by the host at runtime - nothing was set to skip them,"
  Write-Host "and dropping a switch or unsetting a variable will not recover"
  Write-Host "them: hosted CI has no /dev/net/tun, so Stage 3's nested half"
  Write-Host "self-skips there. See docs/smoke-tests.md."
  Write-Host "==========================================================="
}
else {
  Write-Host "Smoke test complete (all stages ran)."
}
}
finally {
  # Restore only if we set it: a CI run that exported POWBOX_SMOKE_REQUIRE_IMAGE
  # directly (without -RequireImage) must keep its own value untouched.
  if ($RequireImage) {
    if ($null -eq $prevRequireImage) {
      Remove-Item Env:\POWBOX_SMOKE_REQUIRE_IMAGE -ErrorAction SilentlyContinue
    }
    else {
      $env:POWBOX_SMOKE_REQUIRE_IMAGE = $prevRequireImage
    }
  }
}
