# 009 — Give the privileged workspace-perms backstop the launcher's *true* host source

## Why this task exists

PR #73 (`chown-defense`) added the sensitive-host-path guard that refuses to recursively
`chown` a `/workspace/<slug>` whose **host bind-mount source is a system or home directory**
(the VPS-lockout incident: a `cc`/`cx` accidentally launched from `~` bind-mounts the whole
home tree; the entrypoint's ownership-heal then re-owns `~/.ssh` and its parent to `node`,
breaking sshd's `StrictModes` chain and locking the user out of the host).

During that PR's review, **Codex raised a P2** against the privileged backstop in
`docker/shared/fix-workspace-perms.sh` that we accepted as real but **deferred to this task**
to keep the PR's scope tight (maintainer decision, PR #73 address-review session,
2026-06-30). Thread: <https://github.com/Roubtec/powbox/pull/73#discussion_r3502374081>.

This task closes that gap.

## The gap (Codex P2)

`fix-workspace-perms.sh` derives the host source **only** from `/proc/self/mountinfo`
(`powbox_mountinfo_host_src`, mountinfo **field 4** = "root"). The doc/comments framed this as
an *independent* backstop that "holds even if this helper is invoked directly with a sensitive
workspace." **That is only true when the source lives on the same filesystem as `/`.**

mountinfo field 4 is the pathname of the mount's root **within its source filesystem**, *not*
the absolute host path. On a host where **`/home` is a separate mount** (a very common layout),
a bind of `/home/alice` has:

```
field 4 (root)  = /alice           <-- what powbox_mountinfo_host_src returns
field 5 (mount) = /workspace/<slug>
```

`/alice` is not the filesystem root, not a bare system/home root, and not one component under
`/home` or `/Users`, so `powbox_is_sensitive_host_path` returns **not sensitive** → a direct
`sudo /usr/local/bin/fix-workspace-perms.sh /workspace/<slug>` against a home bind on such a
host **falls through to the recursive `chown`**, reintroducing the exact SSH-lockout case the
backstop is meant to prevent.

## What is NOT broken (why the PR was still mergeable / why this is defense-in-depth)

The **primary, automatic incident path is already fully guarded on every mount layout** and does
**not** depend on mountinfo:

- The launcher (`scripts/launch-agent.{sh,ps1}`) forwards the **true absolute** host paths in
  dir-mounted mode: `POWBOX_WORKSPACE_HOST_PATH=$PROJECT_PATH` (`pwd -P`-resolved) and
  `POWBOX_WORKSPACE_HOST_HOME` (physically resolved). `pwd -P` yields the real absolute path
  regardless of separate-mount layout, so `/home/alice` is forwarded as `/home/alice`, not `/alice`.
- `heal-workspace-perms.sh` (the startup heal, run as `node` before the agent) classifies using
  **both** that env **and** mountinfo, and **skips** any workspace either signal calls sensitive.
  So the accidental `cc`-from-`~` case is caught by the env signal even where mountinfo under-detects.

The gap is therefore limited to the **privileged helper's independent re-check** exercised by a
**direct** `sudo fix-workspace-perms.sh` invocation — because `sudo`'s `env_reset` strips
`POWBOX_*` before the helper runs, so the helper never sees the launcher's true path and is left
with only the (layout-dependent) mountinfo value. This is a secondary, defense-in-depth check,
not the primary guard.

## Threat model (decided — read before designing)

We defend against **user oversight**, not an **adversarial `node`**. The container is the trust
boundary; `node` runs the agent with full autonomy and can already `sudo fix-workspace-perms.sh`
on any `/workspace` path. The danger we prevent is an *accidental* home/system chown, not a `node`
process deliberately defeating its own safety net.

