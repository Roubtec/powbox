# Task 003a — Warm the Tier 1 base-image cache from the default branch

Follow-up from the PR #62 review (native-Linux CI). Parked in `tasks/deferred/` because the base-image cache is an explicitly **footprint-respecting, best-effort** optimization — the workflow's own comment notes "a cold/empty cache only costs time, never correctness" — and the fix adds a recurring image build on the default branch, a real CI-minutes/footprint tradeoff the maintainer should weigh, while the branch is defendable as-is (the cache is correct; it just does not amortize across PRs).

Review thread:
- https://github.com/Roubtec/powbox/pull/62#discussion_r3446296402 (codex, P2) — base cache is only seeded on `pull_request` runs, so its scope cannot be restored by other PRs.

## Background — the gap

`.github/workflows/native-linux-build.yml` (Tier 1) saves the expensive base image (`node:24-trixie-slim` + ~12 apt groups, ~13 min cold) as a `docker save` tarball via `actions/cache@v4`, keyed on the base-image inputs (`hashFiles('docker/base/Dockerfile', 'docker/shared/**', 'docker-bake.hcl', 'scripts/build-image.sh', 'PSScriptAnalyzerSettings.psd1', '.dockerignore')`).

The workflow only triggers on `pull_request`. GitHub Actions scopes a cache written during a PR run to that PR's ref: it can be restored by **re-runs of the same PR**, but **not by sibling PRs** targeting the same base. Caches written on the **default branch** are the ones restorable by all branches. See https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching#restrictions-for-accessing-a-cache .

Net effect: every new image-affecting PR gets a **cold** base build (~13 min) despite the cache design, because no run ever populates the default-branch-scoped cache that other PRs could read. The cache only helps repeated runs of one PR. This is purely an efficiency limitation — correctness is never at stake (the full-build fallback is always correct).

## Goal

Let an image-affecting PR restore a warm base from a cache populated by the default branch, so the common case avoids the ~13 min cold base build, **without** silently inflating default-branch CI cost beyond what the maintainer accepts.

## Suggested approach (pick one)

**A. Add a default-branch warmup trigger to the same workflow (preferred).** Add `push: { branches: [main], paths: <same base-input globs> }` alongside the existing `pull_request` trigger, and on a `push` event run only the base build + `docker save` + `actions/cache` save under the **same key** — skipping the agent build and the smoke test (gate the smoke/agent steps on `github.event_name == 'pull_request'`, or split a dedicated `warm-base` job that runs only on `push`). The push run writes the default-branch-scoped cache; subsequent PRs restore it. Keep the key identical so PR and warmup entries unify.

**B. Separate warmup workflow.** A small `native-linux-base-warmup.yml` on `push` to `main` (same paths + same cache key) that only builds and saves the base. Cleaner separation, one more file to keep in sync with the key/paths.

**C. Accept the limitation, document it.** If the maintainer judges the recurring main-branch build not worth the per-PR savings, leave the cache as a same-PR-rerun optimization and add a one-line comment in the workflow stating the cross-PR limitation is intentional, so a future reader does not mistake it for a bug.

Whichever is chosen, keep the cache key and the base-input path set **single-sourced** between the PR path and the warmup path so they cannot drift (a warmup keyed differently from the restore would never hit).

## Acceptance

- An image-affecting PR opened after a default-branch warmup run restores the base from cache (build log shows "Base cache HIT") instead of a cold base build, OR the limitation is deliberately documented in-workflow (approach C).
- No change to correctness: the full-build fallback still runs on a genuine cache miss.
- If a warmup path is added, it does not run the agent build or smoke test (warmup builds and saves only the base), and its trigger paths + cache key stay identical to the PR run's so the two share one cache entry.
