FROM node:24-trixie-slim

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bc \
    bat \
    bash-completion \
    bubblewrap \
    bzip2 \
    build-essential \
    ca-certificates \
    curl \
    dnsutils \
    fd-find \
    file \
    fzf \
    gettext-base \
    git \
    gnupg \
    htop \
    iproute2 \
    iptables \
    iputils-ping \
    jq \
    less \
    lsof \
    make \
    nano \
    netcat-openbsd \
    openssh-client \
    pandoc \
    patch \
    procps \
    python3 \
    python3-pip \
    rsync \
    shellcheck \
    shfmt \
    sqlite3 \
    strace \
    sudo \
    time \
    tree \
    unzip \
    vim \
    wget \
    xxd \
    xz-utils \
    zip \
    zsh \
    zstd \
    poppler-utils \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && rm -rf /var/lib/apt/lists/*

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Silence npm's "New major version of npm available!" notice, image-wide. npm is
# whatever the node:24 base bundles (it moves with Node, not independently), so
# the notice is unactionable noise at the end of every `npm install -g` in the
# base, layer-set and agent builds and in every in-session npm call. Declared
# here, right before the first npm install, so it covers those layers without
# busting the apt layers above. An ENV (not a baked npmrc) so a session can
# still opt back in by overriding it.
ENV NPM_CONFIG_UPDATE_NOTIFIER=false

# Install pnpm. Unpinned: pnpm v10+ honors a project's `packageManager` field
# and transparently runs that pinned version (e.g. pnpm@11.x under this global
# 12.x), so the global one only matters for repos without a pin.
RUN npm install -g pnpm

# Install YAML tooling.
RUN pip3 install --no-cache-dir --break-system-packages yq

# Root-side image setup: drop the PEP 668 externally-managed marker (so agents
# can pip-install without --break-system-packages on this disposable container),
# install scoped sudoers for the node user, set zsh as the default shell, and
# create writable paths before named volumes mount so Docker copies sane
# ownership/permissions onto the volumes. Agent config dirs (.claude, .codex)
# are mode 700 because they will hold auth tokens (.credentials.json,
# config.toml). /run/powbox is created node-owned so entrypoint-core.sh (running
# as node) can write the per-boot workspace-source marker map there — the file
# that lets heal-/fix-workspace-perms.sh classify sensitivity on the launcher's
# true absolute host source rather than the layout-dependent mountinfo field 4
# (see sensitive-host-path.sh and tasks/009); /run is a plain image directory
# here (no tmpfs is mounted over it), so the build-time dir survives to runtime.
#
# Sudoers security rationale — the three allowed commands are intentionally
# scoped:
#
#   init-firewall.sh  — sets up iptables rules that restrict outbound traffic to
#                       an allowlist; the script itself is root-owned and immutable
#                       inside the image so agents cannot modify the firewall rules.
#
#   shadow-mounts.sh  — mounts tmpfs over workspace subdirectories (e.g. nested
#                       node_modules in monorepos) to separate container-native
#                       binaries from host-native binaries.  The script is root-
#                       owned and immutable; it refuses to mount outside /workspace/.
#                       tmpfs mounts are container-namespace-scoped and invisible
#                       to the host — not an escape vector.  Requires CAP_SYS_ADMIN
#                       at runtime (Docker's seccomp profile blocks the mount syscall
#                       without it); granted in compose.shared.yml.
#
#   fix-workspace-perms.sh — re-owns root-owned entries of a dir-mounted /workspace/<slug>
#                       to node when the agent (uid 1000) otherwise cannot write them.
#                       Covers two native-Linux cases: a fully root-owned repo (uid 0;
#                       commonly under /root), and a MIXED-ownership repo whose root is
#                       node-owned but which hides nested root-owned files (e.g. a host
#                       `sudo git pull` re-owning .git/objects/*, refs and changed
#                       working-tree files while leaving the top dir node-owned). Without
#                       it git pull/commit and file edits fail with EACCES (or
#                       `insufficient permission for adding an object to repository
#                       database`). It acts only when the workspace root is owned by root
#                       OR node, re-owning ONLY find -uid 0 entries — a tree (or nested
#                       file) owned by some other foreign host uid is left alone (and a
#                       foreign-owned root is refused with remedies), so a real host user
#                       is not locked out. The script is root-owned and immutable; it
#                       canonicalizes its argument and refuses to act on anything but a
#                       direct child of /workspace/. The entrypoint invokes it for a
#                       workspace node cannot write OR that a short-circuiting uid-0 scan
#                       shows contains nested root-owned entries, so it no-ops on
#                       Windows/WSL and on uid-matched Linux hosts with no uid-0 entries.
#                       That probe/scan/heal DECISION (whether and with what path to call
#                       this helper) lives in heal-workspace-perms.sh, baked beside this one;
#                       it runs as node (NOT sudo-allowlisted — its only privileged action is
#                       sudo'ing THIS helper) so the entrypoint and the dir-mount smoke share
#                       one decision unit. BOTH refuse outright to chown a mount whose HOST
#                       bind-mount source is a system or home directory (/, /root, /home/<user>,
#                       /etc, ...): a `cc`/`cx` launched by mistake from ~ would otherwise re-own
#                       the whole home tree to node and break sshd's StrictModes chain on ~/.ssh,
#                       locking the user out of the host. That shared predicate (and the
#                       /proc/self/mountinfo source lookup the root helper trusts because node
#                       cannot forge it) lives in sensitive-host-path.sh, sourced by both.
#
#   apt-get           — allows agents to install system packages at runtime for
#                       anything not pre-installed in the base image. apt-get runs
#                       package maintainer scripts as root, so this is a deliberate
#                       trade-off: the goal is a productive sandbox, not a hardened
#                       multi-tenant environment. Arbitrary root commands (iptables,
#                       shell, etc.) are NOT in the sudoers list. The threat being
#                       guarded against is firewall circumvention, not local
#                       privilege escalation — these containers are single-user and
#                       disposable, and container escape is unrelated to sudo scope.
RUN rm -f /usr/lib/python*/EXTERNALLY-MANAGED \
    && echo "node ALL=(ALL) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/shadow-mounts.sh, /usr/local/bin/fix-workspace-perms.sh, /usr/bin/apt-get" > /etc/sudoers.d/node \
    && chmod 0440 /etc/sudoers.d/node \
    && usermod --shell /bin/zsh node \
    && mkdir -p \
        /home/node/.config/gh \
        /home/node/.config/git \
        /home/node/.local/bin \
        /home/node/.local/share/pnpm/store \
        /home/node/.zsh_history_dir \
        /run/powbox \
        /workspace \
        /ctx \
    && mkdir -m 700 -p /home/node/.claude /home/node/.codex \
    && chown -R node:node /home/node/.claude /home/node/.codex /home/node/.config /home/node/.local /home/node/.zsh_history_dir /run/powbox /workspace /ctx

