# Smoke tests

Orientation for `commands/smoke-test.sh`: how the run is layered, where each part actually executes, what it costs when the network or the host cannot cooperate, and what a partial run does and does not prove.
It deliberately does **not** mirror the assertions. Where a stage has a script of its own, that script is the source of truth for what it checks and is cited below so you can open it directly (Stage 2 is inline in the umbrella and so cites none); the umbrella's per-stage comment blocks explain the wiring around it.
Routed from [AGENTS.md](../AGENTS.md) and from the README's [Host Validation](../README.md#host-validation) section, which keeps the invocation and points here for the rest.

The smoke tier needs a real built image and, in places, a relaunchable container, so it runs on the host or in CI — never from inside an agent container (see [AGENTS.md](../AGENTS.md) → "Validating Changes").

```bash
./commands/smoke-test.sh [image]        # defaults to powbox-agent:latest
```

`POWBOX_SMOKE_REQUIRE_IMAGE=1` (used by CI, and exported to every sub-script) turns an absent image into a hard error before any stage runs, instead of letting the image-gated checks self-skip into a false "all green".

## Layering

The run has two tiers: a **Stage 0 tier** of eight hermetic unit-suite entries (Stages 0a, 0b, 0d and 0f–0j, over eight distinct `scripts/test-*.sh` files), then **six image/host stages** that exercise the built image and the host.

"Hermetic" is a narrow claim: a Stage 0 entry needs no root, no host database, no nested container engine, no relaunch cycle, and no network.
It does **not** mean container-free. All eight entries `docker run --rm … "$IMAGE"` so the suite executes inside the image.

## Host source vs. baked artifact

Tier 0 is the primary home for hermetic `/repo` source suites, so Stage 0 no longer repeats any of those exact targets.

Seven entries point the suite at a **baked** artifact under `/usr/local/bin/`, so a stale or behaviorally broken installed copy is caught by a real suite instead of being waved through by Stage 1's `command -v` presence probe.
Stage 0i is the exception: `test-pnpm-shadow-wrapper.sh` validates the `/repo` source and is explicitly routed out of Tier 0 because it requires the image's writable `/workspace` production root.
The suite still self-skips when invoked directly on a generic host without that root, but both smoke umbrellas set `POWBOX_TEST_REQUIRE_WORKSPACE=1`, so an image-present Stage 0i fails if the promised production root cannot accept its fixture.

The source-versus-baked detect-shadows split shipped by task 053 is therefore deliberate: Tier 0 validates the checkout immediately, while Stage 0g validates what the image installed.
The same two-target shape now applies to sensitive-host-path, worktree orphan safety, peer-review-run and shadow-mounts; the source-only Podman Compose invariant suite stays solely in Tier 0, and the build-staged helpers vendored from agent-skills stay solely in Tier 1 — `gh-review-threads` (Stage 0b) and the `dc-enter`/`dc-remove` pair (Stage 0j).
Which suite each entry runs and which environment override selects the baked path are documented per stage in `commands/smoke-test.sh`.

## What each stage is for

