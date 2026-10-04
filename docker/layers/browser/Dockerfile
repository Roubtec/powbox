# The "browser" layer set: a headless browser stack on top of the lean base,
# for document and diagram work such as a Marp deck to PDF, a Mermaid diagram
# to SVG, or an HTML page printed to PDF. Select it by writing `browser` into
# .powbox-layers (see .powbox-layers.example); scripts/build-image.{sh,ps1}
# then bake this file into powbox-agent-layers:latest and build the agent image
# on it. It is a set of its own, not a layer under `full`: a build selects
# exactly one set.
#
# It installs Chromium, Marp CLI, Mermaid CLI and the Playwright CLI (the
# browser stack below, which the `full` set installs from an identical copy),
# and nothing for Podman or PostgreSQL. It is also the set Tier 1 CI builds and
# smokes, so it is what exercises the base -> layers -> agent chain there (the
# maintainer's `full` set is never built in CI).
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
#   - set no powbox.* labels: the bake target and the base stamp them. The
#     one exception is a capability label for a tool the set installs (such
#     as powbox.podman, which full's Podman block declares): declare it in
#     that tool's block, so deleting the block deletes the label;
#   - keep the default backslash escape (no `# escape=` naming another).
ARG BASE_IMAGE=powbox-agent-base:latest
FROM ${BASE_IMAGE}

USER root

# >>> browser stack. Two committed sets install it, `browser` and `full`, from
# identical copies of the blocks down to the closing marker: a build selects
# one set, so they cannot share a layer. scripts/test-layer-sets.sh fails when
# the two copies differ, so edit both together.
# ---------------------------------------------------------------------------
# Chromium
# ---------------------------------------------------------------------------
# The system Chromium: Marp CLI and Mermaid CLI below drive it through
# Puppeteer, and it is a headless browser in its own right (screenshots, HTML
# printed to PDF, smoke-testing a local dev server).
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Marp CLI and Mermaid CLI
# ---------------------------------------------------------------------------
# Install Marp CLI (Markdown -> slide decks) and Mermaid CLI (`mmdc`, diagram
# source -> SVG/PNG/PDF). Both drive Chromium via puppeteer; skip Puppeteer's
# bundled-Chromium download since the apt-installed system chromium is used at
# runtime (wired up via CHROME_PATH / PUPPETEER_EXECUTABLE_PATH below).
RUN PUPPETEER_SKIP_DOWNLOAD=true npm install -g \
    @marp-team/marp-cli \
    @mermaid-js/mermaid-cli

# ---------------------------------------------------------------------------
# Playwright CLI
# ---------------------------------------------------------------------------
# Install Playwright (browser automation) globally so an agent has the
# `playwright` CLI (screenshot / pdf / codegen / install) without an install
# step. This is CLI-only on purpose: global npm packages are not on Node's
# module path and no NODE_PATH is set (it would make every global package
# resolvable from any repo and mask undeclared dependencies), so programmatic
# `require('playwright')` still needs a local install, which then finds the
# shared browsers. Only the ~19 MB npm package is baked:
# PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD stops the postinstall from pulling ~656 MB of
# browser builds, which would go stale almost immediately -- Playwright keys its
# browsers by revision and bumps that revision nearly every minor release (1.52
# -> 1169, 1.55 -> 1187, 1.58 -> 1208, 1.60 -> 1223, 1.62 -> 1234), so a baked
# revision only ever serves repos pinned to that one minor. Browsers are instead
# downloaded on demand into the PERSISTENT PLAYWRIGHT_BROWSERS_PATH the launcher
# points at .worktrees, so each version is fetched once per container and then
# survives recreation. A repo with its own pinned playwright/@playwright/test
# dependency still resolves its local copy first; this global one is the
# no-repo fallback.
#
# Note the system chromium below CANNOT stand in for Playwright's browsers:
# Playwright exposes no browser-executable env override (there is no
# PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH), and a headless launch resolves to a
# chrome-headless-shell binary the distro package does not ship at all. Only an
# explicit executablePath in launch() reuses it, which is a per-repo code change.
RUN PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install -g playwright

# ---------------------------------------------------------------------------
# Browser environment
# ---------------------------------------------------------------------------
# Point Marp / Puppeteer at the system Chromium (PDF, PPTX, PNG output).
# CHROME_NO_SANDBOX=true is appropriate here: the container itself is the
# isolation boundary, and Chromium's user-namespace sandbox is unreliable
# under our default Docker seccomp/AppArmor profile.
ENV CHROME_PATH=/usr/bin/chromium
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
ENV PUPPETEER_SKIP_DOWNLOAD=true
ENV CHROME_NO_SANDBOX=true

# Playwright deliberately gets NO baked PLAYWRIGHT_BROWSERS_PATH: unset means
# its own default (~/.cache/ms-playwright), which is the right container-
# ephemeral fallback for a non-dev folder that mounts no .worktrees volume. The
# launcher supplies the persistent path per project, exactly as it does for
# NUGET_PACKAGES / GOMODCACHE / CCACHE_DIR.
# <<< browser stack

USER node
