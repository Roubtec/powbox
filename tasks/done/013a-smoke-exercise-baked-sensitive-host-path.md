# Task 013a — Make the in-image smoke run exercise the BAKED sensitive-host-path.sh, not the mounted source

Follow-up to **Task 013** (baked `gh-review-threads` helper, PR #79). Parked in `tasks/deferred/` because the branch is defendable as-is and this touches a **different image layer** (base, not agent) and a file untouched by PR #79 — fixing it there would expand that PR's scope.

## Background — the same source-vs-baked gap, one layer down

PR #79's review surfaced (codex, P2, https://github.com/Roubtec/powbox/pull/79#discussion_r3514722343) that `scripts/test-gh-review-threads.sh` hard-coded `HELPER="${ROOT_DIR}/docker/shared/gh-review-threads"`, so the smoke Stage 0b in-image run exercised the mounted `/repo` **source**, not the baked `/usr/local/bin/gh-review-threads` — a behaviorally broken installed helper would still pass, since Stage 1's `command -v` only checks presence.

PR #79 fixed that for `gh-review-threads` by making the path overridable (`GH_REVIEW_THREADS_HELPER`) and passing `-e GH_REVIEW_THREADS_HELPER=/usr/local/bin/gh-review-threads` on the in-image `docker run` in both `commands/smoke-test.sh` and `commands/smoke-test.ps1`.

**The identical pattern still exists for `sensitive-host-path.sh`:**

- `scripts/test-sensitive-host-path.sh:16` hard-codes `LIB="${ROOT_DIR}/docker/shared/sensitive-host-path.sh"` (the mounted source).
- That test is run **inside the image** by the smoke suites (e.g. `commands/smoke-test.ps1` runs `docker run … /repo/scripts/test-sensitive-host-path.sh`; verify/add the equivalent in `commands/smoke-test.sh`).
- `sensitive-host-path.sh` **is** baked — into the **base** image at `/usr/local/bin/sensitive-host-path.sh` (`docker/base/Dockerfile:361`), and its runtime consumers fall back to that baked copy: `entrypoint-core.sh`, `fix-workspace-perms.sh`, and `heal-workspace-perms.sh` all do `_shp="$(dirname "$0")/sensitive-host-path.sh"; [ -r "$_shp" ] || _shp=/usr/local/bin/sensitive-host-path.sh`.

So the in-image smoke run of `test-sensitive-host-path.sh` validates the `/repo` source, never the baked `/usr/local/bin/sensitive-host-path.sh` that containers actually source. A stale or behaviorally broken baked copy in the base layer would slip past the smoke.

## Goal

Let the in-image smoke run exercise the **baked** `sensitive-host-path.sh`, mirroring the fix PR #79 applied for `gh-review-threads`.

## Suggested approach (mirror PR #79)

1. In `scripts/test-sensitive-host-path.sh`, make the sourced lib overridable, defaulting to the in-repo source:
   ```sh
   LIB="${SENSITIVE_HOST_PATH_LIB:-${ROOT_DIR}/docker/shared/sensitive-host-path.sh}"
   ```
   Keep the existing `# shellcheck source=docker/shared/sensitive-host-path.sh` directive (it resolves the default source path for the linter regardless of the runtime override).
2. Wire an **in-image** run that sources the baked base-layer copy by passing `-e SENSITIVE_HOST_PATH_LIB=/usr/local/bin/sensitive-host-path.sh` on the `docker run`. Note the current asymmetry: `commands/smoke-test.ps1:60` already runs `test-sensitive-host-path.sh` **in-image** (add the `-e` there), but `commands/smoke-test.sh:39` runs it only on the **host** (Stage 0) — so closing the Bash-side gap means *adding* an in-image run (mirroring the Stage 0b gh-review-threads pattern), not just adding `-e` to an existing one. Host runs keep the default source path.
3. Confirm the test still fails closed if the baked lib is absent/unreadable (the existing readability guard should surface it).

## Acceptance

- The in-image smoke run of `test-sensitive-host-path.sh` sources `/usr/local/bin/sensitive-host-path.sh`; a deliberately broken baked copy makes that stage fail (mutation-check it, as PR #79 did for its helper).
- Host runs (no env var) still source the `/repo` checkout.
- `.sh` / `.ps1` parity preserved; `shellcheck --severity=error`, `shfmt -d`, and PSScriptAnalyzer clean.