- **Stage 1 — tool presence and key image config** (`scripts/smoke-test-image.sh`). The sweep every later stage assumes: expected CLIs resolve (most are genuinely invoked, a handful are presence-only probes), plus the image configuration that would otherwise regress silently. Watch `powbox-provenance`, `gitcat` and `wt-bootstrap`: no suite anywhere in the smoke ever *invokes* any of the three, so the presence probe here is the whole of their behavioral coverage — Tier 0's shellcheck step does parse them at error severity, because it extends its file list to extensionless tracked files whose shebang names a shell, but a parse is not behavior. The `wf-check` probe validates a minimal workflow and pins its private Acorn and acorn-walk versions, while `wf-status --help` proves that helper is executable; broader behavior is covered separately by the pure `scripts/test-wf-{check,status}.sh` suites against source (and real marketplace workflows when the local cache exists), not by Stage 1. `wt-bootstrap` is the near-miss that most invites over-reading: what Tier 0 and Stage 0d exercise is the reaping primitive it delegates to — `wt-common.sh`'s `wt_reap_orphan_dir` — never `wt-bootstrap` itself, so nothing the script does in its own right is covered by a test, from its `jq`/`CONTAINER_NAME` prerequisite failures through its `git worktree prune`, its container-local mountpoint checks and its live-vs-orphan classification loop to the remote push probe, the headroom measurement and the single-JSON-object output contract. One structural note that reading the probe list will not tell you: each probe is handed to the driver as a **separate argument** and executed in its own `sh -ec`, so probe text is data rather than script and a failure is reported by index against a printed manifest — but all probes share one container, so filesystem effects deliberately carry forward between them while `cd`, `export` and shell variables do not.
- **Stage 2 — `pg-dev-up` functional tests.** Stands up real throwaway PostgreSQL clusters and connects through the emitted `DATABASE_URL`, then runs `scripts/test-pg-dev-up-scoped.sh` against the `/repo` source and baked server binaries; together they reach role/db creation, URL encoding, DSN, collision handling and worktree/profile isolation that `pg-dev-up check` (binary presence only) cannot.
- **Stage 3 — rootless Podman engine** (`scripts/smoke-test-podman.sh`). Runs the image with the launch-time device and security wiring the launcher normally supplies via the compose overlays, so a base/Podman bump that regresses the engine is caught. Static engine wiring first, then a nested half: a nested run, a bridge network with a published port, and a Compose exec-form health check driven through the `docker compose` shim spelling. See [rootless-podman.md](rootless-podman.md) → "Compose health-check behavior".
- **Stage 4 — self-hosted (`--isolated`) launch mode** (`scripts/smoke-test-selfhosted.sh`). Stage A validates the launcher's identity contract through the `POWBOX_PRINT_IDENTITY` hook, which exits before any Docker call and so needs no image, daemon, or network. Stage B validates the baked `seed-workspace.sh` clone/reuse/`--reclone`/failure behavior and the single-mount hardlink layout against the image, self-skipping when the image is absent. `POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE=1` runs Stage A only.
- **Stage 5 — native-Linux dir-mount ownership** (`scripts/smoke-test-dirmount.sh`). A bind-mounted root-owned repo that the `node` agent (uid 1000) cannot write must be healed by the entrypoint's write probe plus the sudo-allowlisted `fix-workspace-perms.sh` — and must instead be **refused** when the mount's host source is a system or home directory, which makes this the live end-to-end counterpart of the sensitive-host-path suite (Tier 0 source / Stage 0a baked). It drives the extracted `heal-workspace-perms.sh` decision unit, so the decision path is guarded and not merely the helper; no case boots the full entrypoint chain.
- **Stage 6 — durable worktree-metadata recreate lifecycle** (`scripts/smoke-test-worktree-metadata.sh`, task 017). The headline acceptance criterion: in dir-mounted mode a linked git worktree and its per-worktree admin metadata survive a container stop/recreate, because the metadata is bound from the persistent `.worktrees` volume over `.git/worktrees` rather than living in the tmpfs shadow that vanishes on recycle. Two throwaway containers on one named volume; the first one's inner script lives in `scripts/smoke-test-worktree-metadata-container-a.bash`, shared verbatim with the PowerShell mirror. The mountpoint-ownership assertions added by task 053 run on the **host** after that container exits, so a plain `stat` sees the underlying directory rather than the mount stacked on it. Needs the image and a runtime that can grant `CAP_SYS_ADMIN` for the `mount --bind`.

Stage 6's ownership assertions compare each created mountpoint with its deepest pre-existing ancestor rather than with `$(id -u)`, so a squashing filesystem passes instead of failing spuriously — at the price of three conditions under which a green proves nothing: a squashing filesystem, a rootless engine (the container's root maps to the invoker), and the smoke itself run as root on the host.
The latter two are detected and announced in the log; the first cannot be probed portably, so real teeth come only from an unprivileged host user on a rootful Linux engine — the native-Linux CI runner, or a stock Linux desktop install.

## Network

Two stages reach the public network, and each only in part: Stage 3's nested half pulls container images into a throwaway container's empty graphroot, and Stage 4's Stage B clones a small public repo (`POWBOX_SMOKE_PUBLIC_REPO`, default `octocat/Hello-World`).
Everything else runs against the already-present local image and the host — the whole Stage 0 tier, Stage 1, Stage 2, Stage 5 and Stage 6 make no outbound request.

What an unreachable registry or remote costs is not uniform:

- Stage 3's Alpine pull **aborts** the stage, while its distroless `pause` pull **degrades** to a recorded skip of just the XFAIL reproduction.
- Stage 4 fails if the fixture repo cannot be cloned. Do not read that as "any clone failure aborts": several of Stage B's cases *expect* a failure — a nonexistent repo, an `ssh://` URL to one — and the failure is the assertion, captured and validated rather than propagated. A bogus `--ref` is the deliberate counter-case: it does **not** abort the clone at all, because the default branch is cloned first and only the post-clone checkout of the ref fails, benignly — a warning, and a valid checkout left on the default branch.

## Partial runs, host gates, and skipping

Stages self-skip rather than fail when the host cannot provide what they need, and skips are collected into an end-of-run banner.

Five of the six image/host stages are gated by independent environment variables — `POWBOX_SMOKE_SKIP_DB` (Stage 2), `POWBOX_SMOKE_SKIP_PODMAN` (Stage 3), `POWBOX_SMOKE_SKIP_SELFHOSTED` (Stage 4), `POWBOX_SMOKE_SKIP_DIRMOUNT` (Stage 5), and `POWBOX_SMOKE_SKIP_WORKTREE_META` (Stage 6).
Setting all five leaves the Stage 0 tier plus Stage 1 — no host database, no nested engine, no relaunch cycle — though the eight Stage 0 entries and Stage 1 itself still start throwaway containers from the image.
Stage 1 has no skip variable of its own: it is the residue that remains when all five are set, and a missing image makes it fail and abort the run before any later stage executes, so there is nothing to gain from skipping it.

