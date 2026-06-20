# Task 007a — Make the dir-mount smoke guard the entrypoint's nested-uid-0 scan (not just the helper)

Follow-up from the PR #63 review (self-heal mixed-ownership dir-mounted workspaces, stacked on #61).
Parked in `tasks/deferred/` because the current mixed-ownership smoke is **defendable as-is** — it tightly guards the substantive new logic of 007 (the helper's node-owned-root path) — and closing the remaining gap requires either an end-to-end entrypoint run (which needs the launcher's compose wiring: firewall `CAP_NET_ADMIN`, shadow `CAP_SYS_ADMIN`, gh auth) or factoring the entrypoint detection into an independently invocable unit. Both expand scope into the helper-in-isolation smoke architecture established on #61's branch (`task/005-dir-mount-ownership-smoke-stage`), so this is an **agent-proposed deferral** pending maintainer confirmation.

Review thread:
- https://github.com/Roubtec/powbox/pull/63#discussion_r3445242133 (codex, P2) — "Exercise entrypoint in the mixed smoke": the mixed case runs `docker run --entrypoint /bin/bash … -c "$ASSERT_SCRIPT_MIXED"` and the assertion invokes `fix-workspace-perms.sh` directly, so reverting or deleting the new nested-uid-0 scan in `entrypoint-core.sh` would leave this smoke green — it does not guard the production trigger 007 adds. Suggests running the mixed fixture through the normal entrypoint, or adding an end-to-end case for that scan.

## Background — the gap

Task 007's acceptance criterion requires that **"reverting 007's detection/chown makes [the smoke] fail"** (`tasks/007-selfheal-mixed-ownership-dir-mount.md`). 007 lands two coordinated pieces:

1. **Helper chown** (`fix-workspace-perms.sh`): broaden it to act on a node-owned root, re-owning only nested `find -uid 0` entries.
2. **Entrypoint detection** (`entrypoint-core.sh`): a short-circuiting nested-uid-0 scan (`find … -uid 0 -print -quit`, with mountpoint pruning) that hands a mixed-ownership workspace to the helper — the production *trigger* that the root-level write probe misses.

The mixed-ownership smoke stage (`scripts/smoke-test-dirmount.{sh,ps1}`, `case_mixed_ownership` / `ASSERT_SCRIPT_MIXED`) invokes `sudo /usr/local/bin/fix-workspace-perms.sh "$WS"` **directly** inside a `docker run --entrypoint /bin/bash` container — the same helper-in-isolation pattern `case_all_root` (#61/#55) and `smoke-test-selfhosted.sh`'s Stage B use, and which the smoke's own header documents as deliberate ("validates the baked helper + its sudoers wiring in isolation … not the full entrypoint chain — the firewall/gh/shadow setup needs the launcher's compose wiring and is out of scope here").

Consequence, split by which 007 piece is reverted:

- **Revert the helper chown** → caught. Pre-007 the helper refuses a non-root (node-owned) root and exits non-zero, so `ASSERT_SCRIPT_MIXED` step 2 fails. The smoke guards piece (1).
- **Revert the entrypoint detection scan** → **not caught.** The smoke bypasses `entrypoint-core.sh` entirely and calls the helper itself, so deleting the nested-uid-0 scan leaves the smoke green even though a real container would no longer self-heal. The smoke does **not** guard piece (2).

So the smoke partially satisfies the acceptance criterion: it guards the "chown" half but not the "detection" half. The branch remains defendable because the new helper logic — the part most likely to be edited incorrectly — *is* guarded, the limitation is documented and shared with the pre-existing all-root case, and the all-root case has the identical property (a revert of the entrypoint write-probe trigger would not fail it either).

## Goal

Make the dir-mount smoke fail when 007's entrypoint nested-uid-0 **detection scan** is reverted (not only when the helper chown is reverted), so the acceptance criterion is fully met — without re-breaking the all-root case and without requiring host-side capabilities the smoke deliberately avoids.

## Suggested approach (pick one)

**A. Exercise the real detection block via the actual entrypoint (most faithful).** Run the mixed fixture through `entrypoint-core.sh` rather than `--entrypoint /bin/bash`, with a CMD that performs the post-fix assertions. The obstacle is that `entrypoint-core.sh` also runs firewall init (`init-firewall.sh`, needs `CAP_NET_ADMIN`), shadow mounts (`shadow-mounts.sh`, needs `CAP_SYS_ADMIN`), and `gh auth setup-git`; the bare `docker run` here grants none of these. Either grant the needed caps in this one smoke `docker run` (heavier, closer to production) or gate/stub those best-effort steps so the entrypoint reaches the ownership block. Apply the same change to `case_all_root` so both cases guard their respective entrypoint triggers, and mirror it in the `.ps1`.

**B. Factor the detection into an independently testable unit (narrower).** Extract `entrypoint-core.sh`'s "is this workspace mixed-ownership?" decision (the write probe + the pruned `find -uid 0 -print -quit` scan, with the same self-hosted/writer-role/no-sudo exemptions) into a small sourced helper or function that both the entrypoint and the smoke call. The smoke then asserts the unit selects the mixed fixture for handoff, so reverting the scan makes the unit return "clean" and the smoke fails. Touches #63's entrypoint code and must preserve every existing exemption and the mountpoint prune; keep the entrypoint behavior byte-for-byte equivalent.

Approach A guards the real production path end-to-end; approach B is cheaper and keeps the smoke hermetic but tests a refactored copy of the trigger rather than the literal entrypoint invocation. Mirror whichever is chosen in both `scripts/smoke-test-dirmount.sh` and `scripts/smoke-test-dirmount.ps1`.

## Acceptance

- Reverting **only** the nested-uid-0 detection scan in `entrypoint-core.sh` (leaving the helper untouched) makes the dir-mount smoke **fail** with a clear message — closing the half of task 007's acceptance criterion the helper-in-isolation smoke currently misses.
- Reverting **only** the helper's node-owned-root chown path still fails the smoke (no regression to the coverage that already exists).
- The all-root-owned case (#55 / task 005) still passes and, if approach A is taken, likewise guards its entrypoint write-probe trigger.
- No new host capability is silently required of environments where the stage currently self-skips (image absent / no root / masked-uid host): the new coverage either degrades to the existing self-skip or is clearly gated.
- Behavior identical in `scripts/smoke-test-dirmount.sh` and `scripts/smoke-test-dirmount.ps1`; `shellcheck` / `shfmt` clean; PSScriptAnalyzer (house settings) introduces no new findings.

## Context / references

- Smoke harness: `scripts/smoke-test-dirmount.sh` (`case_mixed_ownership`, `ASSERT_SCRIPT_MIXED`, `run_dirmount_case`) and its `.ps1` mirror; wired via `commands/smoke-test.{sh,ps1}` Stage 5.
- Production trigger: `docker/shared/entrypoint-core.sh` nested-uid-0 scan; helper: `docker/shared/fix-workspace-perms.sh`.
- Parent task + acceptance criterion: `tasks/007-selfheal-mixed-ownership-dir-mount.md` ("reverting 007's detection/chown makes it fail").
- Origin: PR #63 review (codex P2, thread `r3445242133`).
