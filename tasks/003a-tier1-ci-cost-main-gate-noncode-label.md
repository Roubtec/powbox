# Task 003a — Trim Tier 1 native-Linux CI cost: gate to main-targeting PRs + honor the `non-code` label

Follow-up from the PR #62 review (native-Linux CI). **Re-scoped on 2026-06-20** after a maintainer decision round: the original framing ("warm the Tier 1 base cache from the default branch so sibling PRs hit a warm base") is **declined** — see "Cache warmup: declined" below. What replaces it is two small, cheaper CI-trigger optimizations the maintainer chose instead — both cut Tier 1 (and some Tier 0) runs outright rather than speeding up a run that still happens.

Original review thread (now resolved in a different direction):
- https://github.com/Roubtec/powbox/pull/62#discussion_r3446296402 (codex, P2) — the base cache is only seeded on `pull_request` runs, so its scope cannot be restored by other PRs.

## Decision (maintainer, 2026-06-20)

**1. Gate Tier 1 to PRs that target `main`.** Add `branches: [main]` to the `pull_request` trigger in `.github/workflows/native-linux-build.yml`, alongside the existing `paths` filter. GitHub's `on.pull_request.branches` filters on the PR's **base (target)** branch, so only PRs merging into `main` run the heavy image build + smoke. Stacked PRs whose base is a parent feature branch (e.g. open PR #65 → base `task/005a-…`) skip Tier 1 and iterate fast; each branch still gets exactly one Tier 1 run at the moment it is retargeted to `main` and rebased — i.e. right before it can compromise `main`, never on intermediate iterations.

**2. Honor the existing `non-code` repo label to skip CI.** The repo already defines a `non-code` label ("Changes to docs and tasks that do not need rebuild and a full CI run") that nothing currently reads. Wire it: add `labeled, unlabeled` to the `pull_request` `types` on **both** Tier 0 (`.github/workflows/native-linux-ci.yml`) and Tier 1, and gate each job with `if: ${{ !contains(github.event.pull_request.labels.*.name, 'non-code') }}`. A docs/tasks-only PR carrying the label then skips even the fast Tier 0 static guards; toggling the label re-evaluates. This is the real win on Tier 0 (which otherwise runs on every PR); on Tier 1 it is belt-and-suspenders, since Tier 1's path + base-branch gate already skips docs PRs.

**Cache warmup: declined.** Keep the existing same-PR base cache (`actions/cache@v4` in `native-linux-build.yml`) exactly as-is. The first push of an image PR warms *that PR's* cache and runs in parallel with human review, so the one-time cold base build is hidden behind review latency — acceptable and ergonomic. The former options A/B (a `push: {branches:[main]}` warmup job, or a separate `native-linux-base-warmup.yml`) only existed to share the cache *across* PRs and would add recurring `main`-branch CI for a saving the maintainer does not feel; **considered & declined.** Optionally fold in the former option C: a one-line in-workflow comment noting the cache is same-PR-by-design, so a future reader does not mistake the cross-PR gap for a bug.

## Notes / interactions to honor in the implementation

- **Auto-retarget on parent merge.** When a parent PR merges, GitHub auto-retargets its child PRs to `main`. That base change fires a `pull_request` event whose action (`edited`) is **not** in the default `types` (`opened, synchronize, reopened`), so the base-branch gate will *not* fire Tier 1 on the retarget alone. In the `rebase-stack` flow the child is rebased onto `main` and force-pushed, which fires `synchronize` and triggers Tier 1 then — so the run still happens before merge. Do **not** add `edited` to the types just to catch a bare retarget: `edited` also fires on every title/body edit, re-running Tier 1 needlessly. Accept the rebase-push as the trigger and document this so it is not read as a bug.
- **Branch protection.** `main` is currently **unprotected** (no required status checks), so a job skipped via the `non-code` `if:` cannot block a merge — no skip-tolerant "status gate" shim is needed today. Keep the forward-looking note already in the Tier 1 header: if these checks are ever marked *required*, the label-skip (and the path/branch gates) need a check that tolerates skipped runs, or docs/`non-code` PRs will hang on a required job that never starts.

## Acceptance

- A PR whose base is **not** `main` (a stacked child, e.g. #65 → `task/005a-…`) does **not** trigger Tier 1; a PR targeting `main` that changes an image-affecting path **does** (unchanged from today for the main-targeting case).
- A PR carrying the `non-code` label skips **both** Tier 0 and Tier 1; removing the label re-enables them on the next triggering event.
- No cross-PR / default-branch warmup job is added; the existing same-PR base cache still works, and (if option C is taken) the workflow documents that the cache is same-PR-by-design.
- The two workflow files stay internally consistent (same `non-code` label name, same gate expression); the change is YAML-only, so no `.sh`/`.ps1` parity work.
