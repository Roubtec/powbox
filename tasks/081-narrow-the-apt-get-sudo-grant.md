# 081 — Narrow the `apt-get` sudo grant so it cannot be used as a root shell

**Relates to:** task 079 (egress allow-list), whose exceptions rely on the in-container firewall that the current grant lets an agent remove. Also the sudoers allowlist in `docker/base/Dockerfile`, and the Security section of `AGENTS.md`.

## Why this task exists

The `node` user may run `/usr/bin/apt-get` through sudo with any arguments. apt runs configurable hook commands (`-o APT::Update::Pre-Invoke::=…` and similar), installs local `.deb` files whose maintainer scripts run as root, and opens a pager for some verbs. Any of these gives a root shell in one command. Because the container holds `NET_ADMIN` (and `SYS_ADMIN`), root can then flush the firewall or remount things.

The firewall is not meant to stop a determined adversary. It is a guard against accidents. An agent that mistypes an IP should be blocked, and should have to make a deliberate choice before it can get around the block. One `sudo apt-get -o …` call is too cheap a way around for that purpose. The repo already acknowledges this gap: the shadow-mounts ownership bullet in `docs/entrypoint-and-runtime.md` and the matching comment in `docker/shared/shadow-mounts.sh` treat it as a known route to root, and the `apt-get` entry in the sudoers comment in `docker/base/Dockerfile` calls it a deliberate trade-off.

## Goal

`sudo apt-get update` and `sudo apt-get install -y <package>`, as the agent instructions and layer-set notes document them, keep working unchanged. Package installs from the configured repositories remain possible. The grant no longer accepts options, verbs or arguments that run arbitrary commands as root.

## Scope

In scope:

- A root-owned wrapper reached by the documented `sudo apt-get …` spelling. It accepts a narrow allowlist of verbs, flags and package-name arguments, and rejects everything else with a clear message.
- Pointing the sudoers entry at the wrapper instead of `/usr/bin/apt-get`.
- A hermetic test for the argument policy, and a smoke assertion on the built image (the `sudo -l` contents, a working `sudo apt-get update`, a refused `-o …`) so Tier 1 covers the wiring too. `docs/smoke-tests.md` says where such a check belongs.
- Updating the docs and comments that currently cite apt-get as a route to root or as a deliberate trade-off, and the `AGENTS.md` Security bullet that lists the sudoers contents.
- A quick review of every other sudo-allowed helper for argument- or environment-driven escalation. Fix anything that is cheap to fix; record anything that is not as a follow-up task.

Out of scope:

- Dropping capabilities or otherwise changing the container's security options. Task 075 covers the Podman-only relaxations.
- Restricting which packages may be installed from the configured repositories. Their maintainer scripts run as root by design, and those repositories are trusted.

## Context and references

- `docker/base/Dockerfile`: the sudoers line, the comment above it (whose `apt-get` entry frames the grant as a deliberate trade-off and needs rewording too), and the "root-owned and immutable" helper pattern used by `fix-workspace-perms.sh` and `shadow-mounts.sh`.
- `sudo -l` inside a container: `env_reset` is on, and `secure_path` starts with `/usr/local/sbin`.
- `docker/shared/container-agent.md.tmpl`, "Installing additional packages", and the .NET entry in `docker/layers/full/agent-notes.md`, for the invocations that must keep working.
- `docs/entrypoint-and-runtime.md` (shadow-mounts ownership bullet) and the comment in `docker/shared/shadow-mounts.sh` that reasons from "node already reaches root through apt-get".

## Target files or areas

`docker/base/Dockerfile`, a new wrapper under `docker/shared/` (listed in `scripts/base-source-files.txt` like the other base-baked helpers), a new `scripts/test-*.sh` suite, `AGENTS.md`, `docker/shared/container-agent.md.tmpl` if the user-visible behaviour needs a note, and the docs and comments named above.

## Implementation notes and landmines

- **Path resolution decides what sudo runs.** The user types `sudo apt-get`, and sudo resolves the name through `secure_path`, not the caller's `PATH`. The wrapper must be what that resolves to, and the sudoers entry must name the wrapper's path only. Check that `sudo /usr/bin/apt-get …` is refused.
- **Allowlist, don't denylist.** Accept known-good verbs and flags, and reject everything else: config options (`-o`, `-c`), anything that turns a package argument into a path or URL, flags that disable authentication, and verbs that open a pager or build from source. Base the accepted set on the documented uses, then widen it only where a common, harmless need shows up.
- **The wrapper parses hostile input as root.** Keep it small. Use `set -euo pipefail`, and never pass an argument through a shell evaluation. Run the real binary with a clean, fixed environment, explicit arguments and no interactive prompts: dpkg's conffile prompt offers a shell when a terminal is attached.
- **Reassess the shadow-mounts race.** The ownership-fix race in `shadow-mounts.sh` was accepted partly because apt-get already gave root. Once that route is closed, decide whether the residual race still only narrows a window or now deserves closing. Record the decision either way, and file a follow-up task if it deserves closing but is not cheap.
- **Image builds run `apt-get` as root too.** Layer-set Dockerfiles switch to `USER root` and call `apt-get`, and `full` installs a local `.deb`, which is exactly what the wrapper refuses. A wrapper named `apt-get` in a directory ahead of `/usr/bin` on root's default `PATH` would therefore break those builds, and user-authored sets alike. CI never builds `full`, so this would surface only in the maintainer's host build. Keep the wrapper reachable only through sudo's own resolution for `node` (a node-scoped `secure_path` pointing at a private directory is one way), not through root's `PATH`.
- Changing this requires a base rebuild. No backward-compatibility handling is wanted.

## Acceptance criteria

- The documented `sudo apt-get update && sudo apt-get install -y <package>` works in a rebuilt container, and so does the `.NET` side-by-side SDK install described in the `full` notes.
- The known apt-based escapes (hook options, a local `.deb`, pager-opening verbs) are refused with a message that tells an agent what the wrapper allows.
- The sudoers file grants the wrapper and the existing helper scripts only, mode `0440`, and `AGENTS.md` describes it accurately.
- Every committed layer set still builds, and a build-time `apt-get` as root still reaches the real binary.
- The hermetic suite pins the accept/reject policy, and the docs no longer claim apt-get as a route to root.

## Validation

- The new suite passes under `./scripts/run-pure-shell-tests.sh`, and `shellcheck` / `shfmt -d` are clean. Tier 1 runs the new smoke assertion.
- Host check by the maintainer after a base rebuild:
  - An install of a small package works.
  - A `-o APT::Update::Pre-Invoke::=id` attempt and a `./local.deb` install are refused.
  - An agent session's normal package installs are unaffected.
  - A `full` image builds.

## Review plan

Try to break the wrapper: walk its parser with option-bundling, `--` separators, `=`-joined values, package names that look like paths, and environment variables apt reads. Then check that the docs and the sudoers wiring agree.
