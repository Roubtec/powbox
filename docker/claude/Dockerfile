ARG BASE_IMAGE=powbox-agent-base:latest
FROM ${BASE_IMAGE}

ARG CLAUDE_CODE_VERSION=latest

ENV CLAUDE_CONFIG_DIR=/home/node/.claude
ENV DISABLE_AUTOUPDATER=1

# Intentionally pipes the remote install script directly into bash and does not
# pin a version or verify a checksum. These images are built locally by each
# user as a personal harness, and the goal is always to get the latest agent
# tooling. Reproducibility and supply-chain hardening are out of scope here.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"
RUN rm -rf /home/node/.claude/downloads

COPY --chown=node:node claude-container/assets/container-claude.md /home/node/.claude-container/CLAUDE.md

ENTRYPOINT ["/usr/local/bin/entrypoint-claude.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
