ARG BASE_IMAGE=powbox-agent-base:latest
FROM ${BASE_IMAGE}

ARG CODEX_VERSION=latest

USER root
RUN npm install -g @openai/codex@${CODEX_VERSION}
USER node

ENV CODEX_CONFIG_DIR=/home/node/.codex

COPY --chown=node:node docker/shared/container-agent.md.tmpl /home/node/.agent-container/agent.md.tmpl
RUN date +%s > /home/node/.agent-container/build-epoch

ENTRYPOINT ["/usr/local/bin/entrypoint-codex.sh"]
CMD ["codex", "--dangerously-bypass-approvals-and-sandbox"]