# Install Typst, the PDF engine for pandoc (`pandoc in.md -o out.pdf
# --pdf-engine=typst`), so the lean image can produce PDFs with no headless
# browser and no LaTeX. A minimal TeX set that serves pandoc was measured at
# 189 MB (402 MB with XeTeX for Unicode text) against Typst's single 40 MB
# binary, whose fonts are embedded, so it needs no font package and no HOME.
#
# Pinned to 0.13.1 on purpose, not the latest: Debian trixie's pandoc
# (3.1.11.1) writes a default Typst template that Typst 0.14 and 0.15 reject
# with `error: font fallback list must not be empty`, while 0.13.1 renders it
# out of the box. Re-test pandoc's PDF output before bumping either tool; the
# Stage 1 smoke probe builds a PDF through this engine, so a bump that breaks
# the template fails there. Fetched as the statically linked musl release
# tarball from GitHub and sha256-pinned per arch, like the OPA binary in the
# `full` layer set; bump the version and both sums together
# (https://github.com/typst/typst/releases). Only the binary is extracted. The
# fetch carries the same --retry ... --retry-all-errors --http1.1 flags as
# the other release downloads, which ride out the HTTP/2 stream resets hosted
# CI runners see; the sha256 check keeps a retried download honest.
RUN TYPST_VERSION=0.13.1 \
    && case "$(dpkg --print-architecture)" in \
        amd64) typst_arch=x86_64 \
               typst_sha256=7d214bfeffc2e585dc422d1a09d2b144969421281e8c7f5d784b65fc69b5673f ;; \
        arm64) typst_arch=aarch64 \
               typst_sha256=4f5b7ee6e57fb639019ee0f6bffcf940edad228ede6ff5269a9f05a1544ceed4 ;; \
        *) echo "no pinned Typst checksum for architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
    && curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors --http1.1 -o /tmp/typst.tar.xz \
        "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-${typst_arch}-unknown-linux-musl.tar.xz" \
    && echo "${typst_sha256}  /tmp/typst.tar.xz" | sha256sum -c - \
    && tar -C /usr/local/bin --strip-components=1 --no-same-owner \
        -xJf /tmp/typst.tar.xz "typst-${typst_arch}-unknown-linux-musl/typst" \
    && rm /tmp/typst.tar.xz \
    && chmod 0755 /usr/local/bin/typst

