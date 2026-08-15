# 002i — Recheck the statusline destination before replacing it

## Why this task exists

Task 002e (PR #151) gave the seeded Claude statusline a digest-gated refresh, whose entire promise is that a newer image replaces only a copy powbox can *prove* is still its own.
`statusline_seed_step` establishes that proof by digesting the destination and comparing it against the marker's `sha256=`, and only then calls `seed_statusline`, which calls `statusline_publish` — a `mktemp`, a `cp`, a best-effort `chmod`, and finally the `mv -T` that replaces the file.

The proof and the replacement are therefore **two separate steps with a gap between them**, and nothing establishes that the destination still holds the bytes that were digested by the time the rename lands.
A writer that changes the file inside that gap has its bytes discarded by the rename, and `seed_statusline` then records the digest of the *source* in the marker — so the destination reads as powbox's own copy from then on.
The loss is silent, unannounced and unrecoverable: no note is printed, the marker actively certifies the overwrite, and there is no copy of what was replaced.
That is the one outcome the digest gate exists to prevent, reached through the gate rather than around it.

The **fresh-seed branch has the same shape**: `statusline_seed_step` tests `[ ! -e ] && [ ! -L ]` and then publishes, so a statusline created in the gap between that test and the rename is replaced as well.
It predates 002e — the `cp` this grew out of tested `[ ! -f ]` and then copied — but it is the same defect and belongs in the same fix.

Raised by the codex reviewer on PR #151 (`docker/shared/entrypoint-claude-hook.sh:289`, P2, <https://github.com/Roubtec/powbox/pull/151#discussion_r3789992293>), which named precisely the case task 002h does not reach.

## Its relationship to 002h, which does not cover it

Task 002h serializes the read/decide/publish/mark transaction against **peer powbox containers**, so that two containers refreshing concurrently cannot leave one's bytes under the other's marker.
A lock binds only the writers that take it, and the writer here is an **arbitrary** one — the user's editor in a peer container against the shared `claude-config` volume, a dotfiles sync, any process that opens the path.
None of them takes powbox's lock, so 002h's fix leaves this gap exactly as wide as it is today, and the two consequences differ in kind rather than degree: 002h's is a mispaired marker, which is cosmetic, self-announcing, and cleared by deleting a file powbox itself wrote, while this one destroys the user's own work without saying so.

The two touch the same transaction in the same block, so they are cheapest done together, but neither subsumes the other and each needs its own decision.

## Why it was not fixed in #151

The reviewer asked for "a conditional/version check that ensures the destination has not changed since validation", and no such check exists at this layer: `rename(2)` has no conditional or compare-and-swap form, and neither `mv` nor any coreutils tool exposes one, so **any** re-check is itself a check followed by a separate replace.
A re-check therefore narrows the gap; it cannot close it, and a fix that reads as though it had would be worse than the stated residual.
What to do instead is a design decision rather than a line of code — narrow it, make the loss recoverable, or accept it and say so — and #151 took the third while stating the residual in place, so the branch does not ship an unstated silent-loss window.

## Scope

**In scope:**

- Settle what `statusline_seed_step` and `seed_statusline` owe a destination that changes under them, and implement it. The three candidates, to be chosen between and justified rather than combined by default:
  1. **Narrow the gap.** Give `statusline_publish` the expected digest and re-verify the destination immediately before the `mv -T`, which cuts the exposure from a digest plus three process spawns (`mktemp`, `cp`, `chmod`) down to a digest plus the rename. It needs its own outcome, since "the destination changed under us" is not the "could not write" the read-only branch reports, and it must be described as narrowing rather than closing.
  2. **Make the loss recoverable instead of rarer.** Rename the destination aside (a `.powbox-replaced` sibling, say) before installing the new copy, so bytes lost to the gap can be retrieved. It closes nothing either, but it downgrades the consequence from unrecoverable to recoverable, and it costs a user-visible file on the volume.
  3. **Accept it**, leaving the residual notes #151 committed as the whole answer. Legitimate only if argued, given that the consequence is destruction of user work rather than the cosmetic class the block's other residuals sit in.
- Cover the **fresh-seed branch** under whichever answer is chosen. `[ ! -e ] && [ ! -L ]` followed by a rename is the same gap with the same consequence, and it is the branch every new volume takes. Note that this branch alone admits a genuinely atomic answer that the refresh branch does not: `ln` fails with `EEXIST` rather than replacing, so a create-if-absent publish can be made to lose nothing at all.
- Preserve both invariants of the block: every publish stays atomic, and no failure of the new path may abort container startup or leave the statusline worse than "left as found".
- Extend `scripts/test-claude-hook-skew.sh` with the shapes the chosen answer introduces, each asserting the hook exits 0 and the instruction file and `settings.json` still refresh, as every other error path in that suite does.

**Out of scope:**

- Serializing powbox's own publishers, which is task 002h. It does not reach an arbitrary writer, and this task does not reach the peer-interleaving mispairing.
- The single-writer crash windows already documented in #151 (a kill between the `mktemp` and its rename; a kill between the publish and the marker rewrite). Neither is a concurrent writer.
- The instruction file and `settings.json`, which are re-asserted from the image on every `-ge` epoch with no ownership claim to lose.

## Notes for the implementer

- The gap is milliseconds on the container startup path, and reaching it takes a writer touching this one file in that window. That is what makes it a follow-up rather than a blocker — and the consequence, not the odds, is what makes it worth closing as far as it can be closed.
- Whatever is chosen, the residual notes in `seed_statusline`, `docs/entrypoint-and-runtime.md`'s statusline bullet and `docs/skills-refresh-and-provenance.md` D9 are updated to describe what remains, rather than deleted — the same instruction 002h carries, for the same reason.
- A test for the gap has to inject a writer *between* the digest and the rename, which the suite cannot do by racing it. Drive it deterministically instead — a stub on `PATH` for one of the commands that runs inside the gap, rewriting the destination when it is called — so the assertion pins the outcome rather than a scheduler.
- Verifying the cross-container half needs two real containers against one volume, which per `AGENTS.md` → "Validating Changes" cannot run inside an agent container.

## Acceptance criteria

- `docker/shared/entrypoint-claude-hook.sh` answers a destination that changes between the digest and the rename in the way this task's chosen option documents, on **both** the refresh branch and the fresh-seed branch, and the code says which of narrowing, recovery or acceptance it implements rather than leaving a reader to infer it.
- No claim anywhere in the code or docs says the gap is closed, except for the fresh-seed branch if it was given the `EEXIST` form, which does close it.
- `scripts/test-claude-hook-skew.sh` pins that outcome with a writer injected deterministically inside the gap, on both branches, and each new case asserts the hook exits 0 and the instruction file and `settings.json` still refresh.
- The bounded-residual notes in `seed_statusline`, `docs/entrypoint-and-runtime.md` and `docs/skills-refresh-and-provenance.md` D9 describe what remains after the change.
- `shellcheck` (default and `--severity=error`), `shfmt -d` and `./scripts/run-pure-shell-tests.sh` pass.

## Status

**Not started.** Queued. No prerequisites beyond PR #151 landing. It touches the same transaction as task 002h and is cheapest done alongside it, but neither depends on the other.
