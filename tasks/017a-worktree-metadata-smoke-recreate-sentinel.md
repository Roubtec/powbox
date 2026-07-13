# Add a Recreate-Side Bind-Direction Sentinel to the Worktree-Metadata Smoke

## Why this task exists

Task `017` added the durable-worktree-metadata recreate smoke (`scripts/smoke-test-worktree-metadata.sh` / `.ps1`, Stage 6 of the smoke drivers).
Container A (initial launch) proves the durable bind maps the persistent source with an explicit sentinel: it writes a probe file to `<ws>/.worktrees/.gitworktrees/<probe>` and asserts it is visible through `<ws>/.git/worktrees/<probe>`.
Container B (the recreate) does **not** repeat that explicit proof — it relies on the pre-recreate `mountpoint`, non-tmpfs FSTYPE, `git status`, branch, dirty-file, and `.git/worktrees/<slug>/gitdir`-visibility assertions.

During the 017 review the peer flagged this asymmetry (Medium): in principle a recreate-time helper regression that bind-mounts a non-tmpfs copy of the metadata from the **wrong source** could still satisfy every current Container-B assertion, so the stage would pass without explicitly proving `.worktrees/.gitworktrees` is the recreated bind source.

The orchestrator **gated** the finding for the 017 PR — Container B already proves the recreate bind maps the persistent source via `.git/worktrees/<slug>/gitdir` visibility (the metadata Container A wrote exists in exactly one place, `.gitworktrees`, so nothing else can make that entry appear), and no reachable `bind_git_worktrees` regression produces an alternate populated source.
This task captures the **defense-in-depth symmetry** improvement so the recreate side fails closed on bind-source explicitly, matching Container A, without depending on that reachability argument.

## Scope

- Add the same source-side sentinel bind-direction proof Container A uses to **Container B** in both smoke implementations, before (or alongside) the lifecycle survival assertions.
- Keep the existing Container-B assertions (recreate survival of tracked+untracked changes, `git status`, no host-side registrations) unchanged; this is additive rigor.
- Preserve the fail-closed exit-code contract from task `017` (round-3): the sentinel mismatch on the recreate side must be a **hard failure** (non-42 exit → stage FAILURE), never a skip. Skips remain reserved for the independent mount-capability preflight only.

Out of scope: any change to `docker/shared/shadow-mounts.sh`, `wt-common.sh`, or the outer `commands/smoke-test.{sh,ps1}` exit-code mapping (all correct as of task `017`).

## Context and references

- `scripts/smoke-test-worktree-metadata.sh` — Container A's sentinel proof is the model to mirror; Container B's re-bind + survival block is where the check belongs.
- `scripts/smoke-test-worktree-metadata.ps1` — parity implementation (CRLF, ASCII-only; `.sh`/`.ps1` parity is a review gate).
- Task `017` PR #103 review thread (peer round-3 finding) records the original observation and the gating rationale.

## Target files or areas

- `scripts/smoke-test-worktree-metadata.sh` — add the Container-B sentinel check.
- `scripts/smoke-test-worktree-metadata.ps1` — mirror it (strict parity: same probe, same direction, same hard-fail exit).

## Implementation notes

- Reuse Container A's probe convention. On the recreate side the natural proof is symmetrical: after the bind is re-established, write a fresh probe into `<ws>/.worktrees/.gitworktrees/<probe>` and assert it appears at `<ws>/.git/worktrees/<probe>` (and clean the probe on every branch, as Container A does).
- Do not let the new check regress the fail-closed guarantee: a mismatch is a regression → hard failure, not exit 42.
- Keep the inner bash blocks of the `.sh` and `.ps1` logic-identical, as the two files already are.

## Acceptance criteria

- Container B performs an explicit source-side sentinel bind-direction proof equivalent to Container A's, in both `.sh` and `.ps1`.
- A wrong/absent recreate bind source fails the stage (non-42 exit), never skips.
- All pre-existing Container-B survival assertions remain; the mount-capability preflight remains the sole path to a skip.
- `.sh`/`.ps1` parity holds.

## Validation

- In-container: `shellcheck` and `shfmt -d` on the `.sh`; `pwsh -Command "Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1 -Path scripts/smoke-test-worktree-metadata.ps1"`; `scripts/check-exec-bits.sh`.
- Confirm the script still self-skips (exit 42) with no mount privilege in-container.
- Host/CI: the real Stage 6 recreate assertions (including the new Container-B sentinel firing) run on a built image with `CAP_SYS_ADMIN`, on the host or in Tier 1 native-Linux CI.

## Review plan

Reviewer confirms Container B's new sentinel mirrors Container A's direction (source `.gitworktrees` → visible at `.git/worktrees`), that a mismatch is a hard failure rather than a skip, that the preflight remains the only skip path, and that `.sh`/`.ps1` parity is preserved.
