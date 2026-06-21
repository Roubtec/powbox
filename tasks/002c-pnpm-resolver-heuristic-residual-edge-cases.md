# Task 002c — pnpm subcommand resolver: residual edge cases of the "first known subcommand" heuristic

Generic follow-up from the PR #70 review (codex, P3) plus a `verify-deps-before-run` behavior
surfaced during fresh review. Deferred because PR #70 is defendable as-is: in the common
regression-shaped scenario the resolver errs to the *safe* direction, and the redesign that would
tidy the remaining edge cases either reopens a worse false negative or adds hot-path cost. Parked
here (not yet actionable) until a maintainer decides the tradeoff is worth a resolver redesign.

Review thread: https://github.com/Roubtec/powbox/pull/70#discussion_r3448851646 (codex, P3,
"Stop latching script arguments as install commands").

## Background — the heuristic and what codex flagged

`docker/shared/pnpm-shadow-wrapper.sh`'s `pnpm_subcommand()` resolves the real subcommand as the
**first token that names a known subcommand** (`is_known_subcommand`), skipping any earlier token
it does not recognize. This was the task-002b redesign: it makes resolution robust to *unknown*
value-taking global flags for free (a flag's value such as `silent`/`info` is not a known
subcommand name, so it is skipped without needing an exhaustive flag list — the gap that let
`pnpm --reporter silent install` resolve to `silent` and silently skip the warning).

The codex P3 observed that pnpm also supports **shorthand script execution** — `pnpm <script>` runs
`<script>` when it is not a builtin command (`pnpm build install` runs the `build` script with
`install` as its argument). Because `build` is not a known subcommand, the resolver skips it and
**latches the trailing `install`**, so in the regression-shaped condition (non-dev folder, no
`PNPM_STORE_DIR`, root `node_modules` not a mountpoint) the wrapper emits the root-node_modules
warning. codex called this a false positive ("pnpm is only running a script").

## Empirical correction — pnpm auto-installs before scripts (`verify-deps-before-run`)

codex's "only running a script, no install" premise does **not** hold for the scenario the warning
targets. pnpm 11.8.0 defaults `verify-deps-before-run` on: before running any script it checks
`node_modules` against the lockfile and **auto-installs missing deps first** (verified: both
`pnpm run build` and `pnpm build install` install a missing `is-number`; `--config.verify-deps-before-run=false`
suppresses it). The warning only fires in a freshly-scaffolded non-dev folder where deps are **not
yet installed** — exactly where `pnpm build install` *does* write `node_modules` onto the host bind
mount. So the latched-`install` warning is, in that scenario, a **true positive**: right outcome,
even if the resolver reached it by latching the wrong token.

## The residual edge cases (what a redesign would actually clean up)

1. **Narrow false POSITIVE (safe direction).** When deps are already satisfied, `pnpm build install`
   runs the script without installing, yet the resolver latches `install` and warns. Benign: one
   advisory stderr line, no block, no data loss — the gate is deliberately tuned to prefer false
   positives over false negatives.
2. **Config-key false NEGATIVE (dangerous direction, exotic, accepted).** pnpm consumes the token
   after ANY value-taking option, including global/config-key ones outside `pnpm install --help`
   (`--node-linker`, `--registry`, `--ca`, `--https-proxy`, the
   `--fetch-*` numerics, any `--<npmrc-key> <value>`). The skip list is now complete with respect to
   `pnpm install --help` (dirs/selectors/patterns/loose-strings/numerics/enums incl.
   `--package-import-method`/`--trust-policy`), but `pnpm --registry run install` still resolves to
   the value `run` and **silently skips the warning on a real root install**. Exotic (the value must
   be literally a subcommand name) and documented in the resolver comment as accepted.