# Copy the substrate startup scripts shared by every agent while still root.
# The unified entrypoint, the per-agent setup hooks, and the wt-* worktree
# helpers are intentionally NOT baked here; the agent image
# (docker/agent/Dockerfile) copies them so that editing one rebuilds only that
# cheap layer — see that Dockerfile. The wt-* helpers ride with the agent layer
# because they evolve in lockstep with the agent-layer assets that consume them
# (the worktree-running skills and the Claude workflows), so an `agent-update` /
# `build.sh agent` rebuild refreshes them without a base rebuild.
#
# NOTE: every file COPYd into the base image is also listed in
# scripts/base-source-files.txt, which drives the powbox.base.recipe.digest
# staleness check. When you add or remove a base COPY here, update that manifest
# to match (agent-layer files must NOT be listed there).
COPY --chmod=755 \
    docker/shared/cid \
    docker/shared/init-firewall.sh \
    docker/shared/shadow-mounts.sh \
    docker/shared/detect-shadows.sh \
    docker/shared/shadow-refresh.sh \
    docker/shared/pnpm-shadow-wrapper.sh \
    docker/shared/pnpm-shadow-doctor \
    docker/shared/entrypoint-core.sh \
    docker/shared/seed-workspace.sh \
    docker/shared/fix-workspace-perms.sh \
    docker/shared/heal-workspace-perms.sh \
    docker/shared/sensitive-host-path.sh \
    /usr/local/bin/

# Route pnpm (and its `pn` short alias) through the shadow wrapper so a package
# scaffolded mid-session gets its node_modules tmpfs-shadowed before pnpm can
# populate it on the host bind mount. The wrapper delegates to the real global
# pnpm; `pnpx`/`pnx` (dlx) are left alone — they don't write workspace
# node_modules. Must run after `npm install -g pnpm` created these symlinks and
# after the wrapper was copied above.
RUN ln -sf /usr/local/bin/pnpm-shadow-wrapper.sh /usr/local/bin/pnpm \
    && ln -sf /usr/local/bin/pnpm-shadow-wrapper.sh /usr/local/bin/pn

USER node

ENV PNPM_HOME="/home/node/.local/share/pnpm"
ENV PATH="/home/node/.local/bin:${PNPM_HOME}/bin:${PNPM_HOME}:${PATH}"
# The agent harnesses' Bash tools spawn $SHELL non-interactively, so default it
# to bash: the models' command prior is bash/POSIX (word-splitting, 0-indexed
# arrays), and a one-shot tool call gains nothing from zsh's interactive features
# — running under zsh just wastes turns on no-word-split / 1-indexed-array
# surprises. Humans still get zsh: it stays the login shell (`usermod` above) and
# is what `launch-agent --shell` opens. EDITOR is set here (not in a shell rc) so
# both shells, and any non-shell child process, inherit it.
ENV SHELL=/bin/bash
ENV EDITOR=nano
ENV GIT_CONFIG_GLOBAL=/home/node/.config/git/config

