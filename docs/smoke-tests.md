# Smoke tests

Orientation for `commands/smoke-test.sh`: how the run is layered, where each part actually executes, what it costs when the network or the host cannot cooperate, and what a partial run does and does not prove.
It deliberately does **not** mirror the assertions. Each stage's script is the source of truth for what it checks, and is cited below so you can open it directly; the umbrella's per-stage comment blocks explain the wiring around it.
Routed from [AGENTS.md](../AGENTS.md) and from the README's [Host Validation](../README.md#host-validation) section, which keeps the invocation and points here for the rest.

The smoke tier needs a real built image and, in places, a relaunchable container, so it runs on the host or in CI — never from inside an agent container (see [AGENTS.md](../AGENTS.md) → "Validating Changes").

```bash
./commands/smoke-test.sh [image]        # defaults to powbox-agent:latest
```

`POWBOX_SMOKE_REQUIRE_IMAGE=1` (used by CI, and exported to every sub-script) turns an absent image into a hard error before any stage runs, instead of letting the image-gated checks self-skip into a false "all green".

## Layering

The run has two tiers: a **Stage 0 tier** of nine hermetic unit-suite entries (Stages 0 and 0a–0h, over seven distinct `scripts/test-*.sh` files), then **six image/host stages** that exercise the built image and the host.

"Hermetic" is a narrow claim: a Stage 0 entry needs no root, no host database, no nested container engine, no relaunch cycle, and no network.
It does **not** mean container-free. With the image present only **Stage 0** and **Stage 0c** run on the host alone; the other seven entries `docker run --rm … "$IMAGE"` so the suite executes inside the image.

## Host source vs. baked artifact

This is the part that is invisible without reading the umbrella carefully, and it is why the tier has nine entries for seven suites.

All but one of the in-image entries point the suite at the **baked** artifact under `/usr/local/bin/` rather than the `/repo` source, so a stale or behaviorally broken baked copy is caught by a real suite instead of being waved through by Stage 1's `command -v` presence probe.
Stage 0e is the exception: what it validates is a `/repo` script with no baked counterpart, so it runs in-image purely for the `yq`/`jq` toolchain.

How an entry pairs host and image decides what is lost when the image is absent, and there are three shapes:

- **Baked half of a host run** (Stages 0a and 0d, paired with Stages 0 and 0c). Records a skip when there is no image — the host half already covered the source.
- **In-image instead of the host** (Stages 0b, 0e, 0g, 0h). Falls back to a host source run only when the image is missing **and** the host toolchain qualifies, else records a skip.
- **Both when it can** (Stage 0f). One entry that runs twice — the host `/repo` source and the baked helper — with each half gated, and skipped, separately.

Which suite each entry runs, which env override selects the baked path, and exactly what gates its host fallback are documented per stage in `commands/smoke-test.sh`.

## What each stage is for

- **Stage 1 — tool presence and key image config** (`scripts/smoke-test-image.sh`). The sweep every later stage assumes: expected CLIs resolve (most are genuinely invoked, a handful are presence-only probes), plus the image configuration that would otherwise regress silently. One structural note that reading the probe list will not tell you: each probe is handed to the driver as a **separate argument** and executed in its own `sh -ec`, so probe text is data rather than script and a failure is reported by index against a printed manifest — but all probes share one container, so filesystem effects deliberately carry forward between them while `cd`, `export` and shell variables do not.
- **Stage 2 — `pg-dev-up` functional test.** Stands up real throwaway PostgreSQL clusters and connects through the emitted `DATABASE_URL`, reaching the role/db creation, URL encoding, DSN and worktree-scoping behavior that `pg-dev-up check` (binary presence only) cannot.
- **Stage 3 — rootless Podman engine** (`scripts/smoke-test-podman.sh`). Runs the image with the launch-time device and security wiring the launcher normally supplies via the compose overlays, so a base/Podman bump that regresses the engine is caught. Static engine wiring first, then a nested half: a nested run, a bridge network with a published port, and a Compose exec-form health check driven through the `docker compose` shim spelling. See [rootless-podman.md](rootless-podman.md) → "Compose health-check behavior".
- **Stage 4 — self-hosted (`--isolated`) launch mode** (`scripts/smoke-test-selfhosted.sh`). Stage A validates the launcher's identity contract through the `POWBOX_PRINT_IDENTITY` hook, which exits before any Docker call and so needs no image, daemon, or network. Stage B validates the baked `seed-workspace.sh` clone/reuse/`--reclone`/failure behavior and the single-mount hardlink layout against the image, self-skipping when the image is absent. `POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE=1` runs Stage A only.
- **Stage 5 — native-Linux dir-mount ownership** (`scripts/smoke-test-dirmount.sh`). A bind-mounted root-owned repo that the `node` agent (uid 1000) cannot write must be healed by the entrypoint's write probe plus the sudo-allowlisted `fix-workspace-perms.sh` — and must instead be **refused** when the mount's host source is a system or home directory, which makes this the live end-to-end counterpart of Stage 0's predicate unit test. It drives the extracted `heal-workspace-perms.sh` decision unit, so the decision path is guarded and not merely the helper; no case boots the full entrypoint chain.
- **Stage 6 — durable worktree-metadata recreate lifecycle** (`scripts/smoke-test-worktree-metadata.sh`, task 017). The headline acceptance criterion: in dir-mounted mode a linked git worktree and its per-worktree admin metadata survive a container stop/recreate, because the metadata is bound from the persistent `.worktrees` volume over `.git/worktrees` rather than living in the tmpfs shadow that vanishes on recycle. Two throwaway containers on one named volume; the mountpoint-ownership assertions added by task 053 run on the **host** after the first exits, so a plain `stat` sees the underlying directory rather than the mount stacked on it. Needs the image and a runtime that can grant `CAP_SYS_ADMIN` for the `mount --bind`.

