# The "full" layer set: the maintainer's bundle of toolchains on top of the lean
# base. Select it by writing `full` into .powbox-layers (see
# .powbox-layers.example); scripts/build-image.{sh,ps1} then bake this file into
# powbox-agent-layers:latest and build the agent image on it.
#
# It adds the language toolchains the lean base leaves out. Each sits in its
# own delimited block below, so a copy can be trimmed by deleting a block
# together with that tool's probes in smoke-probes.txt and its notes in
# agent-notes.md. CI never builds it: Tier 1 exercises the layer-set chain
# through the smaller `browser` set, Tier 0 only checks this directory against
# the contract below, and the maintainer builds this set by hand and fixes it
# when an install breaks.
#
# The contract every layer Dockerfile follows (README "Layer sets"):
#   - start with the two lines below, so the build scripts can pass the base,
#     and build the final stage on it (directly or through a stage that is):
#     the build refuses a layer image whose filesystem layers do not start
#     with the base's;
#   - switch to USER root for installs and end with USER node, the user the
#     base ends with and the agent Dockerfile assumes;
#   - give every COPY and ADD a --chmod=<mode>: the build context is this
#     directory alone, and its digest (scripts/layers-digest.{sh,ps1}) covers
#     file contents, not modes, so a mode must come from this file;
#   - bind-mount no build context in a RUN (a --mount= without type= is a
#     bind too): it shows this directory's files with their checkout modes.
#     A bind from=<stage-or-image> and cache, tmpfs, secret and ssh mounts
#     are fine;
#   - keep only regular files in the directory (a symlink or an empty
#     directory is rejected; create those in a RUN);
#   - use no ONBUILD: a trigger runs in the agent build, from the repo-root
#     context, where it could read files the digest does not cover;
#   - set no powbox.* labels: the bake target stamps them;
#   - keep the default backslash escape (no `# escape=` naming another).
ARG BASE_IMAGE=powbox-agent-base:latest
FROM ${BASE_IMAGE}

USER root

# ---------------------------------------------------------------------------
# PHP 8.4 and composer
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    php8.4-cli \
    php8.4-xml \
    php8.4-mbstring \
    php8.4-curl \
    php8.4-zip \
    php8.4-intl \
    php8.4-sqlite3 \
    php8.4-bcmath \
    php8.4-mysql \
    php8.4-pgsql \
    composer \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# ODBC driver-manager headers
# ---------------------------------------------------------------------------
# The unixODBC headers and pkg-config files, so an ODBC client (pyodbc, PHP's
# pdo_sqlsrv) builds against the msodbcsql18 driver mssql-tools18 pulls in.
RUN apt-get update && apt-get install -y --no-install-recommends \
    unixodbc-dev \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Microsoft-repo tooling: sqlcmd/bcp, PowerShell and PSScriptAnalyzer
