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
    chromium \
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
    unixodbc-dev \
    unzip \
    vim \
    wget \
    xxd \
    xz-utils \
    zip \
    zsh \
    zstd \
    poppler-utils \
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

# Install PostgreSQL 16 (server + client) from the official PGDG apt repo so the
# major version matches what projects pin (e.g. postgres:16.x) and avoids the
# silent behavior drift Debian trixie's stock 17 would introduce. The contrib
# modules (pg_stat_statements, uuid-ossp, hstore, pgcrypto, …) ship inside the
# `postgresql-16` package on PGDG trixie — there is no separate
# `postgresql-contrib-16` anymore. No daemon is started at build or runtime; the
# baked `pg-dev-up` helper stands up a throwaway loopback cluster on demand for
# integration suites (prisma migrate, `test:db`, etc.) — see docker/shared/pg-dev-up.
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        postgresql-16 \
        postgresql-client-16 \
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
# otherwise agents can apply it with `-Settings <path>`.
COPY PSScriptAnalyzerSettings.psd1 /usr/local/share/powershell/PSScriptAnalyzerSettings.psd1

# Install pnpm
RUN npm install -g pnpm

# Install Marp CLI (Markdown -> slide decks) and Mermaid CLI (`mmdc`, diagram
# source -> SVG/PNG/PDF). Both drive Chromium via puppeteer; skip Puppeteer's
# bundled-Chromium download since the apt-installed system chromium is used at
# runtime (wired up via CHROME_PATH / PUPPETEER_EXECUTABLE_PATH below).
RUN PUPPETEER_SKIP_DOWNLOAD=true npm install -g \
    @marp-team/marp-cli \
    @mermaid-js/mermaid-cli

# Install YAML tooling.
RUN pip3 install --no-cache-dir --break-system-packages yq

# Root-side image setup: drop the PEP 668 externally-managed marker (so agents
# can pip-install without --break-system-packages on this disposable container),
# install scoped sudoers for the node user, set zsh as the default shell, and
# create writable paths before named volumes mount so Docker copies sane
# ownership/permissions onto the volumes. Agent config dirs (.claude, .codex)
# are mode 700 because they will hold auth tokens (.credentials.json,
# config.toml).
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
#   fix-workspace-perms.sh — chowns a dir-mounted /workspace/<slug> to node when the
#                       agent (uid 1000) cannot write it, i.e. when a native-Linux
#                       host bind-mounts a root-owned repo (uid 0; commonly a repo
#                       under /root). Without it git pull/commit and file edits fail
#                       with EACCES. It chowns ONLY a root-owned workspace — a tree
#                       owned by some other foreign host uid is refused and warned
#                       about, never chowned, so a real host user is not locked out.
#                       The script is root-owned and immutable; it canonicalizes its
#                       argument and refuses to act on anything but a direct child of
#                       /workspace/, and is invoked only for a workspace the entrypoint
#                       has already confirmed node cannot write, so it no-ops on
#                       Windows/WSL and on uid-matched Linux hosts.
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
        /workspace \
        /ctx \
    && mkdir -m 700 -p /home/node/.claude /home/node/.codex \
    && chown -R node:node /home/node/.claude /home/node/.codex /home/node/.config /home/node/.local /home/node/.zsh_history_dir /workspace /ctx

