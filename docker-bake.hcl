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
  default = "node:24-slim"
}

variable "BASE_SOURCE_DIGEST" {
  default = ""
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
  }
}

group "all" {
  targets = ["base", "agent"]
}

group "default" {
  targets = ["base", "agent"]
}
