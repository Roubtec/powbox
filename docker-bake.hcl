variable "BASE_IMAGE" {
  default = "powbox-agent-base:latest"
}

variable "CLAUDE_CODE_VERSION" {
  default = "latest"
}

variable "CODEX_VERSION" {
  default = "latest"
}

target "_common" {
  context = "."
  output = ["type=docker"]
}

target "base" {
  inherits = ["_common"]
  dockerfile = "docker/base/Dockerfile"
  tags = ["powbox-agent-base:latest"]
}

target "claude" {
  inherits = ["_common"]
  dockerfile = "docker/claude/Dockerfile"
  tags = ["powbox-claude:latest"]
  args = {
    BASE_IMAGE = BASE_IMAGE
    CLAUDE_CODE_VERSION = CLAUDE_CODE_VERSION
  }
}

target "codex" {
  inherits = ["_common"]
  dockerfile = "docker/codex/Dockerfile"
  tags = ["powbox-codex:latest"]
  args = {
    BASE_IMAGE = BASE_IMAGE
    CODEX_VERSION = CODEX_VERSION
  }
}

group "all" {
  targets = ["base", "claude", "codex"]
}

group "default" {
  targets = ["all"]
}
