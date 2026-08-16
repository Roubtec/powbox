# 002h — Serialize the statusline's file+marker publication across containers

## Why this task exists

Task 002e (PR #151) gave the seeded Claude statusline a digest-gated refresh: `entrypoint-claude-hook.sh` writes `~/.claude/statusline-command.sh` and a sidecar marker `~/.claude/.statusline-command.sh.powbox-seeded` carrying `epoch=`/`commit=`/`sha256=`/`source=`, and a newer image replaces the file only while its on-disk digest still equals the recorded `sha256=`. Anything else is treated as the user's and kept.

Every individual publish in that block is atomic — `statusline_publish` and `statusline_write_marker` each write a `mktemp` sibling and `mv -T` it into place — but the file and the marker are **two** renames, and nothing serializes the read/decide/publish/mark transaction across containers. The `claude-config` volume is a single global Docker volume shared by every powbox container, so two containers starting concurrently from *different* newer image epochs can both validate the same old file/marker pair, both decide to refresh, and then interleave:

1. container A renames its statusline into place;
2. container B renames its (different) statusline into place;
3. container B writes its marker;
4. container A writes its marker.

The volume is left holding B's bytes under A's `sha256=`. From then on every image sees a digest mismatch, reports powbox's own copy as a user customization, prints the "yours differs, delete it to take the new one" note once per new image, and never refreshes the file again until the user deletes it.

Raised by the codex reviewer on PR #151 (`docker/shared/entrypoint-claude-hook.sh:254`, P2, <https://github.com/Roubtec/powbox/pull/151#discussion_r3789502511>) and independently corroborated by the claude reviewer on the same PR, which noted it is distinct from the single-writer crash windows the PR already documents — those are one interrupted transaction, this is two complete ones racing.

The concern was accepted rather than fixed in #151 and is documented in place as a bounded residual (in `seed_statusline`, in `docs/entrypoint-and-runtime.md`'s statusline bullet, and in `docs/skills-refresh-and-provenance.md` D9). The consequences are the same bounded class as the residuals already accepted there: cosmetic only, self-announcing, and cleared by deleting the file. What makes it worth a task rather than a permanent won't-fix is that it is the only one of them reachable with no crash and no user action.

## Why it was not fixed in #151

`seed-claude-plugins.sh` already holds the pattern that would fix it — `run_locked` takes an `flock` on a lockfile living on the shared volume, degrading to unlocked when there is no `flock` binary or the lockfile cannot be opened. But that bootstrap is **detached**, so it can wait out `POWBOX_PLUGIN_LOCK_WAIT` (300s by default) without anyone noticing. The statusline block runs **synchronously** on the container startup path, where every second of lock wait is a second of startup delay, and under invariant B (nothing in the block may end startup). Choosing the wait, and pinning the new failure shapes it introduces, is a design decision of its own rather than a line of code.

## Scope

**In scope:**

- Serialize the whole read/decide/publish/mark transaction of `statusline_seed_step` against peer containers on the shared `claude-config` volume.
- Pick and justify a bound for the wait that is defensible on the synchronous startup path, and state what happens when it expires (proceeding unlocked reproduces today's race; skipping the refresh defers it one start — either is acceptable if stated). This choice is deliberately left open; the acceptance criteria below bind to whichever fallback is chosen rather than presuming one.
- Preserve both invariants of the block: every publish stays atomic, and no failure of the locking path — a missing `flock` binary, an unopenable lockfile, an expired wait — may abort container startup or leave the statusline in a state worse than "left as found".
- Extend `scripts/test-claude-hook-skew.sh` with the new shapes: no `flock` on `PATH`, a lockfile that cannot be created, and a contended lock (a peer holding it) — each asserting the hook exits 0 and the instruction file and `settings.json` still refresh, as every other error path in that suite does.

**Out of scope:**

- The single-writer crash windows already documented in #151 (kill between `mktemp` and rename; kill between publish and marker rewrite). A lock does not close them, and they were accepted deliberately.
- Sourcing `seed-skills.sh` or `seed-claude-plugins.sh` from the hook. #151 declined to give a startup-critical hook its first library dependency; that reasoning stands, so the lock is written inline or the shared helper is factored somewhere both can safely read.
- The instruction file / `.instruction-epoch` pair, which is the same *shape* but not the same problem: it is re-asserted on every `-ge` epoch with no digest gate, so a mispairing self-heals on the next start.

## Notes for the implementer

- The rollout window is inherently partial. The race needs two containers both newer than the recorded marker epoch, and during the very rebuild that ships this fix one of them is running the pre-lock hook and takes no lock. The fix narrows the window rather than closing it, and the residual note in the code should say so rather than being deleted outright.
- A lockfile added to `~/.claude` is user-visible; name it to match the existing convention (`.powbox-plugin-bootstrap.lock` is the precedent) and mention it wherever the volume's contents are described.
- Verifying the end-to-end behavior needs two real containers against one volume, which per `AGENTS.md` → "Validating Changes" cannot run inside an agent container. The suite additions above are the in-container coverage; the two-container confirmation is a host step.

## Acceptance criteria

- Two containers from different newer image epochs starting concurrently against one `claude-config` volume can no longer leave the statusline paired with the wrong marker, for as long as both run the locked hook and neither of them publishes without holding the lock — always true under the skip-the-refresh fallback, and the standing cost of the proceed-unlocked one.
- The hook still exits 0 and still refreshes the instruction file and `settings.json` with `flock` absent from `PATH`, with the lockfile path unwritable, and with the lock held by a peer past the wait — the same pair every other error path in `scripts/test-claude-hook-skew.sh` already asserts.
- In each of those three shapes the statusline itself ends in the outcome the fallback chosen in [Scope](#scope) documents, and the suite asserts *that* outcome rather than a presumed one: skipping the refresh leaves the file and its marker exactly as found; proceeding unlocked performs the ordinary digest-gated refresh and leaves the file paired with its own marker. None of the three shapes contains a second publisher — the contended one is a synthetic lock holder, the two-container confirmation being the host step [Notes for the implementer](#notes-for-the-implementer) names — so in them neither fallback may leave the file under a marker that does not describe it, and neither may end worse than "left as found". That floor is scoped to those shapes and is not a concurrency guarantee: against a genuine concurrent peer the proceed-unlocked fallback still mispairs, which is the cost [Scope](#scope) books against choosing it rather than a criterion this suite can assert.
- The bounded-residual notes in `seed_statusline`, `docs/entrypoint-and-runtime.md` and `docs/skills-refresh-and-provenance.md` D9 are updated to describe what remains rather than removed.
- `shellcheck` (default and `--severity=error`), `shfmt -d` and `./scripts/run-pure-shell-tests.sh` pass.

## Status

**Not started.** Queued. No prerequisites beyond PR #151 landing; it touches the same block, so it is cheapest to do while that context is still loaded.
