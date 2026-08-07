# 002f — Prune drift-prone prose from comments where the code already says it

## Why this task exists

PR #143 corrected five comments that claimed the agent-skills clone was "pinned". It never was: both build drivers fetch a moving `main` and derive `AGENT_SKILLS_COMMIT` from whatever that resolved to, so the variable is provenance stamped after the fact. The wording had been copied from site to site — `docker/agent/Dockerfile`, `docs/architecture.md`, both smoke drivers, and `scripts/test-gh-review-threads.sh` — and each copy had to be found and fixed separately.

The instructive part is not that the claim was wrong. It is that **four of the five sites had no reason to make the claim at all.** The smoke drivers only needed to say which artifact their stage guards; the test header only needed to say where its default helper comes from. Both had inherited a provenance sentence that belongs in exactly one place — beside the `COPY` that performs the bake. Deleting the restatements shrank the surface from five sites to one and removed the possibility of the five drifting apart again. That pass removed six net lines of comment prose — ten counting the now-satisfied bullets it also pruned from task 061 — while making the tree more accurate, not less.

This repo is unusually comment-dense, deliberately so — much of the reasoning genuinely cannot be recovered from the code, and that prose is worth keeping. But density raises the cost of every restatement: a fact asserted in five comments is four opportunities for one of them to go stale, and staleness in a comment is worse than silence because it is trusted. The goal here is not fewer comments; it is fewer **duplicated** and **unnecessarily specific** assertions.

## Scope

**In scope:**

A sweep for comment prose that restates what the adjacent code already shows, or that pins detail more precisely than it needs to. Three patterns, in descending value:

1. **Restated provenance / mechanism.** A comment describing where a file comes from, sitting next to the `COPY`/`git clone`/path that shows it. Keep the *why* (this is vendored because the plugin ships it to non-powbox users) and drop the *what* (it lives at `plugins/dev-skills/bin/`, right above a line naming that path).
2. **The same fact asserted in several files.** Pick the one site that owns it — normally where the mechanism lives, not where it is consumed — and have the others either say nothing or point at it. The pin wording is the worked example; likely siblings are the `.agent-skills-src` staging story, the epoch-refresh story, and the worktree-placement story, each of which is currently described in several places.
3. **Over-specific detail that must be maintained.** Line-number references, exhaustive consumer lists ("used by both agents' `address-review` skills and the `wf-address-review` workflow"), and counts inside prose. Every one is a thing that silently goes wrong when something moves. Prefer a stable identifier over a line number, and a category over an enumeration, unless the enumeration is the point.

**Out of scope:**

- Reducing comment density as a goal in itself. Long explanatory comments that carry real reasoning — `peer-review-run`'s header, `wt-remove`'s refusal rationale, the shadow-mount security notes — are the repo working as intended. Do not touch them except to remove a duplicated assertion.
- Rewriting for style, tone, or brevity where nothing is duplicated or drift-prone.
- Docs under `docs/`. Chapter docs are *supposed* to state things fully; the duplication problem there is between chapters, which is a different and larger question.
- Any behavior change.

## Approach

Do not attempt this as one sweep of the whole tree — the judgment is per-site and a large diff of comment-only changes is close to unreviewable. Work by *claim* instead: pick a fact that is asserted in more than one place, establish which site owns it, and fix that cluster in one commit with the cluster named in the message. The pin cluster (already done, PR #143) is the template.

Candidate clusters to check, in rough order of suspected duplication:

- The `.agent-skills-src` staging clone: what it is, who populates it, what is copied out of it.
- The `.powbox-seeded` marker convention and what a stale marker means.
- Worktree placement and why `.worktrees` must be container-local.
- The tmpfs shadow-mount rationale.
- The `POWBOX_SMOKE_REQUIRE_IMAGE` / self-skip contract, which appears in both smoke drivers, the smoke chapter and the README.

A useful mechanical starting point is to grep for distinctive phrases that appear in more than one file — the pin sweep was found exactly that way, by grepping `pinned` after one instance turned out to be wrong.

## Acceptance criteria

- Each commit addresses one claim cluster, names it in the message, and leaves exactly one site asserting the fact.
- No comment that carried reasoning not derivable from the code loses that reasoning. A reviewer should be able to point at each deletion and say what the reader can now get from the code instead.
- No behavior change and no test change; `shellcheck` (error severity), `shfmt -d`, PSScriptAnalyzer and the pure-shell suite pass unchanged.
- Line-number references that survive the pass are verified accurate at the time of the commit.

## Validation

`./scripts/run-pure-shell-tests.sh` plus the static gates. Since the change is comment-only, the real validation is review: each removed sentence should be defensible as "the code below says this".

## Status

**Not started.** Queued. No prerequisites, and it can be done a cluster at a time whenever a cluster is touched for another reason — which is the cheapest way to land it, since the surrounding context is already loaded. The pin cluster was done this way in PR #143.
