# Agent Session Learnings - 2026-06-14 15:17 UTC

Repository: powbox (/workspace/powbox-6de8ac5a6cdd)
Agent: Claude
Session focus: Test PR #54 (self-hosted `--isolated` mode) on the netcup VPS; fix a smoke-test bug; then fix a separate native-Linux dir-mount ownership bug (PR #55); tmux/zsh host config.
Status: Uncommitted retrospective note

## Summary

- The single highest-signal theme: **powbox has no automated native-Linux check, so an entire class of native-Linux-only defects only surfaces through manual VPS testing.** This session found two more (a smoke-test bug that had never executed, and a dir-mount ownership bug), echoing PRs #51 (exec bits) and #52 (firewall). Windows/WSL — the primary dev environment — masks all of them.
- Secondary: image-gated smoke stages **self-skip silently** when no image is present, which produces false "reviews passing" confidence; and a few small automation rough edges (`prune-volumes.sh` interactive-only, base-baked scripts needing a full rebuild to test, multi-PR image testing needing a throwaway merge).

## Issues and Opportunities

### 1. No native-Linux CI — native-only bugs only caught by manual VPS runs

- Type: automation
- Severity: high
- Evidence: `gh pr view 54/55` showed `statusCheckRollup: []` (no checks). This session surfaced a dir-mount ownership bug and a smoke-test hardlink bug; PRs #51/#52 were the same pattern. All are invisible on Windows/WSL.
- Impact: Each native-Linux regression requires a human to stand up / SSH to a VPS, rebuild the image (~13 min), and run smoke tests by hand. Reviews can pass with real native-Linux breakage.
- Suggested improvement: Add a GitHub Actions workflow on `ubuntu-latest` that runs `./build.sh` and `./commands/smoke-test.sh` (CLI sweep + pg + rootless-podman where the runner allows + self-hosted). Even a build-only + Stage-A job would catch exec-bit/digest/identity regressions; a full job on a self-hosted or privileged runner would catch the rest.
- Repro/trigger: Any change to entrypoint/launcher/Dockerfile/firewall/mount logic merged without a native-Linux run.
- Confidence: observed

### 2. Image-gated smoke stages self-skip silently → false confidence

- Type: workflow
- Severity: high
- Evidence: `scripts/smoke-test-selfhosted.sh` Stage B self-skips when `powbox-agent:latest` is absent (as in the infra container). Its single-mount hardlink check had therefore **never executed** until the first real VPS build — and it failed immediately (`mkdir: Permission denied`): the two hardlink `docker run`s lacked `--user root` that every other Stage-B step had. "Reviews passing" on #54 did not mean Stage B had ever run.
- Impact: A latent, always-failing check sat behind a skip; the PR read as fully validated when a whole stage was unexercised.
- Suggested improvement: Make the umbrella `commands/smoke-test.*` print a prominent end-of-run banner listing which stages were SKIPPED-for-no-image, and surface that in the PR/review checklist. Optionally a `POWBOX_SMOKE_REQUIRE_IMAGE=1` mode that fails instead of skipping, used by CI.
- Repro/trigger: Running smoke tests anywhere the agent image isn't built (the default infra container).
- Confidence: observed

### 3. Recurring native-Linux uid/mode friction class (the #55 bug)

- Type: sandbox
- Severity: high
- Evidence: A dir-mounted repo owned by root (repo under `/root`) is `root:root` inside the container; the `node` (uid 1000) agent could not write it — `touch` and `git pull` failed with EACCES (`cannot open '.git/FETCH_HEAD': Permission denied`). The entrypoint only registered `safe.directory` (silences the *ownership warning*, not write perms). Fixed in PR #55 (entrypoint probes writability and chowns root-owned mounts via a new sudo helper).
- Impact: On any native-Linux host where the mounted repo isn't uid-1000-owned, the agent cannot make a single change — a total blocker that Windows/WSL never shows.
- Suggested improvement: Add a smoke-test stage that dir-mounts a root-owned throwaway repo and asserts the agent can write it (would have caught this and prevents regression). Document the "native-Linux host bind-mount uid" expectation in README/AGENTS.md next to the exec-bit note.
- Repro/trigger: `cc <root-owned-repo>` on native Linux.
- Confidence: observed

