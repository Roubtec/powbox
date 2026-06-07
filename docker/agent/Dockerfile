# Unified agent image: both Claude Code and Codex are installed in one image.
# Which one runs is chosen at container start via PRIMARY_AGENT; the other stays
# installed and seeded so either agent can invoke the other in-container (e.g.
# delegated reviews) without Docker-in-Docker. See docs/unified-agent-image.md.
#
# Layer order is deliberate. Codex (updated less often, smaller) is installed
# BELOW Claude (updated most often, larger). Bumping CLAUDE_CODE_VERSION then
# busts only the Claude layer plus the cheap asset/entrypoint layers above it,
# so the common case re-pulls just the Claude layer. Bumping CODEX_VERSION
# rebuilds the Claude layer on top as a side effect — an accepted, rarer cost.
# `agent-update` pins concrete versions per binary so Docker rebuilds the
# minimum set of layers for any single update.
ARG BASE_IMAGE=powbox-agent-base:latest
FROM ${BASE_IMAGE}

# --- Codex (lower layer: updated less often) ---------------------------------
ARG CODEX_VERSION=latest
ENV CODEX_CONFIG_DIR=/home/node/.codex
USER root
RUN npm install -g @openai/codex@${CODEX_VERSION}
USER node

# --- Claude (upper layer: updated most often) --------------------------------
ARG CLAUDE_CODE_VERSION=latest
ENV CLAUDE_CONFIG_DIR=/home/node/.claude
ENV DISABLE_AUTOUPDATER=1
# Intentionally pipes the remote install script directly into bash without
# pinning a checksum. These images are built locally by each user as a personal
# harness and the goal is always the latest agent tooling. Pinning a concrete
# CLAUDE_CODE_VERSION (which agent-update does) is what lets Docker rebuild only
# this layer when Claude — and only Claude — has a new release.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"
RUN rm -rf /home/node/.claude/downloads

# --- Per-agent seed assets ---------------------------------------------------
# Each agent gets its own seed directory under /home/node/.agent-container/<agent>
# so the two never collide. The setup hooks read their assets from there via
# AGENT_SEED_DIR. Kept above both install layers and keyed only on file content,
# so editing skills/statusline rebuilds just this cheap layer.
COPY --chown=node:node docker/shared/container-agent.md.tmpl /home/node/.agent-container/claude/agent.md.tmpl
COPY --chown=node:node docker/claude/agent-container/ /home/node/.agent-container/claude/
COPY --chown=node:node docker/shared/container-agent.md.tmpl /home/node/.agent-container/codex/agent.md.tmpl
COPY --chown=node:node docker/codex/agent-container/ /home/node/.agent-container/codex/
# build-epoch is a monotonic stamp that gates instruction/skill re-seeding.
# build-commit records the powbox commit that built these top (asset/claude)
# layers; the .powbox-seeded skill marker copies it so a seeded skill can be
# traced back to its source. Referencing POWBOX_COMMIT here busts only this
# metadata layer (and the cheap entrypoint COPY below it) when the commit
# changes — the expensive Codex/Claude install layers sit ABOVE and are never
# affected. POWBOX_COMMIT is supplied by scripts/build-image.{sh,ps1}; the
# default keeps standalone `docker build` working.
ARG POWBOX_COMMIT=unknown
RUN date +%s%N | tee /home/node/.agent-container/claude/build-epoch /home/node/.agent-container/codex/build-epoch >/dev/null \
    && printf '%s\n' "${POWBOX_COMMIT}" | tee /home/node/.agent-container/claude/build-commit /home/node/.agent-container/codex/build-commit >/dev/null

# --- Entrypoint + every agent's setup hook -----------------------------------
# The unified entrypoint seeds every agent at startup, then execs the primary.
# Each agent's hook is baked here so editing a hook rebuilds only this layer.
COPY --chmod=755 \
    docker/shared/entrypoint-agent.sh \
    docker/shared/entrypoint-claude-hook.sh \
    docker/shared/entrypoint-codex-hook.sh \
    docker/shared/seed-skills.sh \
    /usr/local/bin/

ENTRYPOINT ["/usr/local/bin/entrypoint-agent.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
