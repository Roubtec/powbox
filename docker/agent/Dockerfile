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
# Intentionally runs the remote install script without pinning a checksum.
# These images are built locally by each user as a personal harness and the
# goal is always the latest agent tooling. Pinning a concrete
# CLAUDE_CODE_VERSION (which agent-update does) is what lets Docker rebuild only
# this layer when Claude — and only Claude — has a new release. Downloaded to a
# file first (not `curl | bash`) so a failed download fails the build instead
# of being masked by the pipeline's exit status.
RUN curl -fsSL -o /tmp/claude-install.sh https://claude.ai/install.sh \
    && bash /tmp/claude-install.sh "${CLAUDE_CODE_VERSION}" \
    && rm /tmp/claude-install.sh
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

# The Codex seed dir is the UNION of the in-tree powbox-specific Codex skills
# COPYed just above (enable-worktrees, session-learnings) and the shared
# dev-workflow skills that live in Roubtec/agent-skills. The agent-skills tree is
# fetched host-side by scripts/build-image.{sh,ps1} into the gitignored
# .agent-skills-src staging dir (credentials never enter the image; the HTTPS
# clone URL keeps working unchanged when that repo flips public) and COPYed to a
# scratch dir here. The RUN then merges the two sets and FAILS THE BUILD LOUDLY
# on any name collision — after task 015a there must be none. A standalone
# `docker build` without a populated .agent-skills-src will fail at this COPY,
# which is intentional: the documented build path is `./build.sh agent`.
COPY --chown=node:node .agent-skills-src/codex/dev-skills/skills/ /tmp/agent-skills-codex/
RUN set -eu; \
    dest=/home/node/.agent-container/codex/skills; \
    for d in /tmp/agent-skills-codex/*/; do \
        name="$(basename "$d")"; \
        if [ -e "$dest/$name" ]; then \
            echo "FATAL: agent-skills Codex skill '$name' collides with an in-tree powbox Codex skill of the same name; resolve the duplicate before baking." >&2; \
            exit 1; \
        fi; \
        cp -a "$d" "$dest/$name"; \
    done; \
    rm -rf /tmp/agent-skills-codex
# build-epoch is a monotonic stamp that gates instruction/skill re-seeding.
# build-commit records the powbox commit that built these top (asset/claude)
# layers; the .powbox-seeded skill marker copies it so a seeded skill can be
# traced back to its source. Referencing POWBOX_COMMIT here busts only this
# metadata layer (and the cheap entrypoint COPY below it) when the commit
# changes — the expensive Codex/Claude install layers sit ABOVE and are never
# affected. POWBOX_COMMIT is supplied by scripts/build-image.{sh,ps1}; the
# default keeps standalone `docker build` working.
#
# /home/node/.powbox/{claude,codex}.commit are the in-container provenance
# surface (base.commit is inherited from the base image). claude.commit equals
# POWBOX_COMMIT (this top layer); codex.commit is POWBOX_COMMIT_CODEX, which the
# build script carries forward when the Codex install layer is reused so it
# reflects the commit that actually built Codex — not this build's commit. It is
# NOT stamped inside the Codex layer itself, which would bust that layer's cache.
# AGENT_SKILLS_COMMIT is the HEAD SHA of the agent-skills snapshot whose Codex
# skills were baked above; /home/node/.powbox/agent-skills.commit is its
# in-container provenance surface (read by powbox-provenance), so a container can
# tell which snapshot it carries. Recorded in this cheap metadata layer, never
# stamped inside the Codex install layer (which would bust its cache).
ARG POWBOX_COMMIT=unknown
ARG POWBOX_COMMIT_CODEX=unknown
ARG AGENT_SKILLS_COMMIT=unknown
RUN date +%s%N | tee /home/node/.agent-container/claude/build-epoch /home/node/.agent-container/codex/build-epoch >/dev/null \
    && printf '%s\n' "${POWBOX_COMMIT}" | tee /home/node/.agent-container/claude/build-commit /home/node/.agent-container/codex/build-commit >/dev/null \
    && mkdir -p /home/node/.powbox \
    && printf '%s\n' "${POWBOX_COMMIT}" > /home/node/.powbox/claude.commit \
    && printf '%s\n' "${POWBOX_COMMIT_CODEX}" > /home/node/.powbox/codex.commit \
    && printf '%s\n' "${AGENT_SKILLS_COMMIT}" > /home/node/.powbox/agent-skills.commit

# --- Entrypoint, setup hooks, and worktree helpers ---------------------------
# The unified entrypoint seeds every agent at startup, then execs the primary.
# Each agent's hook is baked here so editing a hook rebuilds only this layer.
# The wt-* worktree helpers (plus the gitcat cross-branch reader and the
# gh-review-threads safe review-thread fetcher) are baked here too — not in the
# base image — because they evolve in lockstep with the agent-layer assets that
# reference them (the worktree-running skills, the address-review skills, and the
# Claude workflows). Keeping them in this layer means the documented
# `agent-update` / `build.sh agent` path (which reuses an existing base image
# unless --pull) refreshes the helpers along with the skills/workflows, instead
# of leaving stale /usr/local/bin copies behind a base that was not rebuilt.
COPY --chmod=755 \
    docker/shared/entrypoint-agent.sh \
    docker/shared/entrypoint-claude-hook.sh \
    docker/shared/entrypoint-codex-hook.sh \
    docker/shared/seed-skills.sh \
    docker/shared/seed-claude-plugins.sh \
    docker/shared/powbox-provenance \
    docker/shared/gitcat \
    docker/shared/gh-review-threads \
    docker/shared/wt-bootstrap \
    docker/shared/wt-enter \
    docker/shared/wt-remove \
    /usr/local/bin/

# --- Provenance labels -------------------------------------------------------
# Host-side introspection surface (docker image inspect / docker inspect). The
# base commit is inherited from the base image's powbox.commit.base label.
# powbox.base.image.id records the exact base this image was built FROM: the
# Codex install layer's parent, so the build script compares it against the
# current base to tell whether that layer will be reused (same base AND same
# Codex version) and thus whether to carry its commit forward. Declared last so
# they only rebuild this trivial metadata layer.
ARG POWBOX_BASE_IMAGE_ID=""
LABEL powbox.commit.claude="${POWBOX_COMMIT}" \
      powbox.commit.codex="${POWBOX_COMMIT_CODEX}" \
      powbox.base.image.id="${POWBOX_BASE_IMAGE_ID}" \
      powbox.codex.version="${CODEX_VERSION}" \
      powbox.claude.version="${CLAUDE_CODE_VERSION}" \
      powbox.agent-skills.commit="${AGENT_SKILLS_COMMIT}"

ENTRYPOINT ["/usr/local/bin/entrypoint-agent.sh"]
CMD ["claude", "--dangerously-skip-permissions"]
