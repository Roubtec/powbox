# 071 — Move the self-contained toolchains out of the base into the `full` layer set

## Why this task exists

This is the first of two tasks that make the base image lean.
It moves the toolchains that have **no runtime coupling** to the launcher or entrypoint: removing them from the base changes nothing about how a container starts.
Task 073 then moves the coupled ones (Podman, PostgreSQL, the browser stack).

The target user of the lean image is someone running unattended agents over a folder, who needs Node and Python as the agent's own automation runtime, git and the shell tools, and document conversion, but not language toolchains.

## Scope

**In scope — move from `docker/base/Dockerfile` to `docker/layers/full/Dockerfile`:**

| Tool | Approximate size | Notes |
|---|---|---|
| .NET SDK | 645 MB | **Must stay `dotnet-sdk-10.0`** (see below); with its four `DOTNET_*` env vars and the first-use sentinel `RUN` |
| PowerShell + PSScriptAnalyzer | 466 MB | with the baked `PSScriptAnalyzerSettings.psd1` house default |
| Go toolchain + golangci-lint | 308 MB | with `golangci-lint-wrapper.sh`, its symlink, the `go`/`gofmt` symlinks and the `golang-gobin.sh` profile snippet |
| cmake, ninja, pkg-config, ccache, `libssl-dev`, `zlib1g-dev` | 63 MB | the "General-purpose native/CGo/CMake build dependencies" block |
| OPA | 52 MB | |
| PHP 8.4 packages + composer | 28 MB | from the first `apt-get install` block |
| `mssql-tools18`, `unixodbc-dev`, the Microsoft apt repo config | 3 MB | the repo config serves PowerShell and .NET too, so it moves with them |

**Also in scope:**

- The matching rows of `docker/shared/container-agent.md.tmpl` move into a new `docker/layers/full/agent-notes.md`.
- The matching Stage 1 probes move from `commands/smoke-test.{sh,ps1}` into a new `docker/layers/full/smoke-probes.txt`.
- `scripts/base-source-files.txt`, the docs, and the CI cache keys follow.

**Stays in the base (decided, do not move):** Node, npm, pnpm and its shadow wrapper; Python 3 and pip; git, gh, ssh; the shell utilities; `build-essential`, `make`, `patch` (native modules for `pip` and `npm` need a compiler); `shellcheck` and `shfmt` (agents write shell scripts constantly); `pandoc`, `poppler-utils`, `sqlite3`; the firewall, sudo and bubblewrap setup; `yq`.

**Out of scope:**

- Podman, PostgreSQL and `pg-dev-up`, Chromium, Marp, Mermaid, Playwright, and adding Typst (task 073).
- The launcher and entrypoint. `GOMODCACHE`, `GOCACHE`, `CCACHE_DIR`, `NUGET_PACKAGES`, the `go.mod` / .NET project detection and the `bin`/`obj` shadows stay exactly as they are: they are inert without the tool, and they give a user who adds Go or .NET in their own set persistent caches for free.
- `docker/agent/Dockerfile`. `actionlint`, `markdownlint-cli2` and `wf-check` live in the agent image, not the base.

## Context and references

- Depends on tasks 063 (layer-set chain), 067 (agent notes), 069 (layer probes) and should land after 065 so both images are built in CI.
- `docker/base/Dockerfile`: each block to move is introduced by its own comment (for example "Install the Go toolchain from the official go.dev tarball", "Install Open Policy Agent", "General-purpose native/CGo/CMake build dependencies", "Install the .NET SDK", "Install Microsoft-repo tooling", "Install PSScriptAnalyzer", "Pre-create the .NET CLI first-use sentinels"). Carry the rationale comments with the blocks; they record decisions that were measured.
- `docs/architecture.md`: "Bundled Go toolchain", "Bundled .NET SDK".
- **.NET version.** Commit `6a9768a` moved the image to the .NET 10 LTS SDK because .NET 8 support ends on 2026-11-10 and projects are moving their CI to `10.0`. The moved block must install `dotnet-sdk-10.0`. Do not reintroduce `dotnet-sdk-8.0` while relocating it.
- Measured facts to preserve in the notes: with only SDK 10 present a `net8.0` project builds but its binaries and tests do not run, and the two ways out are `DOTNET_ROLL_FORWARD=Major` or installing the older band side by side.

## Target files or areas

- `docker/base/Dockerfile` — remove the blocks above; trim the `ENV PATH` line (`/opt/mssql-tools18/bin`, `/usr/local/go/bin`, `/home/node/go/bin`); remove `golangci-lint-wrapper.sh` from the shared-script `COPY` and its `ln -sf` from the symlink `RUN`.
- `docker/layers/full/Dockerfile` — the moved blocks, each self-contained and clearly delimited so a copy can be trimmed by deleting a block.
- `docker/layers/full/golangci-lint-wrapper.sh` — moved from `docker/shared/` (the build context is the set directory). Grep for the old path `docker/shared/golangci-lint-wrapper.sh` and update every hit outside `tasks/`; at the time of writing those are `docker/base/Dockerfile`, `scripts/base-source-files.txt` and `docs/entrypoint-and-runtime.md`.
- `docker/layers/full/PSScriptAnalyzerSettings.psd1` — a copy of the repo-root file, which must stay at the root for auto-discovery when linting this repo.
- `docker/layers/full/agent-notes.md`, `docker/layers/full/smoke-probes.txt`.
- `docker/shared/container-agent.md.tmpl` — remove or trim the rows: Core runtime (`php`, `composer`), PowerShell, Build (keep `make`, `patch`, `gcc`, `g++`; move cmake/ninja/pkg-config/dev headers/ccache), Go, .NET, Policy, and the `sqlcmd`/`bcp` part of Databases.
- `commands/smoke-test.sh`, `commands/smoke-test.ps1` — the Stage 1 probe list.
- `scripts/base-source-files.txt`.
- `.github/workflows/native-linux-build.yml` — the base cache key's `hashFiles(...)` list.
- `AGENTS.md` ("PowerShell Linting", "Validating Changes"), `README.md`, `docs/architecture.md`, `docs/smoke-tests.md`, and `docs/entrypoint-and-runtime.md` (it names the wrapper by its `docker/shared/` path where it describes the pre-created caches).

