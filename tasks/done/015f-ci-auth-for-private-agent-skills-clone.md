> **RESOLVED (2026-07-08) — superseded by the agent-skills public flip; archived, no code change.**
> `Roubtec/agent-skills` was made **public** (task 015e step 2), so Tier 1's
> unauthenticated HTTPS clone now succeeds with the clone URL unchanged. This is
> exactly the transient-window resolution this task anticipated — **Decision option 1**
> (accept the red until the flip), which has now happened — so acceptance criterion 2
> ("After task 015e's public flip, Tier 1 clones agent-skills with no credential and no
> code change") is satisfied. No CI credential (option 2) was provisioned. Moved from
> `tasks/deferred/` to `tasks/done/`. The original task is preserved below for the record.
>
> ---

# Task 015f — Authenticate Tier 1 CI to clone the (currently private) agent-skills repo

Follow-up to **Task 015b** (consume agent-skills as a powbox build input, PR #92).
Parked in `tasks/deferred/` because the branch is defendable as it stands, the
failure is non-blocking, and the proper resolution is a maintainer decision
(accept the transient window vs. provision a CI credential) that cannot be made
from code.

Review thread: https://github.com/Roubtec/powbox/pull/92#discussion_r3537649590
(codex, P1).

## The concern

Task 015b added a host-side fetch of `Roubtec/agent-skills` to the agent build:
`fetch_agent_skills` in `scripts/build-image.sh:120-178` (and `Fetch-AgentSkills`
in `scripts/build-image.ps1:67-113`) unconditionally clones
`https://github.com/Roubtec/agent-skills.git` for any target that builds the
agent image (`./build.sh agent` / `./build.sh all`).

Tier 1 CI (`.github/workflows/native-linux-build.yml`) runs exactly those
commands on a clean `ubuntu-latest` runner with `permissions: contents: read`
(line 73-74) and **no credential setup** for `agent-skills`. While that repo is
**private**, the unauthenticated HTTPS clone fails before the Docker build
starts, so every image-affecting PR targeting `main` (the Tier 1 trigger) fails
at the fetch step — including PR #92 itself.

## Why deferral is safe (branch defendable as-is)

- **Not merge-blocking.** Tier 1 is not a required status check: `main` is
  protected by the `main-guard` ruleset (PR required, no force-push/deletion) but
  has **no required checks** (see the workflow header, lines 18-26). A red Tier 1
  is visible but cannot block a merge today.
- **The documented build path works.** `./build.sh agent` is meant to run on a
  host where the gh credential helper is configured (the whole reason the fetch
  is host-side and not a `RUN git clone`); there the clone succeeds.
- **A planned resolution already exists and needs no code change.** Task
  `015e-post-migration-checklist.md` step 2 flips the repo public
  (`gh repo edit Roubtec/agent-skills --visibility public`). After that flip the
  unauthenticated CI clone succeeds with the HTTPS URL unchanged — so the CI
  breakage is **transient**, bounded by the window between PR #92 merging and the
  public flip.

## Decision needed (why it is parked, not auto-fixed)

Pick one; both are legitimate:

1. **Accept the transient red Tier 1** until task 015e flips the repo public.
   No code/CI change; just awareness that image PRs show a failing Tier 1 in the
   interim (non-blocking).
2. **Provision an interim CI credential** so Tier 1 is green even while the repo
   is private. This needs a maintainer to create a repo/organization secret
   (a fine-grained PAT or a deploy key with read access to `Roubtec/agent-skills`)
   and decide the injection mechanism — an authoritative call, hence deferred.

## If option 2 is chosen — implementation sketch

- Add a step to `native-linux-build.yml` before "Build image" that scopes a
  credential to the agent-skills clone, e.g. a git credential rewrite:
  `git config --global url."https://x-access-token:${{ secrets.AGENT_SKILLS_TOKEN }}@github.com/Roubtec/agent-skills".insteadOf https://github.com/Roubtec/agent-skills`
  so `build.sh`'s existing clone URL works untouched.
- **Prefer credential injection over a pre-`actions/checkout` of agent-skills
  into `.agent-skills-src`.** `fetch_agent_skills` reuses an existing
  `.agent-skills-src/.git` only when `remote.origin.url` matches the HTTPS URL
  exactly (`scripts/build-image.sh:130-131`); otherwise it `rm -rf`s and
  re-clones. A pre-checkout that leaves a different origin (or a token-embedded
  URL) would be wiped and re-cloned unauthenticated, re-introducing the failure.
  The `insteadOf` rewrite leaves `build.sh` to do its own (now-authenticated)
  clone and composes cleanly.
- Keep the token out of the image: the clone is host-side and only the
  `codex/dev-skills/skills/` subtree is COPYed (and `.dockerignore` excludes the
  staging `.git`), so no credential reaches a layer — but confirm no step echoes
  the tokenized URL.

## Acceptance

- With the repo still private, Tier 1 (`native-linux-build.yml`) either (option 1)
  is knowingly accepted as red until the public flip, or (option 2) completes the
  agent-skills clone and builds the image green.
- After task 015e's public flip, Tier 1 clones agent-skills with no credential
  and no code change (verifying the transient-window reasoning).
- `.sh` / `.ps1` fetch parity preserved if any credential wiring lands.