Consequences for the design (maintainer decision, PR #73 session):

- **The residual issue is plumbing, not security.** `node` is not "forging" anything — `env_reset`
  simply prevents the launcher's already-correct path from *reaching* the privileged helper.
- **Do NOT build a tamper-proof mechanism** (no root-owned, write-once recorder; no privileged
  "source recorder" script; no new sudoers command). We explicitly **do not** defend against a
  user who rewrites `POWBOX_WORKSPACE_HOST_PATH` early in container start — if they have gone that
  far, it is their call. Recording this as a **non-goal** so the implementer does not over-build.

## Goal

Make the privileged backstop classify on the **launcher's true absolute host source** for the
project workspace, so a direct `sudo fix-workspace-perms.sh` refuses a `/home/alice`-style bind
on separate-mount layouts — **without** the false-positives of a mountinfo-only heuristic and
**without** changing the documented contract (see "Rejected approaches").

## Scope / suggested approach

Pick the **simplest** option that lands the true path in the helper; both keep `mountinfo` as a
**fallback** for contexts with no launcher signal (a container started without the launcher, a
test, a workspace the launcher did not mount):

- **Option S1 — sudoers `env_keep` (smallest).** Let `fix-workspace-perms.sh` receive
  `POWBOX_WORKSPACE_HOST_PATH` / `POWBOX_WORKSPACE_HOST_HOME` through `sudo` by adding an
  `env_keep` (or `SETENV`) for exactly those vars on that one command in
  `docker/base/Dockerfile`'s sudoers line. The helper then classifies on the env's true path,
  falling back to `powbox_mountinfo_host_src` when the env is unset.
  - **Caveat:** the helper takes **multiple** workspace args, but the env is a **single** value —
    it cannot disambiguate which source belongs to which mount. Fine while dir-mount mode mounts a
    single project workspace (the common case), but fragile if more than one `/workspace/<slug>`
    is ever passed. Prefer S2 if you want that robustness.

- **Option S2 — a plain startup marker map (recommended).** Have the entrypoint (or the heal, at
  trusted startup, as `node`) write a small marker — e.g. `/run/powbox/workspace-sources` — mapping
  the **container mountpoint** (`/workspace/<slug>`) → its **true absolute host source** (from
  `POWBOX_WORKSPACE_HOST_PATH`). The helper looks up its `ws` argument in that map and classifies
  on the recorded true source, falling back to `powbox_mountinfo_host_src` when there is no entry.
  - The marker need **not** be root-owned or write-once (per the threat model above) — a plain,
    `node`-writable file under a dedicated path (`/run/powbox/`, tmpfs, per-boot) is sufficient.
  - Per-mountpoint keying fixes the multi-arg ambiguity of S1. The launcher only knows the single
    project source, so the map normally has one entry (the project) — which is exactly the mount
    that can be `~`; other mounts fall back to mountinfo. That is sufficient and correct.

Either way:

- Keep `powbox_is_sensitive_host_path` and the `powbox_mountinfo_host_src` decoder untouched
  (they are correct); the change is **which source string** the helper feeds the predicate, and a
  fallback chain (true source → mountinfo).
- Update `fix-workspace-perms.sh`'s comment block: PR #73 will already have replaced the
  overclaim with an honest note about the separate-mount limitation and a pointer to this task —
  when this lands, rewrite it to describe the true-source-with-mountinfo-fallback behavior.
- Keep the existing containment / uid-0-only / volume-prune / idempotency safety properties intact.

## Rejected approaches (do not reintroduce)

- **"Refuse any single-component mountinfo source" (depth-1 heuristic).** Would catch `/alice` but
  also refuse legitimate depth-1 project mounts. It **contradicts the documented contract and the
  unit test** — `scripts/test-sensitive-host-path.sh` asserts `expect_sensitive 1 /projects`
  (line ~72) and `/code/myrepo` heal normally. The helper cannot distinguish `/alice`
  (home on separate `/home`) from `/projects` (a real top-level project on a separate mount) from
  mountinfo alone, so this over-refuses real projects. Rejected in the PR #73 session.
- **Tamper-proof root-owned write-once recorder.** Correct against an adversarial `node`, but the
  threat model is accidental oversight, so it is unnecessary complexity. Rejected (see Threat model).
- **Reconstructing the absolute path from inside the container.** Not feasible: the container sees
  only its own mountinfo (one entry: field 4 within the source fs, mountpoint `/workspace/<slug>`);
  the host's `/home` mount is not visible, so the parent chain cannot be walked to an absolute path.

## Acceptance criteria

- On a native-Linux host with a **separate `/home` mount**, a **direct**
  `sudo /usr/local/bin/fix-workspace-perms.sh /workspace/<slug>` against a `/home/<user>` bind is
  **refused** (true-source classification), with the existing sensitive-source refusal message —
  no recursive `chown`.
- A genuine project bind (e.g. `/home/<user>/repo`, `/srv/app`, `/projects`) still heals — no
  new false-positive refusals, and the `test-sensitive-host-path.sh` contract (incl. `/projects`,
  `/code/myrepo`) is unchanged.
- The automatic startup heal behaviour is unchanged (it was already correct).
- `mountinfo` remains a working fallback when no launcher signal is present (helper invoked without
  the env/marker still behaves as it does today — best-effort).
- Smoke coverage: extend `scripts/smoke-test-dirmount.{sh,ps1}`'s `fix-mountinfo-backstop` case (or
  add a sibling) so the **true-source** path is exercised, and so reverting this task's change makes
  it fail. Note the existing case already self-skips (exit 42) when a host reports a non-sensitive
  bind source — this task removes the need for that skip on the covered path.