# Rootless container engine (Podman) so an in-sandbox agent can build, run, and
# orchestrate its own containers — databases, Adminer, whole service stacks —
# without Docker-in-Docker. Podman runs as the unprivileged `node` user through
# a user namespace, so the blast radius stays inside this container: no
# privileged daemon, no host Docker socket. `podman-docker` provides a `docker`
# command shim; on Debian 13's Podman 5.x the `podman compose` subcommand exists
# and delegates to `podman-compose`, so `podman compose …` and `docker compose …`
# (via the shim) both work — unlike bookworm's Podman 4.3.1, which had no
# `compose` subcommand at all (only the standalone `podman-compose` binary).
# fuse-overlayfs is the rootless storage driver (needs /dev/fuse, passed through
# by launch-agent.sh; entrypoint-core.sh falls back to vfs when it is absent);
# slirp4netns/passt give rootless networking and netavark + aardvark-dns provide
# inter-container DNS. The /etc/subuid + /etc/subgid ranges are what newuidmap
# (from uidmap) maps into the user namespace. Placed low in the file so it never
# busts the expensive gh / mssql / pwsh / npm layers above it.
RUN apt-get update && apt-get install -y --no-install-recommends \
    podman \
    podman-docker \
    podman-compose \
    uidmap \
    fuse-overlayfs \
    slirp4netns \
    passt \
    crun \
    netavark \
    aardvark-dns \
    catatonit \
    && rm -rf /var/lib/apt/lists/* \
    && { grep -q '^node:' /etc/subuid 2>/dev/null || echo 'node:100000:65536' >> /etc/subuid; } \
    && { grep -q '^node:' /etc/subgid 2>/dev/null || echo 'node:100000:65536' >> /etc/subgid; } \
    && touch /etc/containers/nodocker \
    && mkdir -p -m 0755 /etc/containers/containers.conf.d

# Engine defaults for running Podman inside a container without systemd:
# cgroupfs (no systemd cgroup delegation available), the file event logger
# (no journald), and the netavark backend + aardvark-dns for container DNS.
#
# The drop-in dir is pre-created 0755 in the RUN above on purpose: if this COPY
# were left to auto-create it, BuildKit would apply its own --chmod=644 to the
# new directory too, dropping the search bit and making Podman fail to read its
# system config ("open .../10-powbox.conf: permission denied").
COPY --chmod=644 docker/shared/containers.conf /etc/containers/containers.conf.d/10-powbox.conf

# Copy the substrate startup scripts shared by every agent while still root.
# The unified entrypoint, the per-agent setup hooks, and the wt-* worktree
# helpers are intentionally NOT baked here; the agent image
# (docker/agent/Dockerfile) copies them so that editing one rebuilds only that
# cheap layer — see that Dockerfile. The wt-* helpers ride with the agent layer
# because they evolve in lockstep with the agent-layer assets that consume them
# (the *-worktrees skills and the Claude workflows), so an `agent-update` /
# `build.sh agent` rebuild refreshes them without a base rebuild.
COPY --chmod=755 \
    docker/shared/cid \
    docker/shared/init-firewall.sh \
    docker/shared/shadow-mounts.sh \
    docker/shared/detect-shadows.sh \
    docker/shared/shadow-refresh.sh \
    docker/shared/pg-dev-up \
    docker/shared/entrypoint-core.sh \
    docker/shared/seed-image-store.sh \
    docker/shared/seed-workspace.sh \
    docker/shared/fix-workspace-perms.sh \
    /usr/local/bin/

USER node

ENV PNPM_HOME="/home/node/.local/share/pnpm"
ENV PATH="/opt/mssql-tools18/bin:/home/node/.local/bin:${PNPM_HOME}/bin:${PNPM_HOME}:${PATH}"
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

# Rootless Podman keeps its transient runtime state (sockets, runroot) under
# XDG_RUNTIME_DIR. A home-dir path avoids depending on systemd-logind to create
# /run/user/<uid>; entrypoint-core.sh creates it mode 700 at startup.
ENV XDG_RUNTIME_DIR=/home/node/.local/run

# Point Marp / Puppeteer at the system Chromium (PDF, PPTX, PNG output).
# CHROME_NO_SANDBOX=true is appropriate here: the container itself is the
# isolation boundary, and Chromium's user-namespace sandbox is unreliable
# under our default Docker seccomp/AppArmor profile.
ENV CHROME_PATH=/usr/bin/chromium
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium
ENV PUPPETEER_SKIP_DOWNLOAD=true
ENV CHROME_NO_SANDBOX=true

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
# is built outside that script. Declared last so changing the digest only
# rebuilds this trivial metadata layer, never the substrate layers above.
ARG BASE_SOURCE_IMAGE="node:24-trixie-slim"
ARG BASE_SOURCE_DIGEST=""
# Powbox commit that built this base image. Recorded both as an inheritable
# label (child agent images don't override powbox.commit.base, so they expose
# the base's commit automatically) and as a baked file readable in-container.
# The base has a different parent than the agent layers, so its commit can lag
# the agent's. Supplied by scripts/build-image.{sh,ps1}. Declared last so a new
# commit only rebuilds this trivial metadata layer.
ARG POWBOX_COMMIT="unknown"
RUN mkdir -p /home/node/.powbox \
    && printf '%s\n' "${POWBOX_COMMIT}" > /home/node/.powbox/base.commit
LABEL powbox.base.source="${BASE_SOURCE_IMAGE}" \
      powbox.base.source.digest="${BASE_SOURCE_DIGEST}" \
      powbox.commit.base="${POWBOX_COMMIT}"
