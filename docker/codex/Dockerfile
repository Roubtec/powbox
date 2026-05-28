ARG BASE_IMAGE=powbox-agent-base:latest
FROM ${BASE_IMAGE}

ARG CODEX_VERSION=latest

USER root
RUN npm install -g @openai/codex@${CODEX_VERSION}
USER node

ENV CODEX_CONFIG_DIR=/home/node/.codex

COPY --chown=node:node docker/shared/container-agent.md.tmpl /home/node/.agent-container/agent.md.tmpl
COPY --chown=node:node docker/codex/agent-container/ /home/node/.agent-container/
RUN date +%s%N > /home/node/.agent-container/build-epoch

# Codex-specific entrypoint shim and setup hook. Baked here (not in the base
# image) so that editing either script rebuilds only this layer. The base image
# carries the shared entrypoint-core.sh that this shim execs.
COPY --chmod=755 \
    docker/shared/entrypoint-codex.sh \
    docker/shared/entrypoint-codex-hook.sh \
    /usr/local/bin/

ENTRYPOINT ["/usr/local/bin/entrypoint-codex.sh"]
CMD ["codex", "--dangerously-bypass-approvals-and-sandbox"]