Stage 6's ownership assertions compare each created mountpoint with its deepest pre-existing ancestor rather than with `$(id -u)`, so a squashing filesystem passes instead of failing spuriously — at the price of three conditions under which a green proves nothing: a squashing filesystem, a rootless engine (the container's root maps to the invoker), and the smoke itself run as root on the host.
The latter two are detected and announced in the log; the first cannot be probed portably, so real teeth come only from an unprivileged host user on a rootful Linux engine — the native-Linux CI runner, or a stock Linux desktop install.

## Network

Two stages reach the public network, and each only in part: Stage 3's nested half pulls container images into a throwaway container's empty graphroot, and Stage 4's Stage B clones a small public repo (`POWBOX_SMOKE_PUBLIC_REPO`, default `octocat/Hello-World`).
Everything else runs against the already-present local image and the host — the whole Stage 0 tier, Stage 1, Stage 2, Stage 5 and Stage 6 make no outbound request.

What an unreachable registry or remote costs is not uniform:

- Stage 3's Alpine pull **aborts** the stage, while its distroless `pause` pull **degrades** to a recorded skip of just the XFAIL reproduction.
- Stage 4 fails if the fixture repo cannot be cloned. Do not read that as "any clone failure aborts": several of Stage B's cases *expect* a failure — a nonexistent repo, an `ssh://` URL to one, a bogus `--ref` — and the failure is the assertion, captured and validated rather than propagated.

## Partial runs, host gates, and skipping

Stages self-skip rather than fail when the host cannot provide what they need, and skips are collected into an end-of-run banner.

Five of the six image/host stages are gated by independent environment variables — `POWBOX_SMOKE_SKIP_DB` (Stage 2), `POWBOX_SMOKE_SKIP_PODMAN` (Stage 3), `POWBOX_SMOKE_SKIP_SELFHOSTED` (Stage 4), `POWBOX_SMOKE_SKIP_DIRMOUNT` (Stage 5), and `POWBOX_SMOKE_SKIP_WORKTREE_META` (Stage 6).
Setting all five leaves the Stage 0 tier plus Stage 1 — no host database, no nested engine, no relaunch cycle — though the seven in-image Stage 0 entries and Stage 1 itself still start throwaway containers from the image.
Stage 1 has no skip variable of its own: it is the residue that remains when all five are set, and a missing image makes it fail and abort the run before any later stage executes, so there is nothing to gain from skipping it.

On a host that cannot expose `/dev/net/tun` (for example the Docker Desktop VM under the default `auto`), Stage 3 still validates the static engine wiring but skips its whole nested half — the nested run, the published-port check **and** the Compose exec-form health check.
Force the full check with `POWBOX_PODMAN=on`, or skip the whole stage with `POWBOX_PODMAN=off` (deprecated alias `POWBOX_FUSE=off`).
A genuinely broken image — missing engine, dropped drop-in — fails the stage on any host.

### The banner is not complete

Every **requested** skip reaches the banner, because the umbrella records those itself.
A **runtime** self-skip decided inside a child script reaches it only through the `POWBOX_SMOKE_SKIP_MARKER` mechanism, and marker wiring exists for exactly three children: Stages 3, 5 and 6.

Stage 4's child is handed no marker — on either umbrella — so its runtime self-skips are invisible, and a run in which they fired still ends `Smoke test complete (all stages ran)`.
In practice this bites when `POWBOX_SMOKE_PUBLIC_REPO` points at something other than the default: two of Stage B's ref cases assert against Hello-World-specific contents and silently self-skip unless `POWBOX_SMOKE_REF_PATH` and `POWBOX_SMOKE_REF_BRANCH` are supplied too.
So read the banner as complete for a run against the default public repo, or one that supplies both ref overrides, and as silent about those cases otherwise.

## CI gating

Two layered workflows cover this from CI, and **both are skipped by the repo's `non-code` label**:

- **Tier 0** (`.github/workflows/native-linux-ci.yml`) — static guards plus the hermetic `scripts/test-detect-shadows.sh` suite against the `/repo` source. No image, no Docker, seconds.
- **Tier 1** (`.github/workflows/native-linux-build.yml`) — builds the agent image and runs the full smoke under `POWBOX_SMOKE_REQUIRE_IMAGE=1`, so no stage self-skips into a false green. Additionally path-gated to image-affecting paths and to PRs targeting `main`.

See README "Continuous Integration" for the trigger paths and caching.

## The PowerShell mirror

`commands/smoke-test.ps1` runs the same inventory wherever `pwsh` runs, including a native-Linux host, and takes `-SkipDb -SkipPodman -SkipSelfHosted -SkipDirMount -SkipWorktreeMeta` plus `-RequireImage` in place of the environment variables.

Two real differences — the first forced by Windows having no native bash, the second simply not built yet:

- It has **seven** Stage 0 entries rather than nine, because it has no host-source fallback at all. Every entry runs inside the image and self-skips when the image is absent, so the Bash tier's separate host-source-then-baked pairs (Stages 0/0a and 0c/0d) collapse into one entry each — and where the Bash tier would still have covered the `/repo` source on the host, the PowerShell umbrella covers nothing.
- Stage 6 does not yet mirror the mountpoint-ownership assertions, so a full smoke driven through the PowerShell umbrella does not exercise that check. The divergence is recorded in `scripts/smoke-test-worktree-metadata.ps1`'s header and tracked as `tasks/053a-mirror-mountpoint-ownership-smoke-in-powershell-driver.md`; until it lands, run `commands/smoke-test.sh` on Linux for the ownership coverage.
