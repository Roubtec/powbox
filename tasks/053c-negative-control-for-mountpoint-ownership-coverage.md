# Task 053c — Prove the mountpoint-ownership coverage actually fails when the chown is removed

## Why this task exists

Tasks 053 and 053a both state the same acceptance criterion in two halves:

1. the smoke exercises `shadow-mounts.sh`'s "created mountpoint inherits the deepest existing ancestor's ownership" `chown`, **and**
2. it **fails** when that `chown` is removed.

Half (1) is now automated for both drivers: Tier 1 runs the Bash umbrella's Stage 6 and, since 053a's PR, a dedicated PowerShell Stage 6 step, on a runner where the assertions have real teeth (native Linux, rootful daemon, unprivileged `runner` invoker, uid 1001).

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

- Tier 1, after the two Stage 6 steps, against **one** driver only (the extra coverage is of the *assertions*, and both drivers assert the same three cases) — cheapest, and catches the "assertions can no longer fail" regression.
- Tier 1 against **both** drivers — twice the cost, and only catches a mutation-blindness that is present in one driver and not the other.
- Not in CI at all: a documented `scripts/`-level harness a maintainer runs on demand. Cheapest for CI, but reintroduces "nobody knows when this was last run".

### (c) What counts as a pass

The control must assert the run failed **for the right reason** — a red that comes from an unrelated breakage would satisfy a naive "expect non-zero" check and hide the loss of coverage.
Anchor on the assertion's own message (`the created mountpoint did NOT inherit the tree's ownership`, present in both drivers) rather than on the exit code alone.

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
- The control asserts the failure came from the ownership assertion itself, not merely that something exited non-zero.
- A mutation that fails to apply is a hard error, never a silent pass.
- The control runs only where the assertions have teeth, and reports rather than passes when it cannot.
- The drivers under test are unchanged by the control, or the change is a single opt-in hook if decision (a) goes the other way.
- `docs/smoke-tests.md` records that Stage 6's ownership coverage is verified in both directions.
