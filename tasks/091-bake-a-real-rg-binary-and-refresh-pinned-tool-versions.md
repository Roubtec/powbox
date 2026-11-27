# 091 — Bake a real `rg` binary and refresh the pinned tool versions

**Relates to:** `docker/base/Dockerfile`, `docker/agent/Dockerfile`, `docker/layers/full/Dockerfile`, the tooling rows of `docker/shared/container-agent.md.tmpl` and `docker/layers/full/agent-notes.md`, and the exact-version assertions in `commands/smoke-test.sh` and `commands/smoke-test.ps1`.

## Why this task exists

**`rg` works at the agent's prompt and nowhere else.** The agent's own shell has `rg` only as a function the harness defines. For any child process (a script the agent writes and runs, a project's Makefile or test suite, a peer agent) `command -v rg` fails. Agents write scripts that call `rg` because it worked a moment ago, and the scripts fail. The image bakes `fd` and `bat` in the same spirit, but not ripgrep.

**Pins age.** The baked Markdown linter is behind its current release, and the comment beside its pin still calls it the current latest, a claim that became false with the next upstream release. A project whose CI follows newer releases then sees local and CI results disagree. The other pins have not been looked at as a set.

## Goal

`rg` resolves for any process, in every image, the lean one included. Each pinned tool is at the newest release that does not break its consumers, or stays where it is with the reason written beside the pin. Comments about pins no longer claim currency.

## Direction and constraints

- The maintainer's stance: update freely where a version is compatible. Even a breaking upgrade of a common `full`-layer tool is affordable, because individual projects and outdated guidance can be fixed up afterwards. So do not hold a major version back out of caution. Say in the PR what it breaks. If one such upgrade grows beyond a version bump (a database server major is the obvious candidate), split it into a follow-up task.
- Not every pin means "newest is best". The ShellCheck pin tracks what GitHub's hosted runners ship, so that a clean local pass predicts a clean CI pass. The Acorn pins track the parser bundled in Claude Code. Those move with what they mirror, not with upstream. `podman-compose` is task 025a.
- A pin is stated in more than one place: the Dockerfile, a tooling row in the agent-facing text, and exact-version smoke assertions in Bash and PowerShell. They move together. The comment at the Markdown linter's pin names its set.
- A newer Markdown linter can add rules or change defaults. Check this repository's own tree under it against the base branch. The tree is not clean today, so compare findings and do not expect a zero exit.
- The harness's function and a real binary coexist: the function wins in the agent's shell, and the binary serves everything else. Confirm that nothing else in the image shadows it.
- Changes to the lean image are built and smoke-tested by Tier 1. Changes under `docker/layers/full/` need the maintainer's host build.