### 4. Base-baked entrypoint scripts can't be tested without a full rebuild

- Type: tooling
- Severity: medium
- Evidence: `entrypoint-core.sh`, `seed-workspace.sh`, and the new `fix-workspace-perms.sh` are `COPY`d into the **base** image, so any change needs a base rebuild before it can be exercised end-to-end; the infra container (no image) can't test them at all. Stage B's trick of running `seed-workspace.sh` via `--entrypoint` covers that one script but not the full entrypoint flow.
- Impact: Slow iteration on entrypoint logic (~13 min/rebuild, though cached apt layers helped); the most realistic validation was only possible on the VPS.
- Suggested improvement: A documented dev affordance to bind-mount a host copy of a shared script over its baked path (e.g. `-v $PWD/docker/shared/entrypoint-core.sh:/usr/local/bin/entrypoint-core.sh:ro`) for fast iteration without a rebuild; or a smoke harness that drives the full entrypoint with a custom CMD.
- Repro/trigger: Editing any `docker/shared/*.sh` baked by the base image.
- Confidence: observed

### 5. `prune-volumes.sh` is interactive-only (no `--yes`)

- Type: tooling
- Severity: low
- Evidence: Had to pipe `echo y | ./commands/prune-volumes.sh` to GC orphaned `agent-ws-*`/`agent-podman-*` volumes non-interactively during cleanup.
- Impact: Minor friction for scripted/agent-driven cleanup; easy to mis-handle the prompt.
- Suggested improvement: Add a `--yes`/`-y` (and maybe `--dry-run`) flag to `prune-volumes.{sh,ps1}`.
- Repro/trigger: Any non-interactive volume GC.
- Confidence: observed

### 6. Testing two in-flight PRs on one shared image host needs a manual throwaway merge

- Type: workflow
- Severity: low
- Evidence: To leave the VPS image carrying both PR #54 and PR #55, I created a temp merge branch (`#54 + #55`), pushed it, built from it, then deleted it. The image is a single global `powbox-agent:latest`, so "main + PR A + PR B" isn't buildable without a hand-merge (trivial conflict in the Dockerfile COPY block + AGENTS.md).
- Impact: Extra steps and a transient throwaway branch on origin; risk of leaving the shared host on a non-clean provenance commit.
- Suggested improvement: Minor — a documented "stacked test build" recipe, or accept it. Mostly a note that the shared single-tag image makes concurrent-PR validation awkward.
- Repro/trigger: Validating multiple open PRs that each change the base image on the same host.
- Confidence: observed

### 7. Detached `--shell` launch doesn't reliably capture entrypoint stderr

- Type: tooling
- Severity: low
- Evidence: A detached `--shell` launch (zsh exits immediately with no TTY) left the new helper's `claiming ...` stderr line out of `docker logs`, while an interactive TTY launch routes output to the pty (not the `tee` pipe). I had to run the helper directly via `docker run --entrypoint` to confirm its output.
- Impact: Verifying full-entrypoint output (vs. running a single script) was fiddly; the most reliable signal was indirect (host ownership changing).
- Suggested improvement: Minor — a non-interactive launch/verification path that reliably persists complete entrypoint output to a log would simplify behavioral verification.
- Repro/trigger: Wanting to inspect entrypoint output without an interactive client.
- Confidence: inferred

## Follow-Up Candidates

- Add a CI job (ubuntu-latest) that at minimum builds the image and runs Stage A + the image-gated smoke stages; treat skipped image-stages as a review gate. (Items 1, 2)
- Add a dir-mounted-ownership smoke stage: mount a root-owned repo, assert the agent can write it. (Item 3)
- End-of-run "stages skipped" banner in `commands/smoke-test.*`, plus an optional `POWBOX_SMOKE_REQUIRE_IMAGE=1`. (Item 2)
- `--yes`/`-y` flag for `prune-volumes.{sh,ps1}`. (Item 5)
- Document a bind-mount-over-baked-script dev loop for `docker/shared/*.sh`. (Item 4)
