# Task 005a — Exercise the real entrypoint in the dir-mount ownership smoke stage

Follow-up to task [005](../005-dir-mount-ownership-smoke-stage.md) from the PR #61 review. Parked in `tasks/deferred/` because the current stage is a deliberate, task-sanctioned isolation test (it validates the baked helper + sudoers wiring, exactly as task 005's scope permits and as the sibling `smoke-test-selfhosted.sh` Stage B does), while closing the residual gap requires booting the full entrypoint chain — which needs the launcher's compose wiring (firewall/gh/shadow caps) and so expands the PR's scope considerably. The branch is defendable as it stands: it builds, is `shellcheck`/`shfmt`/`Invoke-ScriptAnalyzer` clean, and guards the helper + sudoers regression it set out to guard.

Review thread:
- https://github.com/Roubtec/powbox/pull/61#discussion_r3445129065 (codex, P2) — "Exercise the real entrypoint in the dir-mount smoke test."

## Background — the gap

`scripts/smoke-test-dirmount.{sh,ps1}` run the in-container assertion with `--entrypoint /bin/bash` (now also `--user node`). Docker's `--entrypoint` **overwrites** the image `ENTRYPOINT`, so `/usr/local/bin/entrypoint-agent.sh` and `entrypoint-core.sh` never execute in this stage. The assertion instead re-implements the write probe (`mktemp` in the workspace root) and invokes `sudo /usr/local/bin/fix-workspace-perms.sh "$WS"` **directly**.

Consequence: the stage guards the **helper + its sudoers wiring** (a dropped sudoers entry, a renamed/missing helper, a chown that doesn't claim the tree for node), but it does **not** exercise `entrypoint-core.sh`'s own write-probe and helper-invocation logic — the code that decides *whether* and *with what path/sudo mechanism* to call the helper. A regression confined to that decision path (e.g. the probe stops detecting an unwritable mount, the workspace stops being added to `_unwritable`, the helper stops being invoked, or it is invoked with a wrong path) would still pass this stage.

This is a known, documented limitation: the script header states it validates the helper "in isolation … not the full entrypoint chain — the firewall/gh/shadow setup needs the launcher's compose wiring and is out of scope here," and task 005's own scope explicitly allows "a `docker run` that reproduces the mount + entrypoint." Task [007](../007-selfheal-mixed-ownership-dir-mount.md) (PR #63), which extends this same harness with the mixed-ownership case, inherits the identical isolation limitation and does not address it either — so this is a genuinely new follow-up, not work owned by #63.

## Goal

Add end-to-end coverage that runs the **real** entrypoint write-probe → `fix-workspace-perms.sh` path (not a hand-rolled re-implementation of it) against a root-owned dir-mounted workspace, and asserts the workspace became node-writable afterward — so a regression in `entrypoint-core.sh`'s probe/decision logic is caught, not only a regression in the helper itself.

## Suggested approach (pick one)

**A. Boot the entrypoint with a minimal post-start assertion (preferred).** Run the agent image **without** overriding `--entrypoint`, dir-mounting the root-owned fixture, and have the container run the entrypoint and then a node-side assertion (e.g. via the image's normal command path, or a small wrapper CMD) that confirms `touch`/`git commit` succeed and the tree is uid-1000-owned. This requires neutralizing the parts of `entrypoint-core.sh` that need the launcher's compose wiring (firewall init / `CAP_*`, gh auth, shadow mounts): either gate them behind an existing skip/env signal, add a smoke-only entry path that runs just the workspace-perms probe step, or grant the caps the entrypoint needs. The firewall/gh/shadow setup is the reason task 005 scoped this out — that wiring is the real cost here.

**B. Factor the probe+heal step into a callable unit.** Extract `entrypoint-core.sh`'s "probe each `/workspace/<slug>` and run `fix-workspace-perms.sh` on the unwritable ones" block into a small baked helper (e.g. `/usr/local/bin/heal-workspace-perms.sh`) that `entrypoint-core.sh` calls, then have the smoke stage invoke **that** helper via `--entrypoint`. This exercises the genuine probe/decision code without booting the whole chain, at the cost of a refactor in `entrypoint-core.sh`. Coordinate with task 007, which also edits `entrypoint-core.sh`'s probe (nested uid-0 detection) — ideally land 007 first or share the extracted unit so the two probe changes don't collide.

## Acceptance

- The dir-mount smoke harness includes a case that drives the **actual** entrypoint write-probe → `fix-workspace-perms.sh` path (approach A boots the entrypoint; approach B calls the extracted probe/heal unit), not a re-implemented probe + direct helper call.
- Against the post-#55 image the new coverage passes; reverting `entrypoint-core.sh`'s probe-and-call logic (independently of the helper) makes it fail with a clear EACCES-style message — i.e. it genuinely guards the entrypoint decision path, closing the gap codex raised.
- The existing in-isolation helper assertion is retained (it still uniquely catches a sudoers/helper-path regression) or its coverage is preserved by the new path.
- Still self-skips cleanly where 005 does (image absent unless `POWBOX_SMOKE_REQUIRE_IMAGE`, no-root-fixture local dev, masked-uid host), and honours the per-stage `POWBOX_SMOKE_SKIP_DIRMOUNT` flag.
- `shellcheck`/`shfmt` clean (sh) and `Invoke-ScriptAnalyzer` clean (ps1), with `.ps1` kept CRLF.
