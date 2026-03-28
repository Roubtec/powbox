ARG BASE_IMAGE=powbox-agent-base:latest
FROM ${BASE_IMAGE}

ARG CODEX_VERSION=latest

USER root
RUN npm install -g @openai/codex@${CODEX_VERSION}
USER node

ENV CODEX_CONFIG_DIR=/home/node/.codex

COPY --chown=node:node codex-container/assets/container-agents.md /home/node/.codex-container/AGENTS.md

ENTRYPOINT ["/usr/local/bin/entrypoint-codex.sh"]
CMD ["codex", "--dangerously-bypass-approvals-and-sandbox"]
