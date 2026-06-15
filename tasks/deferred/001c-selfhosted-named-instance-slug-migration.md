# Task 001c — Keep pre-existing named self-hosted instances discoverable after the --name slug change

Follow-up to **Task 001** (self-hosted `--isolated` mode) and PR #56 ("prominent instance names"). Parked in `tasks/deferred/` because the branch is defendable as-is (no data loss — the old container/volume are orphaned, not deleted — and `--reclone`/manual `docker` recovery exist), while the proper fix is a new cross-launcher compatibility-lookup mechanism plus a permanent legacy code path: too much to fold into a review-fix commit on a PR whose point is *adding* the slug.

## Background — the trap

PR #56 weaves a cosmetic `--name` slug into `PROJECT_NAME` for self-hosted instances, but the slug does **not** change the identity hash (the hash still hashes the RAW `--name`):

- Before: `PROJECT_NAME="${REPO_SLUG}-${INSTANCE_HASH}"` → container `claude-<repo>-<hash>`.
- After (`scripts/launch-agent.sh:352-353`): `PROJECT_NAME="${REPO_SLUG}${NAME_SLUG:+-${NAME_SLUG}}-${INSTANCE_HASH}"` → container `claude-<repo>-<name>-<hash>`.
- `INSTANCE_LABEL`/`INSTANCE_HASH` (`scripts/launch-agent.sh:338-343`) are unchanged — named `--isolated` instances were already a released, reusable feature on `main` before this PR.

Net effect: for any **named** `--isolated` container created *before* this change, relaunching the same repo + `--name` now computes `claude-<repo>-<name>-<hash>` and no longer matches the existing `claude-<repo>-<hash>`. Because the reuse check (`docker container inspect "$CONTAINER_NAME"`) and the workspace volume (`agent-ws-${CONTAINER_NAME}`) both key off the new `CONTAINER_NAME`, the existing container and its `agent-ws-*` volume are silently skipped and a **fresh clone** is created. The PowerShell launcher (`scripts/launch-agent.ps1`, the `$projectName`/`$containerName` construction around line 200) mirrors the same break.

This is **P2** (Codex): no data loss — the old container and volume persist and are still reachable via `docker ps -a` / `cc-list` — but a relaunch surprises the user with a brand-new clone and an orphaned old instance, and any in-container session history on the old instance is no longer auto-resumed.

Review thread: https://github.com/Roubtec/powbox/pull/56#discussion_r3410548549 (codex, P2).

## Recovery path that already exists (why deferral is safe)

The old instance is never destroyed, so a user can: relaunch with the old behaviour by not upgrading; find the old container with `cc-list` / `cx-list` / `agent-list` (now that PR #56 also surfaces instance name/repo/ref) and `docker start` it directly; or accept the fresh clone and prune the old one. The gap is purely a silent, surprising fresh-clone on the first post-upgrade relaunch of a *named* instance.

## Goal

When a named `--isolated` launch finds no container/volume under the new slugged name but a legacy-named one (same repo + `--name`, i.e. same `INSTANCE_HASH`) exists, reuse the legacy instance seamlessly instead of silently forking a fresh clone — without ever attaching to or wiping the wrong instance.

## Suggested approach (preferred: legacy-name fallback; rejected: rename/migrate in place)

**Preferred — compute the legacy name and fall back to it when the new name is absent.**
- Derive `LEGACY_PROJECT_NAME="${REPO_SLUG}-${INSTANCE_HASH}"` (the pre-slug shape) and `LEGACY_CONTAINER_NAME="${AGENT}-${LEGACY_PROJECT_NAME}"` / `agent-ws-${LEGACY_CONTAINER_NAME}` alongside the new ones, **only** in the named-isolated branch (`INSTANCE_NAME` non-empty); unnamed instances never had a stable name to migrate.
- When the new-named container does **not** exist (`docker container inspect` fails) **and** the legacy-named container **or** its `agent-ws-*` volume **does** exist, adopt the legacy `CONTAINER_NAME`/`WS_VOLUME`/`PROJECT_NAME` for the rest of the launch so the reuse path, `--reclone`, the warning gates, and the workspace volume all target the existing instance. Otherwise keep the new slugged name (true first launch).
- Emit a one-line note when the fallback fires (e.g. "reusing pre-slug instance `claude-<repo>-<hash>`; new launches of this name keep the legacy name") so the behaviour is visible, not silent.
- **Subtlety — volume can outlive the container.** Mirror Task 001b's lesson: a pruned container may leave its `agent-ws-*` volume behind, so the fallback must check the legacy **volume** as well as the legacy **container**, not just one.
- **Subtlety — don't double-stamp identity.** The legacy instance predates the `powbox.instance-name`/`repo`/`ref` labels; reusing it via `docker start` won't add them (labels are frozen at create). That is acceptable (the `<no value>`/empty normalization added in PR #56 already renders an unlabeled instance as a bare `[self-hosted]`); document that legacy instances stay unlabeled until recreated.

**Why not rename/migrate in place:** `docker rename` + `docker volume` rename (volumes can't be renamed; they'd need create-copy-remove) is heavier, risks data loss on a botched copy, and gains nothing over a stable legacy-name fallback. Keep the legacy name for the legacy instance's lifetime.

## Acceptance

- A named `--isolated` instance created before the slug change (container `claude-<repo>-<hash>`, with or without a surviving `agent-ws-*` volume) is **reused** — not freshly cloned — when relaunched with the same repo + `--name` after the change, with a visible note that the legacy name is in use.
- A genuine first launch of a new named instance is unaffected (new slugged name, fresh clone).
- An unnamed `--isolated` launch is unaffected (no legacy fallback path).
- A running legacy instance is not disrupted; `--reclone` against a reused legacy instance still targets the legacy container/volume.
- `.sh` / `.ps1` parity preserved; the self-hosted smoke matrix (`scripts/smoke-test-selfhosted.{sh,ps1}`) gains a case asserting the legacy-name fallback selects the existing instance (e.g. via `POWBOX_PRINT_IDENTITY` plus a pre-created legacy-named volume/container); lint clean (shellcheck + PSScriptAnalyzer).