# Default pnpm store location and import method. `auto` lets pnpm hardlink (or
# reflink-clone) package files from the store into node_modules when the store
# and node_modules share one mount, and transparently fall back to copying when
# they don't — so it is never worse than the old forced `copy`, and is far
# cheaper when they are co-located. The launcher overrides store-dir per project
# at startup to a path inside the worktrees volume (see entrypoint-core.sh) so
# that per-worktree installs hardlink instead of copying. This store-dir is only
# the fallback default for that runtime override.
RUN pnpm config --global set store-dir /home/node/.local/share/pnpm/store \
    && pnpm config --global set package-import-method auto

# Install Oh My Zsh and the shared shell configuration. zsh is the human login
# shell (and what `--shell` opens); bash is the default $SHELL the agent tools
# spawn — both rc files are baked so either shell is configured.
RUN CHSH=no RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
COPY --chown=node:node docker/shared/.zshrc /home/node/.zshrc
COPY --chown=node:node docker/shared/.bashrc /home/node/.bashrc

WORKDIR /home/node

# Record the upstream base image and the exact digest this image was built FROM
# so `agent-check-updates` can compare it against the current registry digest
# and report whether a newer base is available. Both are supplied by
# scripts/build-image.{sh,ps1}; the defaults are sane fallbacks when the image
# is built outside that script.
#
# The four per-build ARGs below feed only the closing LABEL block. Keep every
# RUN, COPY and ADD above them: a step declared after an ARG is keyed on its
# value, so a step down here would run again at every new commit and give the
# base a new top filesystem layer, which reinstalls everything built on it (the
# layer-set image's set, the agent's Codex, linter and Claude layers). With
# labels only, a bake at a new commit reuses every filesystem layer: the layer
# chain stays the same, while the image ID, which covers the config, changes.
ARG BASE_SOURCE_IMAGE="node:24-trixie-slim"
ARG BASE_SOURCE_DIGEST=""
# Powbox commit that built this base image, recorded as an inheritable label
# only. The agent image restamps powbox.commit.base, and writes the in-container
# /home/node/.powbox/base.commit, from this label as the build script reads it
# off the base. The base has a different parent than the agent layers,
# so its commit can lag the agent's. Supplied by scripts/build-image.{sh,ps1}.
ARG POWBOX_COMMIT="unknown"
# Digest over this base layer's powbox SOURCE inputs (this Dockerfile plus every
# file it COPYs — see scripts/base-source-files.txt). Distinct from
# powbox.base.source.digest above, which is the UPSTREAM node:24-trixie-slim
# digest: this one changes whenever powbox's own base recipe changes.
# check-updates.{sh,ps1} recompute it from the working tree and mark the base
# stale on a mismatch, so adopting any base-layer change (e.g. self-hosted mode)
# triggers a base rebuild with no manual step. Supplied by
# scripts/build-image.{sh,ps1} via scripts/base-source-digest.{sh,ps1}.
#
# Cache-key note: this ARG feeds a label only, below every expensive apt/COPY
# layer, so it adds no filesystem layer and no step is keyed on it. It is
# stamped on the BASE image only — nothing in the agent Dockerfile's Codex
# install layer references it, so it cannot bust that layer's cache (the
# constraint documented in docs/skills-refresh-and-provenance.md). When the base
# recipe actually changes the base is rebuilt and re-parents the agent's Codex
# layer anyway. A new value on its own changes the base image ID but not its
# layer chain.
ARG POWBOX_BASE_RECIPE_DIGEST=""
# powbox.base.selfhosted is a static capability flag (Approach B): the clone path
# for self-hosted (--isolated) mode lives entirely in THIS base layer
# (seed-workspace.sh + entrypoint-core.sh's clone call), so its presence proves
# the image can self-host. It is inherited by the agent image built FROM this one
# (the agent Dockerfile does not override it), and launch-agent.{sh,ps1} fail fast
# on --isolated when it is absent instead of starting in an empty checkout.
LABEL powbox.base.source="${BASE_SOURCE_IMAGE}" \
      powbox.base.source.digest="${BASE_SOURCE_DIGEST}" \
      powbox.base.recipe.digest="${POWBOX_BASE_RECIPE_DIGEST}" \
      powbox.base.selfhosted="1" \
      powbox.commit.base="${POWBOX_COMMIT}"
