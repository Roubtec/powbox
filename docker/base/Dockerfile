FROM node:24-slim

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bc \
    bat \
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
    php8.2-cli \
    php8.2-xml \
    php8.2-mbstring \
    php8.2-curl \
    php8.2-zip \
    php8.2-intl \
    php8.2-sqlite3 \
    php8.2-bcmath \
    php8.2-mysql \
    php8.2-pgsql \
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

# Install sqlcmd tooling for Azure SQL workflows.
RUN curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
    | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/debian/12/prod bookworm main" \
    > /etc/apt/sources.list.d/microsoft-prod.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends mssql-tools18 \
    && ln -sf /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd \
    && ln -sf /opt/mssql-tools18/bin/bcp /usr/local/bin/bcp \
    && rm -rf /var/lib/apt/lists/*

# Install pnpm
RUN npm install -g pnpm

# Install YAML tooling.
RUN pip3 install --no-cache-dir --break-system-packages yq

# Disable PEP 668 externally-managed marker so agents can pip-install without
# needing --break-system-packages (this is a disposable container, not a workstation).
RUN rm -f /usr/lib/python*/EXTERNALLY-MANAGED

# Give 'node' user sudo access for firewall setup, workspace shadow mounts,
# and runtime package installs.
#
# Security rationale: the three allowed commands are intentionally scoped.
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
#                       to the host — not an escape vector.
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
RUN echo "node ALL=(ALL) NOPASSWD: /usr/local/bin/init-firewall.sh, /usr/local/bin/shadow-mounts.sh, /usr/bin/apt-get" > /etc/sudoers.d/node \
    && chmod 0440 /etc/sudoers.d/node

# Set zsh as the default shell for the node user.
RUN usermod --shell /bin/zsh node

# Create writable paths before named volumes are mounted so Docker copies sane ownership.
RUN mkdir -p \
    /home/node/.claude \
    /home/node/.codex \
    /home/node/.config/gh \
    /home/node/.config/git \
    /home/node/.local/bin \
    /home/node/.local/share/pnpm/store \
    /home/node/.zsh_history_dir \
    /workspace \
    /ctx \
    && chown -R node:node /home/node/.claude /home/node/.codex /home/node/.config /home/node/.local /home/node/.zsh_history_dir /workspace /ctx

# Copy startup scripts while still root.
COPY --chmod=755 docker/shared/init-firewall.sh /usr/local/bin/init-firewall.sh
COPY --chmod=755 docker/shared/shadow-mounts.sh /usr/local/bin/shadow-mounts.sh
COPY --chmod=755 docker/shared/detect-shadows.sh /usr/local/bin/detect-shadows.sh
COPY --chmod=755 docker/shared/shadow-refresh /usr/local/bin/shadow-refresh
COPY --chmod=755 docker/shared/entrypoint-core.sh /usr/local/bin/entrypoint-core.sh
COPY --chmod=755 docker/shared/entrypoint-claude.sh /usr/local/bin/entrypoint-claude.sh
COPY --chmod=755 docker/shared/entrypoint-codex.sh /usr/local/bin/entrypoint-codex.sh
COPY --chmod=755 docker/shared/entrypoint-claude-hook.sh /usr/local/bin/entrypoint-claude-hook.sh
COPY --chmod=755 docker/shared/entrypoint-codex-hook.sh /usr/local/bin/entrypoint-codex-hook.sh
COPY --chmod=755 docker/shared/cid /usr/local/bin/cid

USER node

ENV PNPM_HOME="/home/node/.local/share/pnpm"
ENV PATH="/opt/mssql-tools18/bin:/home/node/.local/bin:${PNPM_HOME}:${PATH}"
ENV SHELL=/bin/zsh
ENV GIT_CONFIG_GLOBAL=/home/node/.config/git/config

# Keep pnpm's store outside the workspace because the workspace bind mount and
# the shared pnpm volume are different filesystems.
RUN pnpm config --global set store-dir /home/node/.local/share/pnpm/store \
    && pnpm config --global set package-import-method copy

# Install Oh My Zsh and the shared zsh configuration.
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
COPY --chown=node:node docker/shared/.zshrc /home/node/.zshrc

WORKDIR /home/node