3. **Pre-existing bare-script false NEGATIVE (out of PR #70's scope, recorded here).** Because of
   `verify-deps-before-run`, a bare `pnpm <script>` with **no** install-class word (e.g. `pnpm build`
   in a scaffolded non-dev folder) auto-installs deps onto the host bind mount, but the resolver
   resolves no install-class subcommand, so the wrapper neither warns nor runs a shadow refresh.
   This is the inverse of codex's concern and arguably the more important gap; it predates PR #70
   (the wrapper has always keyed off the resolved subcommand, never script-triggered auto-installs)
   and is not one of the four review threads, so it is noted, not fixed, here.

A resolver that does not depend on a hand-maintained value-taking-flag list — and that is aware
pnpm may install ahead of a script run — would address all three at once.

## Why this is deferred, not fixed in PR #70

The in-scope codex case (1) is a benign false positive in the safe direction, and is often a true
positive anyway (auto-install). The codex-suggested remedy — "treat the first non-flag token as the
command unless it was consumed by a value-taking option" — is the pre-002b "first non-flag token"
approach, which **reopens the dangerous false negative**: it is only correct if the value-taking
flag list is *complete*, and pnpm's value-taking surface is effectively open-ended (case 2). Verified
the two pre-002b motivating cases still hold in pnpm 11.8.0: `pnpm --reporter silent install` and
`pnpm --loglevel info install` are real root installs whose values (`silent`/`info`) a
first-non-flag-token resolver would mis-read as the subcommand. So adopting the suggestion as-written
is a net regression in the direction that actually matters. Case 3 is a separate, pre-existing gap.

## Approaches to weigh (no decision yet)

- **A. Complete-the-flag-list + first-non-flag-token.** Resolve the first non-flag, non-consumed
  token as the command, maintaining a *complete* enumeration of pnpm's value-taking flags. Trouble
  (verified): pnpm consumes the token after EVERY value-taking option regardless of where it is
  documented, and accepts arbitrary `--<npmrc-key> <value>` — so the set is open-ended. Con: the
  list must track pnpm releases AND the npmrc config-key surface or it silently regresses to a false
  negative — the maintenance burden 002b removed. Would need a CI probe diffing our list against
  `pnpm install --help` (and ideally the config-key set) on version bumps. Does nothing for case 3.
- **B. Read `package.json` scripts (and model auto-install).** When the leading token is not a known
  subcommand, treat it as a script run only if it *is* a script in the effective project's
  `package.json`; otherwise treat it as the command. To also cover case 3, account for
  `verify-deps-before-run`: a script run in a folder whose deps are stale/absent will itself install.
  Pro: exact. Con: a JSON read on the hot path, needs effective `-C/--dir` resolution and a
  deps-freshness check, still needs value-skip handling.
- **C. Accept the residuals (document & close).** Keep the safe-direction bias; the in-scope false
  positive (case 1) is benign and usually a true positive, case 2 is exotic and documented, case 3
  is pre-existing. Choosing this explicitly closes the codex thread without code change.

## Acceptance

- A decision recorded for case 1: either `pnpm <local-script> <install-word>` with **satisfied
  deps** no longer warns, or the benign false positive is explicitly accepted (approach C).
- Whatever is chosen, the task-002b false-negative guarantees still hold: every existing
  `assert_warns` case in `scripts/test-pnpm-shadow-wrapper.sh` (`--reporter silent install`,
  `--loglevel info install`, `--network-concurrency run install`, `--package-import-method run
  install`, `--store-dir --filter install`, …) still warns.
- If case 3 is taken on, a scaffolded non-dev `pnpm <script>` (no install-word) that triggers an
  auto-install is detected (warned and/or shadow-refreshed) rather than silently writing host
  `node_modules`.
- If approach A is taken, add a guard that detects drift between the wrapper's value-taking flag
  list and pnpm's documented options (so the list cannot silently fall behind).
- New regression tests cover the chosen behavior.

## Decision (resolved 2026-06-21): Approach C — accept & close

Chosen approach: **C — accept the residuals, document & close.** No resolver redesign, no new
value-taking-flag list, no `package.json` reads. The resolver's executable logic is unchanged.

Maintainer rationale:

- No resolver can fully reason about arbitrary scripts: a script named anything can internally shell
  out to `pnpm i` as shorthand for install, so the leading-token-is-a-script analysis is
  fundamentally incomplete.
- A `package.json`-aware resolver (approach B) would additionally have to understand nested workspace
  packages — too costly a solution for what are rare exceptions to a rare occurrence (mid-session
  scaffolding of a new package inside the container).
- The failure cost is low: the host just removes the container, deletes the folder, and runs the
  container afresh.
- So invest proportionate effort: keep the resolver's safe-direction bias, document the residuals,
  lock in regression tests.

What was implemented:

- Resolver logic (`pnpm_subcommand()` / `refresh_shadows()` / the classifier functions) is
  **byte-for-byte unchanged** — only comments changed.
- The three residual cases are documented in the big comment block above `pnpm_subcommand()` in
  `docker/shared/pnpm-shadow-wrapper.sh`, marked accepted per this decision: #1 the config-key false
  negative (was already noted; its stale `tasks/deferred/002c` pointer and "needs a redesign"
  framing are corrected to reference this file and the accept-&-close decision), #2 the
  script-shorthand benign false positive, and #3 the pre-existing bare-script false negative.
- Three regression tests added to `scripts/test-pnpm-shadow-wrapper.sh` pinning the accepted
  behavior: `pnpm build install` → warns (accepted benign false positive), `pnpm --registry run
  install` → silent (accepted exotic false negative; flips/fails if a future change enumerates
  config-key globals, forcing a conscious re-decision), and bare `pnpm build` → silent (accepted
  pre-existing gap).
- All existing task-002b `assert_warns` guarantees are retained (no existing stage modified or
  removed); the full suite still passes.

The codex P3 thread (PR #70, `#discussion_r3448851646`, "Stop latching script arguments as install
commands") is **closed by this decision** with no code change to the resolver.

Mapping back to the Acceptance section above:

- Case 1 decision: the benign false positive is **explicitly accepted** (approach C) — `pnpm
  <local-script> <install-word>` with satisfied deps still warns, by design.
- The task-002b false-negative guarantees still hold (every existing `assert_warns` case retained).
- Case 3 is **not taken on** — recorded as a documented, accepted gap rather than fixed (it would
  need the redesign declined here).
- Approach A was **not** chosen, so no value-taking-flag drift guard is added.
- New regression tests cover the chosen (accepted) behavior, as required.