# ---------------------------------------------------------------------------
# Install Microsoft-repo tooling: sqlcmd/bcp (mssql-tools18, for Azure SQL
# workflows) and PowerShell (pwsh, so agents can run and lint .ps1 scripts).
#
# Use Microsoft's official `packages-microsoft-prod.deb` config package rather
# than hand-writing the key + sources.list. On Debian 13 (trixie) apt verifies
# signatures with sequoia (`sqv`), which is stricter, and Microsoft signs the
# trixie repo with a rotated key that the legacy `microsoft.asc` bundle does NOT
# contain (apt fails: "Missing key EE4D7792F748182B"). The config deb installs
# the correct rotated keyring (microsoft-prod.gpg) and the matching trixie repo
# line, so it tracks Microsoft's key rotations for us.
RUN curl -fsSL -o /tmp/packages-microsoft-prod.deb \
        https://packages.microsoft.com/config/debian/13/packages-microsoft-prod.deb \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/packages-microsoft-prod.deb \
    && rm -f /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends mssql-tools18 powershell \
    && ln -sf /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd \
    && ln -sf /opt/mssql-tools18/bin/bcp /usr/local/bin/bcp \
    && rm -rf /var/lib/apt/lists/*

# Install PSScriptAnalyzer (the PowerShell linter — shellcheck cannot lint
# .ps1) into the AllUsers module scope so every account can use it. Runs as
# root, before the USER node switch below.
RUN pwsh -NoProfile -NonInteractive -Command \
      "\$ErrorActionPreference = 'Stop'; \
       Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
       Install-Module -Name PSScriptAnalyzer -Scope AllUsers -Force"

# Ship the repo's PSScriptAnalyzer config as the image-wide house default.
# PSScriptAnalyzer auto-discovers a PSScriptAnalyzerSettings.psd1 in the
# directory it analyzes, so a project with its own root file overrides this;
# otherwise agents can apply it with `-Settings <path>`. The build context is
# this directory, so the file copied is the set's own byte-identical copy of
# the repo-root one; scripts/test-layer-sets.sh fails when the two differ.
COPY --chmod=644 PSScriptAnalyzerSettings.psd1 /usr/local/share/powershell/PSScriptAnalyzerSettings.psd1

ENV PATH="/opt/mssql-tools18/bin:${PATH}"

# ---------------------------------------------------------------------------
# Go toolchain and golangci-lint
# ---------------------------------------------------------------------------
# Install the Go toolchain from the official go.dev tarball — Debian trixie's
# golang package trails upstream by several releases, and Go repos pin exact
# toolchains (go.mod `toolchain` lines, .tool-versions), so the apt version is
# never the one a project wants. Pinned with per-arch sha256s; bump the version
# and both checksums together (https://go.dev/dl/?mode=json). GOTOOLCHAIN is
# left at its `auto` default deliberately: a repo pinning a NEWER toolchain than
# the baked one transparently downloads and runs it on first `go` invocation
# (public egress is open), while a repo pinning an older one runs the baked
# binary directly (toolchain pins are minimums) — so projects keep working
# between image bumps instead of failing fast on a version mismatch. Baking the
# toolchain also makes `go mod tidy` the authoritative resolver for go.sum
# merge/rebase conflicts (regenerates and validates checksums) rather than
# hand-merged unions.
#
# golangci-lint is the de-facto Go metalinter and the one lint binary projects
# actually pin (v2 config schema — a v1 binary cannot parse v2 configs); it
# bundles staticcheck, errcheck, ineffassign, unused, etc. internally, so none
# of those are installed standalone. Its release tarball is fetched straight
# from GitHub and sha256-pinned per arch exactly like Go (checksums come from
# the release's golangci-lint-<ver>-checksums.txt) — NOT via the official
# `curl | sh` installer: under /bin/sh (no pipefail) a failed installer
# download would be masked by the pipeline and the layer would "succeed"
# without the linter, and the pinned digests make the bits immutable where a
# tag fetch is not. The binary is extracted OFF PATH to /usr/local/libexec:
# the PATH name /usr/local/bin/golangci-lint is a symlink to the
# cache-scoping wrapper (golangci-lint-wrapper.sh — the pnpm-wrapper
# precedent; see the wrapper COPY below), which derives
# a per-worktree GOLANGCI_LINT_CACHE and then execs this real binary. gopls
# and dlv are deliberately NOT baked: the agent harnesses speak no LSP and
# debug via tests/prints, and either is one `go install` away (~/go/bin is on
# PATH below).
# go/gofmt are symlinked into /usr/local/bin (the sqlcmd/bcp precedent) because
# login shells (`sh -lc`, as the image smoke test spawns) reset PATH from
# /etc/profile and would otherwise lose /usr/local/go/bin; the go binary
# resolves GOROOT through the symlink. ~/go/bin (GOBIN — where `go install`
# lands) can't be covered by build-time symlinks, so a profile.d snippet
# re-prepends it for those PATH-resetting login shells ($HOME, not a hardcoded
# /home/node, so it also holds for root); the harnesses' non-login shells get
# it from the ENV PATH below, and zsh logins inherit that ENV PATH untouched
# (Debian's zprofile never sources /etc/profile). Placed low in the file so a
# Go bump never busts the expensive gh / mssql / pwsh / npm layers above.
#
# The tarball fetches carry --retry ... --retry-all-errors --http1.1: go.dev (and
# occasionally github.com) intermittently reset the HTTP/2 stream mid-download on
# hosted CI runners, which surfaces as `curl: (92) ... INTERNAL_ERROR` and hard-fails
# the build. Forcing HTTP/1.1 sidesteps that h2 stream-reset class outright, and
# --retry-all-errors additionally rides out transient CDN 5xx/timeouts. Safe here
# because both artifacts are sha256-pinned below, so a retried/partial download can
# never smuggle in different bits.
RUN GO_VERSION=1.26.4 \
    && GOLANGCI_LINT_VERSION=2.12.2 \
    && arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
        amd64) go_sha256=1153d3d50e0ac764b447adfe05c2bcf08e889d42a02e0fe0259bd47f6733ad7f \
               golangci_sha256=8df580d2670fed8fa984aac0507099af8df275e665215f5c7a2ae3943893a553 ;; \
        arm64) go_sha256=ef758ae7c6cf9267c9c0ef080b8965f453d89ab2d25d9eb22de4405925238768 \
               golangci_sha256=44cd40a8c76c86755375adfeea52cfd3533cb43d7bd647771e0ae065e166df3a ;; \
        *) echo "no pinned Go/golangci-lint checksums for architecture: $arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --http1.1 -o /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-${arch}.tar.gz" \
    && echo "${go_sha256}  /tmp/go.tar.gz" | sha256sum -c - \
    && tar -C /usr/local -xzf /tmp/go.tar.gz \
    && rm /tmp/go.tar.gz \
    && ln -sf /usr/local/go/bin/go /usr/local/bin/go \
    && ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt \
    && curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --http1.1 -o /tmp/golangci-lint.tar.gz "https://github.com/golangci/golangci-lint/releases/download/v${GOLANGCI_LINT_VERSION}/golangci-lint-${GOLANGCI_LINT_VERSION}-linux-${arch}.tar.gz" \
    && echo "${golangci_sha256}  /tmp/golangci-lint.tar.gz" | sha256sum -c - \
    && mkdir -p /usr/local/libexec \
    && tar -C /usr/local/libexec --strip-components=1 --no-same-owner \
        -xzf /tmp/golangci-lint.tar.gz "golangci-lint-${GOLANGCI_LINT_VERSION}-linux-${arch}/golangci-lint" \
    && rm /tmp/golangci-lint.tar.gz \
    && printf 'export PATH="$HOME/go/bin:$PATH"\n' > /etc/profile.d/golang-gobin.sh

COPY --chmod=755 golangci-lint-wrapper.sh /usr/local/bin/golangci-lint-wrapper.sh

# golangci-lint gets the base's pnpm-wrapper treatment: the PATH name resolves to
# the cache-scoping wrapper, which derives a per-worktree GOLANGCI_LINT_CACHE and
# execs the real binary extracted to /usr/local/libexec in the Go layer above
# (parallel worktree runs must not share one analysis cache — see the wrapper).
RUN ln -sf /usr/local/bin/golangci-lint-wrapper.sh /usr/local/bin/golangci-lint

# /usr/local/go/bin is the baked Go toolchain; /home/node/go/bin is Go's default
# GOBIN ($GOPATH/bin), so anything a session `go install`s (gopls, dlv, …) is
# immediately runnable without PATH surgery. Login shells never see this ENV
# (they reset PATH from /etc/profile) — the go/gofmt symlinks and the
# profile.d GOBIN snippet in the Go layer above keep both entries alive there.
ENV PATH="/usr/local/go/bin:/home/node/go/bin:${PATH}"

# ---------------------------------------------------------------------------
# Open Policy Agent
# ---------------------------------------------------------------------------
# Install Open Policy Agent (`opa`), the Rego policy engine projects use to
# unit-test authorization policy (`opa test policy/…`). Baked so a session
# touching Rego can run the same policy tests its CI does locally instead of
# leaning on the GitHub workflow that installs OPA — general-purpose tooling on
# the same footing as the Go/golangci binaries above. Fetched as the pinned,
# statically linked release binary from GitHub and sha256-pinned per arch
# (checksums from the release's opa_linux_<arch>_static.sha256); bump the
# version and both sums together (https://github.com/open-policy-agent/opa/releases).
# The `_static` build is used deliberately — a single self-contained binary with
# no glibc coupling, dropped straight onto PATH (no tarball to unpack).
#
# Version note: this is ONE baked release. `opa test` on a policy suite is
# version-tolerant in practice (validated against a 1.4.x-pinned project's
# tests), but a project that pins OPA to a specific engine for exact builtin
# fidelity (e.g. a matching envoy sidecar) should still pin/verify its own —
# the baked binary is for running the test suites, not certifying that a policy
# loads byte-for-byte in a particular deployed engine version.
#
# Placed low so an OPA bump never busts the expensive apt/gh/mssql/pwsh/npm
# layers above.
RUN OPA_VERSION=1.18.2 \
    && arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
        amd64) opa_sha256=9903e5125ac281104f2c4b7371d10cc3b74a98933743fcbfc174f9bf0ab20de8 ;; \
        arm64) opa_sha256=9cad2e67d375aded483823349173fe100d9701d37635908edadeb0298603c58c ;; \
        *) echo "no pinned OPA checksum for architecture: $arch" >&2; exit 1 ;; \
    esac \
    && curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --http1.1 -o /usr/local/bin/opa \
        "https://github.com/open-policy-agent/opa/releases/download/v${OPA_VERSION}/opa_linux_${arch}_static" \
    && echo "${opa_sha256}  /usr/local/bin/opa" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/opa

# ---------------------------------------------------------------------------
# Native build tools: CMake, Ninja, pkg-config, ccache, OpenSSL/zlib headers
# ---------------------------------------------------------------------------
# General-purpose native/CGo/CMake build dependencies. `build-essential` (gcc,
# g++, make) is already baked in the base; these add the build-orchestration and TLS/
# compression dev pieces that every non-trivial native build reaches for — a
# CMake/Ninja project, a CGo module wrapping a C library, or any build linking
# `-lssl -lcrypto -lz`. `libssl-dev`/`zlib1g-dev` ship the headers and `.pc`
# files so `pkg-config openssl` and `-lssl -lcrypto -lz` work with no runtime
# apt install; the OpenSSL 3.x runtime itself is already present. `ccache` is the
# compiler cache: baked here, but its persistent cache dir is wired by the
# launcher/entrypoint (CCACHE_DIR → .worktrees/.ccache, beside the Go caches) so
# repeated large native builds survive container recreation. It stays OPT-IN per
# build (no global CC/CXX or masquerade-PATH interposition here) — projects
# activate it with `CC="ccache gcc"` or `cmake -DCMAKE_C_COMPILER_LAUNCHER=ccache`.
# Pure build-time packages: no entrypoint, sudoers, or firewall interaction.
# Placed low so it never busts the expensive gh / mssql / pwsh / npm / Podman /
# Go / OPA layers above it.
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake \
    pkg-config \
    libssl-dev \
    ninja-build \
    zlib1g-dev \
    ccache \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# .NET SDK (needs the Microsoft apt repo the sqlcmd/PowerShell block adds)
# ---------------------------------------------------------------------------
# Install the .NET SDK so a session touching C#/F# projects can run the same
# `dotnet build` / `dotnet test` its CI does, instead of pushing and waiting for
# the pipeline to tell it the solution does not compile — general-purpose
# tooling on the same footing as the Go/OPA binaries above.
#
# No new apt source is needed: the Microsoft `packages-microsoft-prod` repo (and
# its rotated trixie keyring) is already configured far above for pwsh and
# mssql-tools18, and it carries the SDK packages too. That layer ends with an
# `rm -rf /var/lib/apt/lists/*`, hence the `apt-get update` here.
#
# Version choice: the 10.0 LTS band (supported to 2028-11-14; 8.0's support
# ends 2026-11-10), pinned only to major.minor (the postgresql-16 /
# mssql-tools18 precedent, NOT the sha256-pinned tarball treatment Go and OPA
# need — this is a signed distro repo). It is the major projects currently pin
# in CI (`actions/setup-dotnet` with `10.0.1xx`). The apt candidate tracks the
# NEWEST 10.0 feature band (10.0.4xx at the time of writing), so a local run
# and a CI run agree on the runtime and language major but not necessarily on
# the SDK feature band. `dotnet-sdk-10.0` pulls its own runtime, the ASP.NET
# runtime, and the targeting/apphost packs, so `dotnet test -f net10.0` works
# with nothing else installed. A project still targeting an older TFM
# (`net8.0`) BUILDS with this SDK alone — the targeting pack comes from NuGet —
# but its binaries and tests do not RUN without that runtime ("You must install
# or update .NET to run this application"); `DOTNET_ROLL_FORWARD=Major` runs
# them on the baked 10.0 runtime instead. Because the Microsoft repo is already
# wired, a project needing a different band is one `sudo apt-get update && sudo
# apt-get install -y dotnet-sdk-N.0` away in-session — the same escape hatch
# GOTOOLCHAIN=auto gives Go projects. The `update` is not optional: this layer
# ends by clearing /var/lib/apt/lists and no later layer repopulates it, so a
# bare `apt-get install` in a fresh container fails with "Unable to locate
# package" even though the source is configured.
# Baking a second SDK is deliberately avoided: each one is ~600 MB (8.0 was
# ~575 MB, 10.0 is ~645 MB).
#
# `dotnet format` and `dotnet test` ship inside the SDK, so no companion lint or
# test-runner package is installed (contrast golangci-lint, which Go needs
# separately). Targeting .NET Framework (`net48`) from Linux also needs nothing
# extra — projects reference the Microsoft.NETFramework.ReferenceAssemblies
# NuGet package and compile with only this SDK present.
#
# Placed low, beside the other late tool layers, so an SDK bump never busts the
# expensive gh / mssql / pwsh / npm / Podman / Go / OPA layers above it.
RUN apt-get update && apt-get install -y --no-install-recommends \
    dotnet-sdk-10.0 \
    && rm -rf /var/lib/apt/lists/*

# Keep `dotnet` output clean and its side effects predictable. Each of these was
# observed on a real first build in a fresh container, not copied from a
# checklist; an agent parsing build output should see compiler diagnostics and
# nothing else. No PATH entry is needed — the apt package symlinks
# /usr/bin/dotnet, so login shells that reset PATH from /etc/profile keep it.
#   DOTNET_CLI_TELEMETRY_OPTOUT - no usage telemetry from a sandbox.
#   DOTNET_NOLOGO - drops the multi-line first-run "Welcome to .NET" banner that
#     otherwise prefixes the first build's output.
#   DOTNET_GENERATE_ASPNET_CERTIFICATE - the CLI otherwise SILENTLY generates and
#     installs an ASP.NET Core HTTPS development certificate on first run.
#     Nothing in a headless agent container terminates TLS locally, so this is
#     pure surprise state.
#   DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE - suppresses the periodic workload
#     update advertisement. Note this does NOT cover the separate first-use
#     workload-verification warning; the sentinel warm-up below does.
# DOTNET_SKIP_FIRST_TIME_EXPERIENCE is deliberately NOT set: it has been a no-op
# since .NET 5, and NOLOGO covers what it used to.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
ENV DOTNET_NOLOGO=1
ENV DOTNET_GENERATE_ASPNET_CERTIFICATE=false
ENV DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE=1

USER node

# Pre-create the .NET CLI first-use sentinels so the very first `dotnet build`
# in a container is silent. Without them it emits "An issue was encountered
# verifying workloads. For more information, run 'dotnet workload update'" —
# which is unactionable here: workload manifests live under the root-owned
# /usr/share/dotnet, `node` cannot write them ("Inadequate permissions"), and
# that is the permanent, intended state of this image. The warning is emitted
# once per HOME per SDK version and then self-silences, so an agent's first
# build was the one that got the noise.
#
# Two empty marker files are enough, and the version is derived from the
# installed SDK rather than hardcoded, so an SDK bump above needs no edit here.
# The derived value is validated to be one well-formed version token before
# anything is touched: `$(...)` strips only trailing newlines, so a
# `dotnet --version` that ever grew a second stdout line would otherwise `touch`
# a newline-bearing garbage filename, suppress nothing, and still succeed —
# failing the build loudly is the only safe outcome. Stage 1b of the smoke test
# applies the same guard (see this set's smoke-probes.txt) so a stale cached
# copy of this layer cannot ship one either.
# Deliberately NOT warmed by running a throwaway `dotnet new` + build: that
# would pull NuGet packages into the image for no benefit. Must run after
# USER node — the sentinels are per-HOME, and /home/node is image content (only
# .claude / .config/gh are volumes), so they persist into every container.
RUN mkdir -p /home/node/.dotnet \
    && _sdk="$(dotnet --version)" \
    && [ -n "$_sdk" ] \
    && [ "$_sdk" = "${_sdk%%[!0-9A-Za-z.-]*}" ] \
    && touch "/home/node/.dotnet/${_sdk}.dotnetFirstUseSentinel" \
        "/home/node/.dotnet/${_sdk}.toolpath.sentinel"
