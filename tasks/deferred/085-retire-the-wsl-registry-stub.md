# 085 — Retire the `reg.exe` stand-in once Claude Code stops misdetecting Docker Desktop as WSL

**Relates to:** PR #189, `docker/shared/wsl-reg-stub.sh` (baked as `/mnt/c/Windows/System32/reg.exe`), `POWBOX_WSL_REGISTRY_STUB`, the stub group in `scripts/test-rm-prompt-bypass.sh`, smoke stage 0k, and README "`rm` prompts under bypass mode".

## Why this task exists

Claude Code treats any Linux kernel whose version string contains `microsoft` or `wsl` as WSL. Docker Desktop's WSL2 kernel matches. In that mode Claude Code reads Windows managed-settings policy through a hard-coded `reg.exe` path, and when that read cannot be answered it ignores `CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS` (failing closed). Inside a powbox container there is no Windows to ask, so powbox bakes a stand-in that answers "no such key". The stand-in is a workaround for upstream behaviour. It also hides any Windows-side Claude Code policy, which the container could never read anyway. The misdetection was reported upstream via `/feedback`.

## When it becomes actionable

When a Claude Code release does either of the following:

- it no longer classifies a container on a WSL2 kernel as WSL, for example by checking for `/proc/sys/fs/binfmt_misc/WSLInterop` or `WSL_DISTRO_NAME` rather than the kernel string;
- it offers a supported way to opt out of the Windows registry read.

The stub group's cross-check against the Claude binary in `scripts/test-rm-prompt-bypass.sh` is the tripwire for that change. If it starts failing after a Claude Code update, check here first.

## Direction and constraints

- Prefer the supported mechanism over the stand-in. If the fix is an opt-out, set it at launch next to the waiver in `docker/shared/entrypoint-agent.sh`.
- Remove the stand-in, its compose variable, its test group and smoke stage, and its README and docs paragraphs together, so no doc keeps describing a file that is gone.
- Before removing it, verify on a Docker Desktop host that the startup warning reports the waiver as set.
