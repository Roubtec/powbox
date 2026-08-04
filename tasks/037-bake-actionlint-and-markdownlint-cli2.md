# Task 037 — Bake actionlint and markdownlint-cli2 into the agent image

## Why this task exists

Two linters that the review/task skills lean on are not on `PATH`, so subagents re-install them per worktree, per session:

- `actionlint`: any task touching `.github/workflows/*.yml` triggers a fresh `go install github.com/rhysd/actionlint/cmd/actionlint@latest` (observed repeatedly in kalm2, a CI-heavy repo where workflow files are routine review targets).
- `markdownlint-cli2`: repos that lint `tasks/*.md` fall back to `npx --yes markdownlint-cli2`, paying npx resolution and a network dependency on every lint. Worse, bare `npx` pulls the latest version, which can disagree with a repo's CI pin (kalm2 pins 0.18.1 in CI; newer versions raise MD060 false alarms on pre-existing files), so every subagent has to be told the pin or produce false failures.

Baking both removes a recurring per-session cost across all consumer repos.

## Scope

Included:

- Install `actionlint` (pinned current release, static binary) into the agent image on `PATH`.
- Install `markdownlint-cli2` (pinned version) globally into the agent image on `PATH`.
- Add both to the tooling table in `docker/shared/container-agent.md.tmpl` (and the README/docs tooling mentions if present), with one line each noting: repos that pin a different version in CI should still invoke their pinned version (`npx markdownlint-cli2@<pin>` or a repo wrapper) — the baked copy is the default, not an override of repo policy.
- Extend the image smoke (`scripts/smoke-test-image.sh`) with presence/version checks, matching how other baked tools are asserted.

Out of scope:

- Per-repo lint configuration or pins (each consumer repo owns its own; kalm2's 0.18.1 pin stays a kalm2 concern).
- Adding lint invocations to powbox CI.

## Context and references

- `docker/agent/Dockerfile` — where other CLI tools are installed; follow the existing pin-and-verify pattern (checksum or pinned release URL, as done for other static binaries).
- `docker/shared/container-agent.md.tmpl` — the tooling table agents read.
- `actionlint` ships static Linux binaries per release; `markdownlint-cli2` is an npm package (a global `npm install -g markdownlint-cli2@<version>` in the image layer is sufficient).

## Target files or areas

- `docker/agent/Dockerfile`
- `docker/shared/container-agent.md.tmpl`
- `scripts/smoke-test-image.sh`
- README tooling section if it mirrors the table.

## Implementation notes

- Pin exact versions (release tag for actionlint, npm version for markdownlint-cli2) so image builds are reproducible; note the versions in the Dockerfile comment.
- Keep image-size impact minimal: actionlint is a single small binary; markdownlint-cli2 adds a node_modules subtree under the global prefix — acceptable, but avoid pulling optional deps.
- `markdownlint-cli2 --version` is not a dedicated version option: the CLI treats `--version` as an input glob while its startup banner happens to include the version. The smoke should therefore exercise the PATH binary by linting a real file and verify the exact pin separately through npm's machine-readable global package metadata, rather than parsing presentation output that lints no files.
- This is an image change: full validation needs a host rebuild + smoke run (Tier 1 CI covers image-affecting PRs to main). In-container validation is limited to Dockerfile lint/review.

## Acceptance criteria

- A rebuilt agent image has `actionlint --version` working and `markdownlint-cli2` linting a real Markdown file on `PATH` for the `node` user; npm's global package metadata reports the pinned markdownlint-cli2 version.
- The tooling table documents both, including the repo-pin caveat for markdownlint-cli2.
- Image smoke asserts both binaries.

## Validation

- Host: `./build.sh all` then `scripts/smoke-test-image.sh` passes including the new checks.
- Tier 1 CI green on the PR.

## Review plan

Reviewer checks version pinning and checksum handling match the Dockerfile's existing conventions, the smoke assertions run for both, and the docs wording keeps repo CI pins authoritative.
