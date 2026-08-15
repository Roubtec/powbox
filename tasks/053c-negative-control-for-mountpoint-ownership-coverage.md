# Task 053c — Prove the mountpoint-ownership coverage actually fails when the chown is removed

## Why this task exists

Tasks 053 and 053a both state the same acceptance criterion in two halves:

1. the smoke exercises `shadow-mounts.sh`'s "created mountpoint inherits the deepest existing ancestor's ownership" `chown`, **and**
2. it **fails** when that `chown` is removed.

Half (1) is automated for the **Bash** driver today: Tier 1 runs the Bash umbrella's Stage 6 on a runner where the assertions have real teeth (native Linux, rootful daemon, unprivileged `runner` invoker, uid 1001).
It becomes automated for **both** drivers once task 053a (PR #152, still open at the time of writing) lands, which is what adds the PowerShell driver's own mountpoint-ownership assertions and a dedicated PowerShell Stage 6 step in Tier 1.
Until then `scripts/smoke-test-worktree-metadata.ps1` carries its KNOWN DIVERGENCE comment and asserts none of them, so everything below that speaks of two drivers is conditional on 053a.

Half (2) has never been automated in this repo, for either driver.
It has only ever been a manual instruction in a task file: delete the `chown` from `docker/shared/shadow-mounts.sh`, rebuild, run the smoke, confirm red, put it back.
Nothing records whether that was ever performed, and nothing re-performs it when the assertions are later refactored.

That gap is the same shape as the defect 053a itself hit in review: an artifact that is *correct* is not the same as an artifact that is *reached*, and a passing assertion is not the same as an assertion that can fail.
The three ownership assertions compare a directory against its deepest pre-existing ancestor. If a future refactor made both sides read the same path, or made `Get-PathOwnerId` / `owner_of` return the same sentinel for both, every assertion would pass forever and half (1)'s automation would not notice.

## Scope

Add an automated negative control: with the `chown` removed from `shadow-mounts.sh`, the mountpoint-ownership assertions must go **red**.

This is a mutation test, not a new smoke stage, and it must be as cheap as possible — Tier 1 already runs 7+ minutes.

## Open questions for the maintainer — decide before implementing

### (a) How to inject the mutation

Two routes look viable; both need the same real image, so neither is free.

- **Derived image.** `FROM powbox-agent:latest` plus a `RUN` that strips the `chown` from `/usr/local/bin/shadow-mounts.sh`, then point the driver at the derived tag via its existing `-Image` / `$IMAGE` argument. No driver change at all — the drivers already take the image as a parameter. Costs one extra tiny layer build. Verified feasible: the script is baked by a plain `COPY --chmod=755` as root (`docker/base/Dockerfile`) with **no** `chattr +i` anywhere in `docker/`, so a root `RUN` can patch it; the "immutable" wording in the Dockerfile comments means root-owned relative to the `node` user, not filesystem-immutable.
- **Bind-mount a patched copy** over `/usr/local/bin/shadow-mounts.sh` in the `docker run`. Avoids the extra build, but the drivers construct `runArgs` internally, so it needs a new opt-in hook in **both** drivers — a new surface on the very files under test.

The derived-image route looks clearly better: zero change to the code under test, which is the property a negative control most needs.

### (b) Where it runs, and against which driver

- Tier 1, after the two Stage 6 steps, against **one** driver only — cheapest, and catches the "assertions can no longer fail" regression *in the driver it runs*. Be explicit about what it does not catch: 053a deliberately duplicates the host-side assertion code rather than sharing it, so a mutation-blindness confined to the other driver — the `Get-PathOwnerId` / `owner_of` returning one sentinel for both paths case named above — stays invisible, because the covered driver still goes red and the control still passes. Choosing this option therefore also means narrowing this task's claim to the one driver's assertions, rather than to the ownership coverage as a whole.
- Tier 1 against **both** drivers — twice the cost, and the only option that covers both host-side assertion implementations. What it buys over the option above is precisely the per-driver blindness that option cannot see, which is the threat this task was written for. Note that until 053a lands there is only one implementation to cover, so this option's second run has nothing to assert against.
- Not in CI at all: a documented `scripts/`-level harness a maintainer runs on demand. Cheapest for CI, but reintroduces "nobody knows when this was last run".

### (c) What counts as a pass

The control must assert the run failed **for the right reason** — a red that comes from an unrelated breakage would satisfy a naive "expect non-zero" check and hide the loss of coverage.
So anchor on an ownership check's own message rather than on the exit code alone — but not on the *host-side* message alone, because under the whole-`chown` mutation it never prints.

Removing the `chown` aborts the driver inside **Container A**, before any host-side assertion runs: `scripts/smoke-test-worktree-metadata.sh` creates `$WS/.claude`, compares that intermediate directory against its pre-existing parent right there in the container, and exits with `the shadow-mounts.sh mountpoint chown REGRESSED` (its line 235 as of this writing), which the driver reports as `Container A could not set up the durable worktree`.
The host-side message `the created mountpoint did NOT inherit the tree's ownership` is therefore unreachable under that mutation, and a control anchored on it alone would reject the very mutation it exists to prove.

That is a decision, not a detail — pick one:

- **Match either message**, accepting the in-container intermediate-directory check as a valid anchor, and record that the mutation is caught at the earliest ownership check rather than at the host-side ones. Cheapest, but it leaves the host-side assertions themselves unproven by this control.
- **Narrow the mutation** so Container A's intermediate-directory case still passes and the host-side assertions are actually reached. `shadow-mounts.sh` has one `chown -h "$owner" "$resolved_new"` inside a loop over `new_dirs`, and that array is built target-first (`new_dirs[0]` is the mountpoint itself, the entries after it are the ancestors it had to create), so a mutation that skips only the first element leaves the intermediate `.claude` correctly owned — Container A passes — while the mountpoints stay root-owned and the host-side assertions fire. More faithful to what the control claims to protect, but coupled to that loop's internals, so it needs the same match-or-fail guard as any other textual mutation.

Whichever is chosen, note also that the host-side message lives in `scripts/smoke-test-worktree-metadata.sh` only today; the PowerShell driver gains its counterpart with task 053a (PR #152), so the anchor set must be written against whichever drivers the control actually runs — see (b).

Note the vacuity conditions still apply in reverse: under a rootless engine, or as root on the host, the mutated run would **pass**, and the control would then fail spuriously. It must therefore run only where the positive half has teeth — the same runner — and say so if it cannot.

## Target files or areas

- `.github/workflows/native-linux-build.yml` — the Tier 1 job, after the existing smoke steps
- possibly a small `scripts/` harness holding the mutation + expectation, so the workflow step stays a one-liner and the same check is runnable by hand
- `docker/shared/shadow-mounts.sh` — read-only reference (the `chown` under mutation); **not** modified by this task
- `docs/smoke-tests.md` → Stage 6 — document that the coverage is checked in both directions

## Implementation notes

- Keep the mutation textual and narrow, and fail loudly if it matched nothing — a `sed` that silently matches zero lines would produce an unmutated image and a green "negative" control, which is precisely the failure mode this task exists to prevent.
- The mutated image must never be reused by another step; tag it distinctly and prefer building it after the real smoke steps have run.
- `AGENTS.md` → "Validating Changes": the workflow edit itself cannot be validated in-container beyond `actionlint`; the run on the PR is the validation.

## Acceptance criteria

- Removing the mountpoint `chown` from `shadow-mounts.sh` causes the mountpoint-ownership coverage to fail, demonstrated automatically rather than by instruction.
- The control asserts the failure came from an ownership check itself — matching whichever message decision (c) settles on, including Container A's in-container intermediate-directory check if that is the one the chosen mutation trips first — not merely that something exited non-zero.
- The control's stated reach matches decision (b): a single-driver control does not claim to protect both drivers' duplicated host-side assertion implementations.
- A mutation that fails to apply is a hard error, never a silent pass.
- The control runs only where the assertions have teeth, and reports rather than passes when it cannot.
- The drivers under test are unchanged by the control, or the change is a single opt-in hook if decision (a) goes the other way.
- `docs/smoke-tests.md` records that Stage 6's ownership coverage is verified in both directions.
