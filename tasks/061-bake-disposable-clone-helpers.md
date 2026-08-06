# 061 — Bake the disposable-clone helpers (`dc-enter`/`dc-remove`) for the Codex flavor

## Why this task exists

`Roubtec/agent-skills` PR #42 (merged as `885cdee`) shipped
`plugins/dev-skills/bin/dc-enter` and `dc-remove`: a subagent asks for a disposable clone of
the repository it is standing in, gets one absolute path back, and can wreck it without
reaching the checkout every sibling worktree shares. They exist because a reviewer subagent
asked to verify a claim empirically ran `rm -rf ./*` in the shared main checkout — it had
tried to build a throwaway clone first, the clone step was piped to `tail` so `set -e` never
saw it fail, and execution continued in the repository root.

**Claude gets them for free; Codex does not.** The dev-skills plugin's `bin/` is on the Bash
tool's PATH while the plugin is enabled, so a Claude container resolves `dc-enter` as soon as
the marketplace clone refreshes past `885cdee`, with no powbox change at all. The Codex
palette is seeded from `.agent-skills-src/codex/dev-skills/skills/`, which carries no `bin/`
— which is exactly why `gh-review-threads` is baked into `/usr/local/bin` rather than left to
the plugin path. Today powbox has **no** reference to `dc-enter`, `dc-remove`, `DC_ROOT` or
`DC_AGENT` anywhere, so a Codex agent's `command -v dc-enter` will never resolve and its
empirical-verification guidance degrades silently, forever — which is the exact failure the
helpers exist to prevent.

This is a bake-and-document task, not an authoring one. The helpers are net-new in
agent-skills with no powbox original to reconcile against; their own headers already state
the arrangement powbox is expected to adopt: bake **from that copy**, keep `DC_ROOT` as the
placement interface, and import `scripts/test-dc-helpers.sh` as the consumer contract with
`DC_ENTER_HELPER`/`DC_REMOVE_HELPER` retargeting it at the baked artifacts. Follow that
rather than inventing a second arrangement — it is the same shape `gh-review-threads` already
uses (task 013), so this task is mostly "one more helper through the existing pipe".

## Scope

**In scope:**

1. Agent-layer baking of both helpers from the pinned `.agent-skills-src` clone, plus the
   `.dockerignore` re-includes that let them into the build context.
2. Moving `AGENT_SKILLS_COMMIT` to a snapshot at or past `885cdee`, so the staging clone
   actually carries the two files.
3. Discoverability: a `container-agent.md.tmpl` entry and the `README.md` baked-helper list.
4. In-image contract coverage: import `scripts/test-dc-helpers.sh` and wire it into
   `commands/smoke-test.{sh,ps1}` and the Tier-0/Tier-1 routing notes, plus `command -v`
   presence probes for both helpers.
5. A decision, recorded in the task's PR description or a comment, on `DC_ROOT` and
   `DC_AGENT` — see "Placement and scope decisions" below. Either may end as "leave unset,
   the default is already right"; what is out of bounds is leaving it unconsidered.

**Out of scope:**

- **Authoring or editing the helpers.** They are vendored; a behaviour change belongs in
  agent-skills, in the same PR as its `scripts/test-dc-helpers.sh` update.
- **The consumer-side pointer.** The `command -v dc-enter` guidance in the skills that
  compose subagent prompts is agent-skills **task 017 item 5** (five prompt-composing skills,
  their Codex mirrors, and both dynamic workflows). Powbox no longer keeps in-tree skills, so
  it cannot write that wording. Note the ordering: until 017 lands, nothing *directs* a
  subagent to the helper, and this task only makes it resolvable when something does. The two
  are independent — 017's degradation clause is required to work before the helper exists,
  and this task is required to work before 017 can stop degrading — so neither blocks the
  other.
- The Claude flavor's PATH route. It already works through the plugin's `bin/`; adding a
  baked copy for Claude alone would create two artifacts to keep in sync for no gain. The
  baked copy serves both, and a Claude container that resolves the plugin's copy first is
  running the same file from the same pin.
- Base-image changes.

## Placement and scope decisions

Both have measured defaults that already behave correctly on powbox. Record the decision;
do not add configuration for its own sake.

- **`DC_ROOT`** — `dc-enter` resolves `$DC_ROOT`, else `$TMPDIR`, else `/tmp`, and refuses any
  root inside the invoking repository or its worktrees. Measured in a current agent
  container: `TMPDIR` is unset and `/tmp` is the overlay filesystem (disk-backed, not a
  size-capped tmpfs), so clones already land container-local and outside `/workspace`, which
  is the placement powbox would set the variable to express. A `.git` of ~34 MB clones
  cheaply even with the default `--no-hardlinks`. So the honest default is "do not set it",
  and the reason to set it anyway would be to relocate clones onto a persistent volume or to
  make the intent explicit rather than incidental.