## Implementation notes

- **Layer Dockerfile shape.** `USER root` for the installs, `USER node` before the .NET sentinel `RUN` (the sentinels are per-HOME and must be owned by `node`), and `USER node` at the end. Set the moved `ENV` values here, including the `PATH` additions as `ENV PATH="…:${PATH}"`.
- **Login-shell PATH.** The Go block's `/usr/local/bin` symlinks and `/etc/profile.d/golang-gobin.sh` exist because login shells reset `PATH`; they move with it unchanged.
- **Apt lists.** Each moved apt block keeps its own `apt-get update` and `rm -rf /var/lib/apt/lists/*`.
- **Probes.** Move every Stage 1 probe for a moved tool, keeping order (the golangci-lint fixture probe must precede the three that use its worktree). The Go block's probes are more than the ones that call `go` or `golangci-lint`: the GOBIN probe (`powbox-gobin-probe`, which passes only while `/home/node/go/bin` is on `PATH`) belongs to that block and moves with it. The comment block above the core list explains several of the moved probes (GOBIN, the golangci-lint cache scoping, the .NET sentinels); remove those explanations from both drivers and carry them into the probe file as `#` lines. Add a presence probe for everything the moved blocks install that has none today, because per task 069 the probe file is what turns a missing tool into a failure. At the time of writing that is `pwsh`, the PSScriptAnalyzer module (it must import under `pwsh`), the baked settings file `/usr/local/share/powershell/PSScriptAnalyzerSettings.psd1`, `php`, `composer` and `bcp` (only `sqlcmd -?` is probed). Re-derive the list by comparing what the layer Dockerfile installs against the moved probes rather than trusting this one. The core list keeps the `command -v podman` probe task 069 added; it moves in task 073. Probes in the file need no shell quoting layer: write them as they should reach `sh -ec`.
- **Settings-file parity.** Add a check to a pure-shell suite that `docker/layers/full/PSScriptAnalyzerSettings.psd1` is byte-identical to the repo-root file, so the two cannot drift.
- **Agent notes.** Move the row text rather than rewriting it; the notes are appended under a heading by task 067's staging step, so write them as a table or `###` sections. Keep the corrected PowerShell lint command (`Invoke-ScriptAnalyzer -Path . -Recurse`).
- **Developing powbox itself needs `full`.** Linting this repo's `.ps1` files in-container needs `pwsh` and PSScriptAnalyzer. Say so in `AGENTS.md` "Validating Changes", and note that Tier 0 runs the same recursive PSScriptAnalyzer pass, so a contributor on the lean image is still covered by CI.
- **Exec bit.** `scripts/check-exec-bits.sh` governs tracked scripts; the moved wrapper keeps its mode.
- **Doc counts.** `docs/smoke-tests.md` and `README.md` enumerate probes and stages in prose; grep for the numbers rather than trusting anchors.
- The base recipe digest and the `full` digest both change, so the first `agent-update` after this lands rebuilds everything. That is expected.

## Acceptance criteria

- The lean image (no selector) contains none of: `go`, `gofmt`, `golangci-lint`, `dotnet`, `opa`, `pwsh`, `php`, `composer`, `cmake`, `ninja`, `ccache`, `sqlcmd`, `bcp`; and still contains `gcc`, `make`, `shellcheck`, `shfmt`, `pandoc`, `pdftotext`, `sqlite3`, `node`, `pnpm`, `python3`.
- An image built with `full` selected contains all of them, `dotnet --version` reports a `10.0.x` SDK, and `golangci-lint` still resolves to the cache-scoping wrapper.
- `./commands/smoke-test.sh` passes against the lean image with no layer stage, and against the `full` image with Stage 1b running the moved probes.
- The instruction file rendered in a lean container mentions none of the moved tools as available; in a `full` container the appended section documents all of them.
- `scripts/base-source-files.txt` lists exactly the files the base Dockerfile still COPYs.
- No tracked file outside `tasks/` still references `docker/shared/golangci-lint-wrapper.sh`.
- `docker/layers/full/Dockerfile` installs `dotnet-sdk-10.0`, and no file reintroduces `dotnet-sdk-8.0`.
- `shellcheck`, `shfmt -d`, PSScriptAnalyzer (`-Recurse`), `markdownlint-cli2` on changed Markdown and `./scripts/run-pure-shell-tests.sh` pass; Tier 1 is green for both passes.

## Validation

Static checks and the pure-shell suites run in-container.
The image contents need a host build: ask the maintainer to run `./build.sh all` with and without `.powbox-layers` set to `full`, then `./commands/smoke-test.sh` against each, and to report the two image sizes (`docker image ls`) for the PR description. Tier 1 covers both on the PR.

## Review plan

Diff the removed base blocks against the added layer blocks to confirm each moved verbatim, comments included, and that nothing was dropped or duplicated. Then check the three lists that must agree with the Dockerfiles: the template rows versus the notes, the core probe list versus the probe file, and `scripts/base-source-files.txt` versus the base `COPY` lines.