On a host that cannot expose `/dev/net/tun` (for example the Docker Desktop VM under the default `auto`), Stage 3 still validates the static engine wiring but skips its whole nested half — the nested run, the published-port check **and** the Compose exec-form health check.
Force the full check with `POWBOX_PODMAN=on`, or skip the whole stage with `POWBOX_PODMAN=off` (deprecated alias `POWBOX_FUSE=off`).
A genuinely broken image — missing engine, dropped drop-in — fails the stage on any host.

### The banner is not complete

Every **requested** skip reaches the banner, because the umbrella records those itself.
A **runtime** self-skip decided inside a child script has no channel of its own other than the `POWBOX_SMOKE_SKIP_MARKER` mechanism, and marker wiring exists for exactly three children: Stages 3, 5 and 6 — though a skip can still reach the banner without the child's help when the umbrella re-evaluates the same host condition itself, which is how Stage 3's tun-driven nested-half skip is recorded.

Stage 4's child is handed no marker — on either umbrella — so its runtime self-skips are invisible, and a run in which they fired still ends `Smoke test complete (all stages ran)`.
In practice this bites when `POWBOX_SMOKE_PUBLIC_REPO` points at something other than the default: two of Stage B's ref cases assert against Hello-World-specific contents and silently self-skip unless `POWBOX_SMOKE_REF_PATH` and `POWBOX_SMOKE_REF_BRANCH` are supplied too.
So read the banner as complete for a run against the default public repo, or one that supplies both ref overrides, and as silent about those cases otherwise.

## CI gating

Two layered workflows cover this from CI, and **both carry the repo's `non-code` label gate** — though only Tier 0 subscribes to `labeled`/`unlabeled` events, so toggling the label re-evaluates Tier 0 at once, while Tier 1 reads its gate only on the next `opened`/`synchronize`/`reopened` event and an already-queued or running Tier 1 is not called off:

- **Tier 0** (`.github/workflows/native-linux-ci.yml`) — static guards plus the auto-discovered native-Linux-hermetic source suites through `scripts/run-pure-shell-tests.sh`. No image or Docker; the suites run in parallel and finish in about a minute on the measured container.
- **Tier 1** (`.github/workflows/native-linux-build.yml`) — builds the agent image and runs the smoke under `POWBOX_SMOKE_REQUIRE_IMAGE=1`, so an absent image is a hard error rather than a run whose image-gated checks self-skip into a false green. That flag reaches only the image-dependent skips: the hosted runner exposes no `/dev/net/tun`, so Stage 3's nested half self-skips there — see "Partial runs, host gates, and skipping" above — and a green Tier 1 is a partial smoke, not a full one. Additionally path-gated to image-affecting paths and to PRs targeting `main`.

See README "Continuous Integration" for the trigger paths and caching.

## The PowerShell mirror

`commands/smoke-test.ps1` runs the same inventory wherever `pwsh` runs, including a native-Linux host, and takes `-SkipDb -SkipPodman -SkipSelfHosted -SkipDirMount -SkipWorktreeMeta` plus `-RequireImage` in place of the environment variables.

Its eight Stage 0 entries match the Bash targets.
Stage 6 mirrors the mountpoint-ownership assertions too (task 053a): both drivers hand Container A the same shared inner script, `scripts/smoke-test-worktree-metadata-container-a.bash`, so that half cannot drift, while each implements the ~40 host-side lines natively.
One deliberate, narrower divergence remains: the PowerShell driver runs those ownership assertions only on a native-Linux host and records a counted `Note-Skip` otherwise, because a Windows/macOS bind mount squashes `uid:gid` and every comparison would then pass vacuously — a green that proves nothing is worse than an announced skip.
The gate is documented in `scripts/smoke-test-worktree-metadata.ps1`'s header.

The mirror is not left to host runs alone: Tier 1 (`.github/workflows/native-linux-build.yml`) runs `scripts/smoke-test-worktree-metadata.ps1` in its own step after the Bash umbrella, because `commands/smoke-test.sh` never invokes the PowerShell driver and the hosted runner — native Linux, rootful daemon, unprivileged `runner` invoker — is the only automated configuration where those assertions have teeth.
That step is stricter than the umbrella in two ways: a runtime self-skip fails it (on that runner every skip reason is impossible, so a skip means the coverage stopped running), and it counts the three `ok: mountpoint ownership` lines, so a green proves the assertions were reached rather than merely that the driver started.
Only Stage 6 runs there; the other PowerShell stages would re-check what the Bash umbrella just checked.