- **`DC_AGENT`** — the scope component is `$DC_AGENT`, else `$CONTAINER_NAME`, else the login
  name. Powbox sets `CONTAINER_NAME`, so clones are already scoped per container and per
  invoking worktree. The one case it does not separate is a `codex exec` peer invoked from
  inside a Claude container: it inherits the same `CONTAINER_NAME` and therefore the same
  scope. The failure mode there is a **refusal**, not corruption — `dc-enter` refuses a slug
  whose clone already exists precisely so a concurrent sibling's verification is never pulled
  out from under it — so this is an ergonomics question, not a safety one. If it is worth
  fixing, powbox already keys per-agent state under `/home/node/.agent-container/<agent>/`
  and can export `DC_AGENT` from the same value in the agent hooks.

## Target files or areas

- `docker/agent/Dockerfile` — the `gh-review-threads` `COPY --chmod=755` (~line 170) and its
  rationale comment (~lines 161-169). Add both helpers. The existing comment's reasoning
  applies verbatim — single source of truth in agent-skills, baked from the same pinned clone
  that feeds the Codex palette, refreshed in lockstep whenever the pin moves — so extend it
  rather than writing a parallel paragraph.
- `.dockerignore` (~lines 10-19) — the block that excludes the whole `.agent-skills-src`
  staging tree and re-includes only what the Dockerfile COPYs. Add
  `!.agent-skills-src/plugins/dev-skills/bin/dc-enter` and `…/dc-remove`, and update the
  comment, which currently says the Dockerfile copies "two subpaths".
- `docker-bake.hcl` (~lines 55-59) — `AGENT_SKILLS_COMMIT` must name a snapshot at or past
  `885cdee`; the build will otherwise fail on a missing COPY source, which is the right
  failure but a confusing one if the pin is forgotten.
- `docker/shared/container-agent.md.tmpl` — a "Git and GitHub" entry beside the
  `gh-review-threads` bullet (~line 61). Agents act on what this file tells them, so it is
  the single highest-value edit here. Say what the helper is *for* (a place to verify a claim
  empirically that is safe to wreck), the calling convention `DC="$(dc-enter <slug>)"` with
  stdout carrying only the path, that a worktree is **not** a substitute because it shares
  `.git`, that an existing slug is refused rather than reused so `dc-remove <slug>` (or
  `--replace`) frees it, and that `GIT_DIR` and its relatives override `git -C` so they must
  be cleared in the caller's own shell before using the path.
- `README.md` (~line 543) — the image-baked-helpers sentence that currently reads
  "`wt-bootstrap`, `wt-enter`, `wt-remove` (plus `gitcat` … and `gh-review-threads` …)".
- `scripts/test-dc-helpers.sh` — imported from agent-skills as the consumer contract, exactly
  as `scripts/test-gh-review-threads.sh` was. It already honours `DC_ENTER_HELPER` and
  `DC_REMOVE_HELPER`, needs only Bash, git and coreutils, and builds every fixture under one
  `mktemp -d` root, so it runs hermetically in-image. It is large (~2270 lines, 609 checks);
  import it whole rather than excerpting, since a partial copy is a contract that silently
  stops covering things.
- `commands/smoke-test.sh` — a new Stage 0 letter beside Stage 0b (~lines 47-68), same shape:
  `docker run --rm -v "${ROOT_DIR}:/repo:ro" -e DC_ENTER_HELPER=/usr/local/bin/dc-enter -e
  DC_REMOVE_HELPER=/usr/local/bin/dc-remove --entrypoint /bin/bash "$IMAGE"
  /repo/scripts/test-dc-helpers.sh`, with the image-absent skip. Pick the next free letter
  rather than assuming one: the existing set is 0a, 0b, 0d, 0f, 0g. Add
  `command -v dc-enter` and `command -v dc-remove` to the Stage 1 presence list (~line 340).
- `commands/smoke-test.ps1` — the mirrored stage and its image-absent warning (~lines 72-83).
- `scripts/run-pure-shell-tests.sh` (~lines 12, 22) and `AGENTS.md` (~line 59) — the imported
  suite needs the baked helpers, so it joins `test-gh-review-threads.sh` in the explicit
  Tier-1 route rather than the source runner. `AGENTS.md` currently says "Three
  environment-dependent suites"; that count changes.
