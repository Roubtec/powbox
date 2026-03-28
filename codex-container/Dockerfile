FROM node:24-slim

ARG CODEX_VERSION=latest

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bc \
    bat \
    bzip2 \
    build-essential \
    git \
    curl \
    ca-certificates \
    fd-find \
    file \
    gettext-base \
    gnupg \
    htop \
    iputils-ping \
    sudo \
    fzf \
    less \
    lsof \
    make \
    netcat-openbsd \
    openssh-client \
    patch \
    python3 \
    python3-pip \
    shfmt \
    shellcheck \
    sqlite3 \
    strace \
    zsh \
    procps \
    nano \
    vim \
    xxd \
    jq \
    iptables \
    iproute2 \
    dnsutils \
    rsync \
    tree \
    unzip \
    unixodbc-dev \
    wget \
    xz-utils \
    zip \
    zstd \
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

# Install YAML tooling and shell formatter.
RUN pip3 install --no-cache-dir --break-system-packages yq

# Give 'node' user sudo access (for firewall setup at container start)
RUN echo "node ALL=(ALL) NOPASSWD: /usr/local/bin/init-firewall.sh" > /etc/sudoers.d/node \
    && chmod 0440 /etc/sudoers.d/node

# Set zsh as default shell for the node user
RUN usermod --shell /bin/zsh node

# Create writable paths before named volumes are mounted so Docker copies sane ownership.
RUN mkdir -p \
    /home/node/.codex \
    /home/node/.config/gh \
    /home/node/.local/bin \
    /home/node/.local/share/pnpm/store \
    /workspace/node_modules \
    /home/node/.zsh_history_dir \
    /home/node/.config/git \
    && chown -R node:node /home/node/.codex /home/node/.local /home/node/.zsh_history_dir /home/node/.config /workspace

# Copy startup scripts while still root
COPY --chmod=755 init-firewall.sh /usr/local/bin/init-firewall.sh
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

# Switch to non-root user
USER node

# Environment
ENV CODEX_CONFIG_DIR=/home/node/.codex
ENV PNPM_HOME="/home/node/.local/share/pnpm"
ENV PATH="/opt/mssql-tools18/bin:/home/node/.local/bin:$PNPM_HOME:$PATH"
ENV SHELL=/bin/zsh
ENV GIT_CONFIG_GLOBAL=/home/node/.config/git/config

# Keep pnpm's content-addressable store outside /workspace. The workspace bind
# mount and the shared pnpm volume are different filesystems, so pnpm otherwise
# falls back to a project-local .pnpm-store.
RUN pnpm config --global set store-dir /home/node/.local/share/pnpm/store \
    && pnpm config --global set package-import-method copy

# Install Oh My Zsh (unattended), Codex CLI, and the custom .zshrc
RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
RUN npm install -g @openai/codex@${CODEX_VERSION}
COPY --chown=node:node assets/.zshrc /home/node/.zshrc
COPY --chown=node:node assets/container-agents.md /home/node/.codex-container/AGENTS.md

# Default workspace
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["codex", "--dangerously-bypass-approvals-and-sandbox"]
