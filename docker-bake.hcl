# The agent image's parent: powbox-agent-base:latest, or
# powbox-agent-layers:latest when a layer set is selected. Supplied by
# scripts/build-image.{sh,ps1}.
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

# Powbox git commit that built the image's top layers (and the base or layer-set
# image when building those); baked into the skill ownership marker and the
# provenance labels/files. Supplied by scripts/build-image.{sh,ps1}.
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

# Signature of the image this agent is built FROM (its layer chain plus the
# environment, SHELL, WORKDIR and USER a RUN inherits), recorded as
# powbox.parent.signature. The Codex install layer sits directly on that parent,
# so the build script compares this against the next build's parent to decide
# whether that layer is reused (and thus whether POWBOX_COMMIT_CODEX can be
# carried forward). Supplied by scripts/build-image.{sh,ps1}.
variable "POWBOX_PARENT_SIGNATURE" {
  default = ""
}

# powbox.commit.base of the base image, written to
# /home/node/.powbox/base.commit by the agent's top metadata layer and
# restamped as the agent's own label (the base image carries its commit as a
# label only). Supplied by
# scripts/build-image.{sh,ps1}.
variable "POWBOX_COMMIT_BASE" {
  default = "unknown"
}

# The selected layer set (see .powbox-layers.example): its directory, which is
# the layers target's whole build context, its name, and the digest of that
# directory from scripts/layers-digest.{sh,ps1}. Supplied by
# scripts/build-image.{sh,ps1}.
variable "POWBOX_LAYERS_DIR" {
  default = "docker/layers/full"
}

variable "POWBOX_LAYERS_SET" {
  default = "full"
}

variable "POWBOX_LAYERS_DIGEST" {
  default = ""
}

# Image ID of the powbox-agent-base:latest the layer-set image is built FROM,
# recorded as powbox.layers.base.id so the next build can tell whether the base
# moved underneath it. Not to be confused with POWBOX_PARENT_SIGNATURE, which
# describes the agent's own parent. Supplied by scripts/build-image.{sh,ps1}.
variable "POWBOX_LAYERS_BASE_ID" {
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
    POWBOX_COMMIT_BASE = POWBOX_COMMIT_BASE
    POWBOX_PARENT_SIGNATURE = POWBOX_PARENT_SIGNATURE
    AGENT_SKILLS_COMMIT = AGENT_SKILLS_COMMIT
  }
}

# Optional image between the base and the agent. Built only when a layer set is
# selected, so the groups below leave it out and the build script names it
# explicitly. The labels are set here, not in the set's own Dockerfile, so a
# custom Dockerfile cannot omit them; they enter no build step's cache key, and
# the agent image inherits them.
target "layers" {
  inherits = ["_common"]
  context = POWBOX_LAYERS_DIR
  dockerfile = "Dockerfile"
  tags = ["powbox-agent-layers:latest"]
  args = {
    BASE_IMAGE = "powbox-agent-base:latest"
  }
  labels = {
    "powbox.layers.set" = POWBOX_LAYERS_SET
    "powbox.layers.digest" = POWBOX_LAYERS_DIGEST
    "powbox.layers.base.id" = POWBOX_LAYERS_BASE_ID
    "powbox.commit.layers" = POWBOX_COMMIT
  }
}

group "all" {
  targets = ["base", "agent"]
}

group "default" {
  targets = ["base", "agent"]
}