- `.github/workflows/native-linux-build.yml` (~line 79) — the path filter list that names
  `scripts/test-gh-review-threads.sh`.

## Implementation notes

- **Bake both helpers, not just `dc-enter`.** `dc-remove` is how a slug is freed after a
  refusal, and its whole safety argument is that it can only delete what `dc-enter` created
  and marked. Shipping the creator without the reaper leaves agents to `rm -rf` the path
  themselves, which is the class of command this pair exists to keep them away from.
- **Import the suite verbatim first, then adapt only the header.** The `gh-review-threads`
  precedent is instructive as a warning: powbox's copy and the upstream one now differ by
  ~860 lines. Upstream acknowledges the arrangement ("Powbox keeps an importable copy as its
  bake-time consumer-contract check; keep fixture and contract changes reconcilable"), but
  the further the two drift the less the powbox copy proves about the artifact it guards. So
  import unmodified, keep the diff to the header's sync note, and say in that note which
  agent-skills commit it came from.
- The helpers need git 2.36+ (`worktree list --porcelain -z`), which the image already
  exceeds; no base-image work.
- `scripts/check-exec-bits.sh` governs files kept in this repo. These are copied with
  `--chmod=755` from a staging clone, so the exec bit is set at COPY time and the guard has
  nothing to assert — worth a sentence in the Dockerfile comment so a later reader does not
  go looking for the missing check.
- Do not add a fallback path for containers built before this lands. The consumer wording
  that 017 owns already degrades on `command -v`, which is the whole point of that clause.

## Acceptance criteria

- A fresh agent image (`./build.sh agent` or `agent-update`) has `/usr/local/bin/dc-enter`
  and `/usr/local/bin/dc-remove` on PATH, executable, byte-identical to the pinned
  agent-skills snapshot.
- `DC="$(dc-enter probe)"` inside a container prints one absolute path on stdout, outside
  `/workspace` and outside the invoking repository, and `git -C "$DC" update-ref -d
  refs/heads/<something>` leaves the invoking repository's refs untouched.
- `dc-remove probe` removes exactly that path, and refuses a directory it did not create.
- The imported `scripts/test-dc-helpers.sh` passes in-image against the **baked** artifacts
  (not the mounted `/repo` copies) and is wired into `commands/smoke-test.{sh,ps1}` with the
  image-absent skip; `command -v dc-enter` and `command -v dc-remove` are in the Stage 1
  presence list.
- `container-agent.md.tmpl` and `README.md` mention both helpers, and the tmpl entry states
  the calling convention, the worktree-is-not-a-substitute point, the slug-refusal behaviour,
  and the `GIT_DIR` caveat.
- `AGENTS.md`, `scripts/run-pure-shell-tests.sh` and the CI path filter agree on where the
  new suite runs, with the suite count in `AGENTS.md` corrected.
- `AGENT_SKILLS_COMMIT` names a snapshot carrying both helpers.
- The `DC_ROOT`/`DC_AGENT` decisions are recorded with their reasoning, whichever way they go.
- `shellcheck` (error severity), `shfmt -d`, and the CI static guards pass.

## Validation

Build the agent image, then in a fresh container: confirm both helpers on PATH; run the
round trip above from the repository root and again from a nested subdirectory and from a
linked worktree (the last is the one that catches a source derived from `--git-common-dir`
instead of the invoking worktree); confirm a second `dc-enter probe` is refused rather than
handing back the wrecked clone, and that `dc-remove probe` then frees the slug. Run
`commands/smoke-test.sh` and confirm the new stage executes and would fail against a
deliberately broken baked helper (temporarily `COPY` a stub to prove the stage is not
vacuous). Confirm a Codex container sees the helpers too, since that is the flavor this task
exists for.

## Review plan

Reviewer confirms: both helpers are baked from the pinned staging clone with the
`.dockerignore` re-includes present and the pin moved; the imported suite runs against the
baked artifacts rather than the mounted source, is routed to Tier 1 rather than the pure-shell
runner, and would fail on a stubbed helper; the presence probes cover both; the tmpl entry
tells an agent enough to use the helper correctly without reading the script; README, AGENTS
and the CI path filter are consistent; nothing in this PR edits the helpers themselves or
authors consumer-side skill wording that belongs to agent-skills task 017; and the
`DC_ROOT`/`DC_AGENT` decisions are stated with reasons rather than defaulted silently.

## Status

**Not started.** Unblocked — agent-skills PR #42 is merged, so the helpers exist at a pinnable
commit. Independent of agent-skills task 017 item 5 in both directions; landing this first
simply means the helper is resolvable before anything points at it.
