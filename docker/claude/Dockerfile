ARG BASE_IMAGE=powbox-agent-base:latest
FROM ${BASE_IMAGE}

ARG CLAUDE_CODE_VERSION=latest

ENV CLAUDE_CONFIG_DIR=/home/node/.claude
ENV DISABLE_AUTOUPDATER=1

RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"
RUN rm -rf /home/node/.claude/downloads

COPY --chown=node:node claude-container/assets/container-claude.md /home/node/.claude-container/CLAUDE.md

ENTRYPOINT ["/usr/local/bin/entrypoint-claude.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
