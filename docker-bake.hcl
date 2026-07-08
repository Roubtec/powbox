variable "BASE_IMAGE" {
  default = "powbox-agent-base:latest"
}

variable "CLAUDE_CODE_VERSION" {
  default = "latest"
}

variable "CODEX_VERSION" {
  default = "latest"
}

variable "BASE_SOURCE_IMAGE" {
  default = "node:24-trixie-slim"
}

variable "BASE_SOURCE_DIGEST" {
  default = ""
}

# Digest over the base layer's powbox SOURCE inputs (the base Dockerfile plus the
# files it COPYs; see scripts/base-source-files.txt). Stamped as
# powbox.base.recipe.digest on the base image so check-updates.{sh,ps1} can flag
# a stale base when powbox's own base recipe changes. Distinct from
# BASE_SOURCE_DIGEST (the upstream node:24-trixie-slim digest). Supplied by
# scripts/build-image.{sh,ps1}.
variable "POWBOX_BASE_RECIPE_DIGEST" {
  default = ""
}

# Powbox git commit that built the image's top layers (and the base image when
# building base); baked into the skill ownership marker and the provenance
# labels/files. Supplied by scripts/build-image.{sh,ps1}.
variable "POWBOX_COMMIT" {
  default = "unknown"
}

# Powbox commit that built the Codex install layer. Differs from POWBOX_COMMIT
# when that layer is reused from cache (Claude-only update); the build script
# carries the prior value forward. Stamping it inside the Codex layer would bust
# that layer's cache, so it is recorded only in the top metadata layer.
variable "POWBOX_COMMIT_CODEX" {
  default = "unknown"
}

# Content ID of the base image this agent is built FROM, recorded in the top
# metadata layer. The Codex install layer's parent is the base, so the build
# script compares this against the current base to decide whether a separate
# base rebuild busts that layer (and thus whether POWBOX_COMMIT_CODEX can be
# carried forward). Supplied by scripts/build-image.{sh,ps1}.
variable "POWBOX_BASE_IMAGE_ID" {
  default = ""
}

# HEAD SHA of the Roubtec/agent-skills snapshot whose Codex skills are baked into
# the agent image. Fetched host-side by scripts/build-image.{sh,ps1} into the
# gitignored .agent-skills-src staging dir; recorded on the image so a container
# can tell which agent-skills snapshot it carries (powbox-provenance /
# /home/node/.powbox/agent-skills.commit).
variable "AGENT_SKILLS_COMMIT" {
  default = "unknown"
}

target "_common" {
  context = "."
  output = ["type=docker"]
}

target "base" {
  inherits = ["_common"]
  dockerfile = "docker/base/Dockerfile"
  tags = ["powbox-agent-base:latest"]
  args = {
    BASE_SOURCE_IMAGE = BASE_SOURCE_IMAGE
    BASE_SOURCE_DIGEST = BASE_SOURCE_DIGEST
    POWBOX_BASE_RECIPE_DIGEST = POWBOX_BASE_RECIPE_DIGEST
    POWBOX_COMMIT = POWBOX_COMMIT
  }
}

target "agent" {
  inherits = ["_common"]
  dockerfile = "docker/agent/Dockerfile"
  tags = ["powbox-agent:latest"]
  args = {
    BASE_IMAGE = BASE_IMAGE
    CLAUDE_CODE_VERSION = CLAUDE_CODE_VERSION
    CODEX_VERSION = CODEX_VERSION
    POWBOX_COMMIT = POWBOX_COMMIT
    POWBOX_COMMIT_CODEX = POWBOX_COMMIT_CODEX
    POWBOX_BASE_IMAGE_ID = POWBOX_BASE_IMAGE_ID
    AGENT_SKILLS_COMMIT = AGENT_SKILLS_COMMIT
  }
}

group "all" {
  targets = ["base", "agent"]
}

group "default" {
  targets = ["base", "agent"]
}
