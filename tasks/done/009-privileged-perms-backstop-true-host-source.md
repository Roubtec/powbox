# 009 — Classify the workspace-perms heal *and* privileged backstop on the launcher's *true* host source

## Why this task exists

PR #73 (`chown-defense`) added the sensitive-host-path guard that refuses to recursively
`chown` a `/workspace/<slug>` whose **host bind-mount source is a system or home directory**
(the VPS-lockout incident: a `cc`/`cx` accidentally launched from `~` bind-mounts the whole
home tree; the entrypoint's ownership-heal then re-owns `~/.ssh` and its parent to `node`,
breaking sshd's `StrictModes` chain and locking the user out of the host).

That guard classifies on `/proc/self/mountinfo` **field 4** (`powbox_mountinfo_host_src`).
mountinfo field 4 is the mount's root **within its source filesystem**, *not* the absolute
host path — and **two** PR #73 review rounds surfaced that this single fact breaks the guard in
**both directions**:

- **Gap A — under-detection (Codex P2, thread `r3502374081`, deferred to this task):** the
  privileged backstop `fix-workspace-perms.sh` can under-detect a *sensitive* source and chown it
  anyway (the SSH-lockout case reopens). Accepted as real but deferred to keep PR #73 scope tight
  (maintainer decision, PR #73 address-review session, 2026-06-30).
- **Gap B — over-detection (Codex P2, thread `r3502622441`, raised in the follow-up round):** the
  startup heal `heal-workspace-perms.sh` can over-detect a *safe* source and wrongly **skip**
  healing a legitimate checkout (the agent is left unable to write a real project). This
  **supersedes** the earlier framing in this task (and in the docs) that "the automatic startup
  heal was already correct" — it is correct for the incident path, but has this false-positive.

Both gaps have the **same root cause** and the **same fix** (classify on the launcher's true
absolute source, with mountinfo as fallback), so they are tracked together here.

## Gap A — under-detection in the privileged helper (Codex P2 `r3502374081`)

`fix-workspace-perms.sh` derives the host source **only** from `/proc/self/mountinfo`
(`powbox_mountinfo_host_src`, mountinfo **field 4** = "root"). The doc/comments framed this as
an *independent* backstop that "holds even if this helper is invoked directly with a sensitive
workspace." **That is only true when the source lives on the same filesystem as `/`.**

On a host where **`/home` is a separate mount** (a very common layout), a bind of `/home/alice`
has:

```
field 4 (root)  = /alice           <-- what powbox_mountinfo_host_src returns
field 5 (mount) = /workspace/<slug>
```

`/alice` is not the filesystem root, not a bare system/home root, and not one component under
`/home` or `/Users`, so `powbox_is_sensitive_host_path` returns **not sensitive** → a direct
`sudo /usr/local/bin/fix-workspace-perms.sh /workspace/<slug>` against a home bind on such a
host **falls through to the recursive `chown`**, reintroducing the exact SSH-lockout case the
backstop is meant to prevent.

## Gap B — over-detection in the startup heal (Codex P2 `r3502622441`)

The heal's guard (`heal-workspace-perms.sh`, ~line 89) skips healing if **either** mountinfo
**or** the launcher env calls the source sensitive:

```sh
_host_src="$(powbox_mountinfo_host_src "$_dir")"
if powbox_is_sensitive_host_path "$_host_src" "${POWBOX_WORKSPACE_HOST_HOME:-}" ||
    { [ -n "${POWBOX_WORKSPACE_HOST_PATH:-}" ] &&
        powbox_is_sensitive_host_path "$POWBOX_WORKSPACE_HOST_PATH" ...; }; then
    continue   # skip the heal
fi
```

When the project directory is **the root of its own filesystem** — a root-owned checkout whose
bind source is a dedicated mount (e.g. a disk/partition mounted at `/projects` or `/mnt/repo` on
the host, with the repo *at* that mountpoint) — mountinfo field 4 for the bind is `/`, not the
absolute host path. `powbox_is_sensitive_host_path "/"` returns **sensitive** (bare root), so the
**first** operand of the `||` short-circuits `true` **before** the authoritative
`POWBOX_WORKSPACE_HOST_PATH` (`/projects`, which is *not* sensitive) is ever consulted. The heal
therefore **skips `fix-workspace-perms.sh`** and leaves the agent unable to write an otherwise
valid, root-owned checkout.

This is a **false positive**: a wrong *skip*, which the design accepts as "a loud, recoverable
inconvenience" — so the branch is defendable as-is — but it degrades a legitimate ops layout
(dedicated repo disk) that should heal cleanly. The conservative OR (`skip if EITHER says
sensitive`) is what lets the degenerate mountinfo `/` override the true, safe env.

## What is still guarded (why the PR was mergeable / why both gaps are defense-in-depth)

The **primary, automatic incident path is guarded on every mount layout** and does **not** depend
on mountinfo alone:

- The launcher (`scripts/launch-agent.{sh,ps1}`) forwards the **true absolute** host paths in
  dir-mounted mode: `POWBOX_WORKSPACE_HOST_PATH=$PROJECT_PATH` (`pwd -P`-resolved) and
  `POWBOX_WORKSPACE_HOST_HOME` (physically resolved). `pwd -P` yields the real absolute path
  regardless of separate-mount layout, so `/home/alice` is forwarded as `/home/alice`, not `/alice`.
- `heal-workspace-perms.sh` consults **both** that env **and** mountinfo, so the accidental
  `cc`-from-`~` case is caught by the env signal even where mountinfo under-detects (Gap A does not
  reopen the incident on the automatic path).

So neither gap reopens the SSH-lockout on the automatic launcher path. What remains:

- **Gap A** is limited to the **privileged helper's independent re-check** on a **direct**
  `sudo fix-workspace-perms.sh` — `sudo`'s `env_reset` strips `POWBOX_*`, so the helper sees only
  the (layout-dependent) mountinfo value.
- **Gap B** is a **usability** regression in the heal — a real project on a dedicated-mount layout
  is wrongly skipped because the conservative OR lets a degenerate mountinfo `/` override the safe
  launcher env.

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

Make **both** the startup heal (`heal-workspace-perms.sh`) and the privileged backstop
(`fix-workspace-perms.sh`) classify on the **launcher's true absolute host source** for each
project workspace, with mountinfo as a **fallback** only when no launcher signal is recorded —
so that:

- a direct `sudo fix-workspace-perms.sh` **refuses** a `/home/alice`-style bind on separate-mount
  layouts (fixes Gap A), and
- the heal **heals** a root-owned checkout whose bind source is a whole-filesystem mount
  (`/projects`, `/mnt/repo`) instead of over-detecting the degenerate mountinfo `/` (fixes Gap B),

**without** the false-positives/negatives of a mountinfo-only heuristic and **without** changing
the documented depth-1 contract (see "Rejected approaches").

## Scope / suggested approach

Pick the **simplest** option that lands the true path in **both** consumers; both keep `mountinfo`
as a **fallback** for contexts with no launcher signal (a container started without the launcher, a
test, a workspace the launcher did not mount):

- **Option S1 — sudoers `env_keep` (smallest, helper-only).** Let `fix-workspace-perms.sh` receive
  `POWBOX_WORKSPACE_HOST_PATH` / `POWBOX_WORKSPACE_HOST_HOME` through `sudo` by adding an
  `env_keep` (or `SETENV`) for exactly those vars on that one command in
  `docker/base/Dockerfile`'s sudoers line. The helper then classifies on the env's true path,
  falling back to `powbox_mountinfo_host_src` when the env is unset.
  - **Caveat:** the helper takes **multiple** workspace args, but the env is a **single** value —
    it cannot disambiguate which source belongs to which mount. Fine while dir-mount mode mounts a
    single project workspace (the common case), but fragile if more than one `/workspace/<slug>`
    is ever passed. It also does nothing for Gap B (the heal), so it would need pairing with a
    heal-side change. Prefer S2.

- **Option S2 — a plain startup marker map (recommended, fixes both gaps at once).** Have the
  entrypoint (or the heal, at trusted startup, as `node`) write a small marker — e.g.
  `/run/powbox/workspace-sources` — mapping the **container mountpoint** (`/workspace/<slug>`) →
  its **true absolute host source** (from `POWBOX_WORKSPACE_HOST_PATH`). **Both** the heal and the
  helper look up their `ws`/`_dir` argument in that map and classify on the recorded true source,
  falling back to `powbox_mountinfo_host_src` when there is no entry.
  - Fixes Gap A (helper sees `/home/alice` → refuses) **and** Gap B (heal sees `/projects` →
    heals; the degenerate mountinfo `/` is only the fallback, used when the map has no entry).
  - The marker need **not** be root-owned or write-once (per the threat model above) — a plain,
    `node`-writable file under a dedicated path (`/run/powbox/`, tmpfs, per-boot) is sufficient.
  - Per-mountpoint keying fixes the multi-arg ambiguity of S1. The launcher only knows the single
    project source, so the map normally has one entry (the project) — which is exactly the mount
    that can be `~` (Gap A) or a whole-fs disk (Gap B); other mounts fall back to mountinfo.

Either way:

- Keep `powbox_is_sensitive_host_path` and the `powbox_mountinfo_host_src` decoder untouched
  (they are correct); the change is **which source string** each consumer feeds the predicate, and
  a fallback chain (true source → mountinfo).
- For the **heal**, the net effect is: when a recorded true source exists it is **authoritative**
  (a safe true source is no longer overridden by a degenerate mountinfo value); mountinfo is used
  only as the fallback when there is no recorded source. This is what closes Gap B.
- Update the comment blocks: PR #73 already replaced the helper's overclaim with an honest note
  about the separate-mount limitation and a pointer to this task; when this lands, rewrite the
  helper comment to describe the true-source-with-mountinfo-fallback behavior, and update the
  heal's `SAFETY GUARD` comment (which currently claims mountinfo is a trustworthy second opinion)
  to reflect true-source-authoritative + mountinfo-fallback.
- Keep the existing containment / uid-0-only / volume-prune / idempotency safety properties intact.

## Rejected approaches (do not reintroduce)

- **"Refuse any single-component mountinfo source" (depth-1 heuristic).** Would catch `/alice` but
  also refuse legitimate depth-1 project mounts. It **contradicts the documented contract and the
  unit test** — `scripts/test-sensitive-host-path.sh` asserts `expect_sensitive 1 /projects`
  (line ~72) and `/code/myrepo` heal normally. The helper cannot distinguish `/alice`
  (home on separate `/home`) from `/projects` (a real top-level project on a separate mount) from
  mountinfo alone, so this over-refuses real projects. Rejected in the PR #73 session.
- **Making `/` mountinfo not-sensitive to fix Gap B.** Would let a genuine `/`-on-host bind (the
  whole host root fs mounted in) fall through to chown — strictly worse than the false positive it
  fixes. The fix for Gap B is to prefer the **true source** over the degenerate mountinfo `/`, not
  to weaken the predicate.
- **Tamper-proof root-owned write-once recorder.** Correct against an adversarial `node`, but the
  threat model is accidental oversight, so it is unnecessary complexity. Rejected (see Threat model).
- **Reconstructing the absolute path from inside the container.** Not feasible: the container sees
  only its own mountinfo (one entry: field 4 within the source fs, mountpoint `/workspace/<slug>`);
  the host's `/home` mount is not visible, so the parent chain cannot be walked to an absolute path.

## Acceptance criteria

- **Gap A:** On a native-Linux host with a **separate `/home` mount**, a **direct**
  `sudo /usr/local/bin/fix-workspace-perms.sh /workspace/<slug>` against a `/home/<user>` bind is
  **refused** (true-source classification), with the existing sensitive-source refusal message —
  no recursive `chown`.
- **Gap B:** On a native-Linux host, a **root-owned** checkout whose bind **source is the root of
  its own filesystem** (mountinfo field 4 = `/`, e.g. a dedicated disk mounted at `/projects` or
  `/mnt/repo` with the repo at the mountpoint) is **healed**, not skipped — the heal classifies on
  the launcher's true source (`/projects`, non-sensitive) rather than the degenerate mountinfo `/`.
  Reverting this change makes the heal wrongly skip it.
- A genuine project bind (e.g. `/home/<user>/repo`, `/srv/app`, `/projects`) still heals — no
  new false-positive refusals, and the `test-sensitive-host-path.sh` contract (incl. `/projects`,
  `/code/myrepo`) is unchanged.
- The accidental `cc`-from-`~` incident is still caught on the automatic launcher path (the true
  source is `/home/<you>`/`/root` → sensitive → skip) — closing Gap B must not reopen the incident.
- `mountinfo` remains a working fallback when no launcher signal is present (either consumer invoked
  without the env/marker still behaves as it does today — best-effort).
- Smoke coverage: extend `scripts/smoke-test-dirmount.{sh,ps1}` so **both** the true-source refusal
  (Gap A) and the true-source heal of a whole-fs-mount checkout (Gap B) are exercised, and so
  reverting this task's change makes them fail. Note the existing `fix-mountinfo-backstop` case
  already self-skips (exit 42) when a host reports a non-sensitive bind source — this task removes
  the need for that skip on the covered path.
- `shellcheck` / `shfmt` clean (and PSScriptAnalyzer clean for any `.ps1` change).

## Context / references

- Gap A thread (Codex P2, under-detection): <https://github.com/Roubtec/powbox/pull/73#discussion_r3502374081>
- Gap B thread (Codex P2, over-detection): <https://github.com/Roubtec/powbox/pull/73#discussion_r3502622441>
- Helper: `docker/shared/fix-workspace-perms.sh` (baked to `/usr/local/bin/`; NOPASSWD sudoers
  entry in `docker/base/Dockerfile` ~line 210, which currently grants no `env_keep`/`setenv`).
- Heal (Gap B lives at ~line 89, the `powbox_is_sensitive_host_path ... || ...` OR):
  `docker/shared/heal-workspace-perms.sh`.
- Predicate + mountinfo parser: `docker/shared/sensitive-host-path.sh`; unit test
  `scripts/test-sensitive-host-path.sh` (asserts the documented depth-1 contract).
- Launcher env source of truth: `scripts/launch-agent.sh` (`POWBOX_WORKSPACE_HOST_PATH`/`_HOME`,
  set only in dir-mounted, non-`--isolated` mode) and its PowerShell mirror `scripts/launch-agent.ps1`.
- Live guard smoke: `scripts/smoke-test-dirmount.sh` (`ASSERT_SCRIPT_SENSITIVE`,
  `ASSERT_SCRIPT_FIX_BACKSTOP`).
- Origin: PR #73 address-review session (2026-06-30 for Gap A; 2026-07-01 for Gap B).

## Validation

On a native-Linux host with `/home` on its own filesystem: bind a `/home/<user>` dir at
`/workspace/<slug>` and run the privileged helper **directly**; confirm it now refuses (true-source
classification, Gap A) where today it would `chown`. Separately, bind a **root-owned** checkout
whose source is a whole-filesystem mount (mountinfo `/`) and confirm the **heal now heals it**
(Gap B) where today it skips. Confirm a real project bind (`/home/<user>/repo`, `/projects`) still
heals, and that the accidental-`~` case is still skipped on the launcher path. Re-run
`scripts/test-sensitive-host-path.sh` (unchanged, green) and the dir-mount smoke. `shellcheck`/`shfmt` clean.

## Review plan

Reviewer confirms: both the heal and the helper classify on the launcher's true absolute source for
the project mount; the helper refuses the separate-`/home` case (Gap A) and the heal heals the
whole-fs-mount case (Gap B); mountinfo still works as a fallback; the accidental-`~` incident is
still caught on the launcher path; **no** new false-positive refusals for legitimate projects; the
documented depth-1 contract and its unit test are untouched; no tamper-proof machinery was added
beyond the agreed threat model; the smoke exercises both the true-source refusal and the
true-source heal and fails if this change is reverted.

## Status

**Not started.** Deferred from PR #73 (maintainer decision, keep PR scope tight). Now covers **both**
review rounds' findings (Gap A under-detection in the helper, Gap B over-detection in the heal),
since they share one root cause and one fix. Actionable once PR #73 merges; branch off the post-#73
`main` since it edits `fix-workspace-perms.sh`, `heal-workspace-perms.sh`, and the dir-mount smoke
that PR touches.