- `shellcheck` / `shfmt` clean (and PSScriptAnalyzer clean for any `.ps1` change).

## Context / references

- Gap thread (Codex P2): <https://github.com/Roubtec/powbox/pull/73#discussion_r3502374081>
- Helper: `docker/shared/fix-workspace-perms.sh` (baked to `/usr/local/bin/`; NOPASSWD sudoers
  entry in `docker/base/Dockerfile` ~line 210, which currently grants no `env_keep`/`setenv`).
- Predicate + mountinfo parser: `docker/shared/sensitive-host-path.sh`; unit test
  `scripts/test-sensitive-host-path.sh` (asserts the documented depth-1 contract).
- Heal (already-correct primary guard, uses env + mountinfo): `docker/shared/heal-workspace-perms.sh`.
- Launcher env source of truth: `scripts/launch-agent.sh` (`POWBOX_WORKSPACE_HOST_PATH`/`_HOME`,
  set only in dir-mounted, non-`--isolated` mode) and its PowerShell mirror `scripts/launch-agent.ps1`.
- Live guard smoke: `scripts/smoke-test-dirmount.sh` (`ASSERT_SCRIPT_SENSITIVE`,
  `ASSERT_SCRIPT_FIX_BACKSTOP`).
- Origin: PR #73 address-review session (2026-06-30).

## Validation

On a native-Linux host with `/home` on its own filesystem: bind a `/home/<user>` dir at
`/workspace/<slug>` and run the privileged helper **directly**; confirm it now refuses (true-source
classification) where today it would `chown`. Confirm a real project bind
(`/home/<user>/repo`, `/projects`) still heals. Re-run `scripts/test-sensitive-host-path.sh`
(unchanged, green) and the dir-mount smoke. `shellcheck`/`shfmt` clean.

## Review plan

Reviewer confirms: the helper classifies on the launcher's true absolute source for the project
mount and refuses the separate-`/home` case; mountinfo still works as a fallback; **no** new
false-positive refusals for legitimate projects; the documented depth-1 contract and its unit test
are untouched; no tamper-proof machinery was added beyond the agreed threat model; the smoke
exercises the true-source path and fails if this change is reverted.

## Status

**Not started.** Deferred from PR #73 (maintainer decision, keep PR scope tight). Actionable once
PR #73 merges; branch off the post-#73 `main` since it edits `fix-workspace-perms.sh` and the
dir-mount smoke that PR touches.
