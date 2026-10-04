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
An image built from a layer set adds a seventh, Stage 1b, which runs the probes the set ships (see [Layer-set probes](#layer-set-probes-stage-1b)), and Stages 2 and 3 run only on an image that has the tool they test (see [Not applicable](#not-applicable-capability-gated-stages)).

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

- **Stage 1 — tool presence and key image config** (`scripts/smoke-test-image.sh`). The sweep every later stage assumes: expected CLIs resolve (most are genuinely invoked, a handful are presence-only probes), plus the image configuration that would otherwise regress silently. Watch `powbox-provenance`, `gitcat` and `wt-bootstrap`: no suite anywhere in the smoke ever *invokes* any of the three, so the presence probe here is the whole of their behavioral coverage — Tier 0's shellcheck step does parse them at error severity, because it extends its file list to extensionless tracked files whose shebang names a shell, but a parse is not behavior. The `wf-check` probe validates a minimal workflow and pins its private Acorn and acorn-walk versions, while `wf-status --help` proves that helper is executable; broader behavior is covered separately by the pure `scripts/test-wf-{check,status}.sh` suites against source (and real marketplace workflows when the local cache exists), not by Stage 1. `wt-bootstrap` is the near-miss that most invites over-reading: what Tier 0 and Stage 0d exercise is the reaping primitive it delegates to — `wt-common.sh`'s `wt_reap_orphan_dir` — never `wt-bootstrap` itself, so nothing the script does in its own right is covered by a test, from its `jq`/`CONTAINER_NAME` prerequisite failures through its `git worktree prune`, its container-local mountpoint checks and its live-vs-orphan classification loop to the remote push probe, the headroom measurement and the single-JSON-object output contract. One structural note that reading the probe list will not tell you: each probe is handed to the driver as a **separate argument** and executed in its own `sh -ec`, so probe text is data rather than script and a failure is reported by index against a printed manifest — but all probes share one container, so filesystem effects deliberately carry forward between them while `cd`, `export` and shell variables do not. The `command -v podman` probe is the one to keep in mind when reading Stage 3: Stage 3 runs only on an image that has the engine, so this presence probe, not Stage 3, is what fails an image that lost it.
- **Stage 1b — layer-set probes** (`smoke_layer_stage` in `scripts/smoke-test-lib.sh`). Runs only against an image built from a layer set: the probes the set ships in `docker/layers/<set>/smoke-probes.txt`, through the same `scripts/smoke-test-image.sh` driver as Stage 1, so they get the same per-probe shells and the same index → probe manifest on failure. See [Layer-set probes](#layer-set-probes-stage-1b).
- **Stage 2 — `pg-dev-up` functional tests.** Stands up real throwaway PostgreSQL clusters and connects through the emitted `DATABASE_URL`, then runs `scripts/test-pg-dev-up-scoped.sh` against the `/repo` source and baked server binaries; together they reach role/db creation, URL encoding, DSN, collision handling and worktree/profile isolation that `pg-dev-up check` (binary presence only) cannot. Both halves run only when `pg-dev-up` is on the image's `PATH`.
- **Stage 3 — rootless Podman engine** (`scripts/smoke-test-podman.sh`). Runs only when `podman` is on the image's `PATH`. Runs the image with the launch-time device and security wiring the launcher normally supplies via the compose overlays, so a base/Podman bump that regresses the engine is caught. Static engine wiring first, then a nested half: a nested run, a bridge network with a published port, and a Compose exec-form health check driven through the `docker compose` shim spelling. See [rootless-podman.md](rootless-podman.md) → "Compose health-check behavior".
- **Stage 4 — self-hosted (`--isolated`) launch mode** (`scripts/smoke-test-selfhosted.sh`). Stage A validates the launcher's identity contract through the `POWBOX_PRINT_IDENTITY` hook, which exits before any Docker call and so needs no image, daemon, or network. Stage B validates the baked `seed-workspace.sh` clone/reuse/`--reclone`/failure behavior and the single-mount hardlink layout against the image, self-skipping when the image is absent. `POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE=1` runs Stage A only.
- **Stage 5 — native-Linux dir-mount ownership** (`scripts/smoke-test-dirmount.sh`). A bind-mounted root-owned repo that the `node` agent (uid 1000) cannot write must be healed by the entrypoint's write probe plus the sudo-allowlisted `fix-workspace-perms.sh` — and must instead be **refused** when the mount's host source is a system or home directory, which makes this the live end-to-end counterpart of the sensitive-host-path suite (Tier 0 source / Stage 0a baked). It drives the extracted `heal-workspace-perms.sh` decision unit, so the decision path is guarded and not merely the helper; no case boots the full entrypoint chain.
- **Stage 6 — durable worktree-metadata recreate lifecycle** (`scripts/smoke-test-worktree-metadata.sh`, task 017). The headline acceptance criterion: in dir-mounted mode a linked git worktree and its per-worktree admin metadata survive a container stop/recreate, because the metadata is bound from the persistent `.worktrees` volume over `.git/worktrees` rather than living in the tmpfs shadow that vanishes on recycle. Two throwaway containers on one named volume; each one's inner script lives in its own file — `scripts/smoke-test-worktree-metadata-container-a.bash` and `scripts/smoke-test-worktree-metadata-container-b.bash` — shared verbatim with the PowerShell mirror. The mountpoint-ownership assertions added by task 053 run on the **host** after that container exits, so a plain `stat` sees the underlying directory rather than the mount stacked on it. Needs the image and a runtime that can grant `CAP_SYS_ADMIN` for the `mount --bind`.

Stage 6's ownership assertions compare each created mountpoint with its deepest pre-existing ancestor rather than with `$(id -u)`, so a squashing filesystem passes instead of failing spuriously — at the price of three conditions under which a green proves nothing: a squashing filesystem, a rootless engine (the container's root maps to the invoker), and the smoke itself run as root on the host.
The latter two are detected and announced in the log; the first cannot be probed portably, so real teeth come only from an unprivileged host user on a rootful Linux engine — the native-Linux CI runner, or a stock Linux desktop install.

## Layer-set probes (Stage 1b)

The smoke test keeps a core that every image must pass (Stage 1), and a layer set carries its own probes, which run only against an image built from that set.
Which set that is comes from the image under test, never from `.powbox-layers`: the run reads the image's `powbox.layers.set` label, so it describes the image it was given whatever the working tree selects.
The probes themselves come from the working tree, `docker/layers/<set>/smoke-probes.txt`.

The file holds one probe per line, run in file order, so a probe may rely on files an earlier one left behind.
Blank lines and lines whose first non-space character is `#` are ignored, and a trailing CR is stripped, so a CRLF checkout reads the same.
Nothing else is interpreted: every other line is handed to `scripts/smoke-test-image.sh` exactly as written, so every rule its header states still holds — a probe runs in its own `sh -ec`, must be self-contained, and must not end in a backslash (the driver rejects a trailing line continuation rather than run the truncated probe).
Both readers decode the file as UTF-8 and refuse one that is not valid UTF-8 or holds a NUL byte, rather than hand the two drivers different probes.

What happens depends on the label and on what the working tree holds:

1. **No label.** The image is lean: there is no Stage 1b, and that is not a skip.
2. **A set other than a committed one, no `smoke-probes.txt`.** The set ships no probes: one note line, and the run continues. This is how a user opts a set of their own out of layer tests.
3. **A committed set (`full` or `browser`), no `smoke-probes.txt`.** The run fails, naming the missing file.
4. **A committed set, no `docker/layers/<set>/` at all.** The run fails, naming the missing directory, whatever `POWBOX_SMOKE_REQUIRE_IMAGE` says.
5. **A `smoke-probes.txt` with no probe line** (empty, or only comments and blank lines). One note line naming the file, no Stage 1b, and the run continues; it is not a skip.
6. **A set other than a committed one whose directory is not in the working tree.** A warning, and a `Stage 1b` entry in the skipped list, so the run is partial; under `POWBOX_SMOKE_REQUIRE_IMAGE` the run fails instead. The entry names no skip control and no host condition: it comes back when the working tree holds the set.
7. **A digest label that differs from the working tree's digest of the set** (`scripts/layers-digest.sh`, the digest the build stamps as `powbox.layers.digest`). A warning that the image is stale relative to the set, then the probes run anyway. The digest covers every file in the set directory, `smoke-probes.txt` included, so editing the probes alone marks the image stale here and in `agent-check-updates`. The check also runs in cases 2 and 5, ahead of their note, so emptying or deleting a set's probe file still reports the image stale although there is nothing to run.

A label that is not a valid set name (`^[a-z0-9][a-z0-9._-]*$`, the rule `.powbox-layers` follows) fails the run rather than being turned into a path.

The probe file is what makes a missing tool a failure for a set.
Stages 2 and 3 report "not applicable" on an image without `pg-dev-up` or `podman` instead of failing, so a set that installs a tool must carry a presence probe for it (`command -v <tool> >/dev/null`, or something stronger) in its `smoke-probes.txt`; without one, an image that lost the tool passes.
For the committed sets, `full` and `browser`, the guard cannot be lost by deleting the file or the directory: cases 3 and 4 above fail the run. Both drivers name these sets in one list (`SMOKE_COMMITTED_LAYER_SETS` in `scripts/smoke-test-lib.sh`, `$SmokeCommittedLayerSets` in its `.ps1` mirror), so a newly committed set must be added to both lists to join the rule. For `browser` this is also what keeps Tier 1 honest: a `browser` image whose working tree lost the probe file fails Tier 1's smoke step instead of turning Stage 1b into a note.
`full`'s file carries a probe for every tool the set installs, functional checks included (the golangci-lint cache scoping, the GOBIN login-shell `PATH`, the .NET first-use sentinels), each group with its rationale as `#` lines; `browser`'s holds none yet.
The opt-out in case 2 is for sets of your own: a user who edits their own set maintains or deletes its probes.
A set contributes in-container probes only; stages that need host orchestration stay in this repository.

## Network

Two stages reach the public network, and each only in part: Stage 3's nested half pulls container images into a throwaway container's empty graphroot, and Stage 4's Stage B clones a small public repo (`POWBOX_SMOKE_PUBLIC_REPO`, default `octocat/Hello-World`).
Everything else runs against the already-present local image and the host — the whole Stage 0 tier, Stage 1, Stage 2, Stage 5 and Stage 6 make no outbound request, and neither does Stage 1b unless a set's own probe does.

What an unreachable registry or remote costs is not uniform:

- Stage 3's Alpine pull **aborts** the stage, while its distroless `pause` pull **degrades** to a recorded skip of just the XFAIL reproduction.
- Stage 4 fails if the fixture repo cannot be cloned. Do not read that as "any clone failure aborts": several of Stage B's cases *expect* a failure — a nonexistent repo, an `ssh://` URL to one — and the failure is the assertion, captured and validated rather than propagated. A bogus `--ref` is the deliberate counter-case: it does **not** abort the clone at all, because the default branch is cloned first and only the post-clone checkout of the ref fails, benignly — a warning, and a valid checkout left on the default branch.

## Partial runs, host gates, and skipping

Stages self-skip rather than fail when the host cannot provide what they need, and skips are collected into an end-of-run banner.
That banner mixes two kinds of entry, so read it as "did not run, or did not run in full" rather than as a list of stages you have no coverage from: some entries are whole stages that never ran, others are stages that ran with only a portion self-skipped — Stage 3's nested half is the standing example, and it is listed on every hosted-CI run.
The remedy turns on a *different* axis, so do not read it off that one: what decides it is whether the entry names a skip control, not whether the entry is a whole stage.
An entry naming a skip variable (or, on the PowerShell mirror, a `-Skip*` switch) was skipped on request and comes back when you unset or drop the control it names — whole stage or not, since `POWBOX_SMOKE_SKIP_SELFHOSTED_CLONE` is a requested *within-stage* partial that runs Stage 4's launcher-identity half and skips its clone half.
An entry naming no skip control was decided at runtime by the host or the working tree: there is nothing set to unset, and it comes back only when the host can provide what the stage needs — or, for a Stage 1b entry naming a layer-set directory missing from the working tree, when that directory is there (see [Layer-set probes](#layer-set-probes-stage-1b)).

Five of the six image/host stages are gated by independent environment variables — `POWBOX_SMOKE_SKIP_DB` (Stage 2), `POWBOX_SMOKE_SKIP_PODMAN` (Stage 3), `POWBOX_SMOKE_SKIP_SELFHOSTED` (Stage 4), `POWBOX_SMOKE_SKIP_DIRMOUNT` (Stage 5), and `POWBOX_SMOKE_SKIP_WORKTREE_META` (Stage 6).
Setting all five leaves the Stage 0 tier plus Stage 1 (and Stage 1b for an image built from a layer set) — no host database, no nested engine, no relaunch cycle — though the eight Stage 0 entries and Stage 1 itself still start throwaway containers from the image.
Stage 1 has no skip variable of its own: it is the residue that remains when all five are set, and a missing image makes it fail and abort the run before any later stage executes, so there is nothing to gain from skipping it.
Stage 1b has none either: whether it runs is decided by the image's label and the set's probe file (see [Layer-set probes](#layer-set-probes-stage-1b)).

On a host that cannot expose `/dev/net/tun` (for example the Docker Desktop VM under the default `auto`), Stage 3 still validates the static engine wiring but skips its whole nested half — the nested run, the published-port check **and** the Compose exec-form health check.
Force the full check with `POWBOX_PODMAN=on`, or skip the whole stage with `POWBOX_PODMAN=off` (deprecated alias `POWBOX_FUSE=off`).
A genuinely broken image fails on any host: a missing engine fails Stage 1's `command -v podman` presence probe, and a dropped drop-in still fails Stage 3.

### Not applicable: capability-gated stages

Stage 2 runs only when `pg-dev-up` is on the image's `PATH`, and Stage 3 only when `podman` is; one short `docker run --rm --entrypoint /bin/sh` per stage asks the image's login shell, the `PATH` every probe runs with.
On an image without the tool the stage is **not applicable**: it is listed in a separate block of the banner, as information, and it never makes the run partial — a lean image without Podman has been fully tested.
The capability check comes first, so on such an image the stage is not applicable whatever its skip control says; on an image that has the tool, an explicit skip (`POWBOX_SMOKE_SKIP_DB`/`POWBOX_SMOKE_SKIP_PODMAN`, or `-SkipDb`/`-SkipPodman` on the PowerShell mirror) still records a skip and marks the run partial, exactly as before.
A capability check that answers neither "present" nor "absent" (a docker failure) fails the run rather than reading as not applicable.

Gating alone would let an image that lost a tool pass with its stage reported as not applicable, so absence is made a failure by a **presence probe** wherever the image is supposed to have the tool: in Stage 1's core list for what every image ships (`psql --version`, `pg-dev-up check` and `command -v podman` today), and in a layer set's `smoke-probes.txt` for what the set installs.
While the core list asserts all three, an image without them fails Stage 1 and stops there, so the not-applicable path is reachable end to end only once those probes move into a layer set; until then `scripts/test-smoke-probe-wrapper.sh` covers the gate and the banner against a fake `docker`.

### The banner is not complete

Every **requested** skip reaches the banner, because the umbrella records those itself.
A **runtime** self-skip decided inside a child script has no channel of its own other than the `POWBOX_SMOKE_SKIP_MARKER` mechanism, and marker wiring exists for exactly three children: Stages 3, 5 and 6 — though a skip can still reach the banner without the child's help when the umbrella re-evaluates the same host condition itself, which is how Stage 3's tun-driven nested-half skip is recorded.

Stage 4's child is handed no marker — on either umbrella — so its runtime self-skips are invisible, and a run in which they fired still ends `Smoke test complete (all stages ran)`.
In practice this bites when `POWBOX_SMOKE_PUBLIC_REPO` points at something other than the default: two of Stage B's ref cases assert against Hello-World-specific contents and silently self-skip unless `POWBOX_SMOKE_REF_PATH` and `POWBOX_SMOKE_REF_BRANCH` are supplied too.
So read the banner as complete for a run against the default public repo, or one that supplies both ref overrides, and as silent about those cases otherwise.

Not-applicable stages are printed in their own block, above the skipped-or-partial one, and only skipped entries make the run partial.
A run with not-applicable stages and nothing skipped ends `Smoke test complete (every stage that applies to this image ran)`; a run with neither still ends `Smoke test complete (all stages ran)`.

## CI gating

Two layered workflows cover this from CI, and **both carry the repo's `non-code` label gate** — though only Tier 0 subscribes to `labeled`/`unlabeled` events, so toggling the label re-evaluates Tier 0 at once, while Tier 1 reads its gate only on the next `opened`/`synchronize`/`reopened` event and an already-queued or running Tier 1 is not called off:

- **Tier 0** (`.github/workflows/native-linux-ci.yml`) — static guards plus the auto-discovered native-Linux-hermetic source suites through `scripts/run-pure-shell-tests.sh`. No image or Docker; the suites run in parallel and finish in about a minute on the measured container. Among the static guards, a layer-set contract scan runs `scripts/layers-digest.sh` over every committed set under `docker/layers/` except the user-owned `custom/`, and fails naming the set that breaks the contract or has no `Dockerfile`. It is the only CI check on `full`.
- **Tier 1** (`.github/workflows/native-linux-build.yml`) — builds and smokes two images in two sequential passes, lean first: the lean image (no `.powbox-layers`) and then lean + the committed `browser` layer set. The second pass tests the layer-set mechanism, not every tool install: after each pass's smoke run, both agents' seeded `agent.md.tmpl` are compared byte for byte with the expected source (the core template for lean, the staged `.powbox-staging/agent.md.tmpl` for `browser`, whose notes heading must appear exactly when the staged file differs from the core template), and a further `browser` step runs Stage 1b against the built image with a two-probe file whose second probe fails, asserting that the stage fails, prints `SMOKE PROBE 2 FAILED` and prints the manifest. The maintainer's `full` set is never built in CI; the maintainer builds and smoke-tests it by hand, and a PR that changes only `docker/layers/full/` does not start Tier 1. Each pass asserts the built agent image's `powbox.layers.set` label (none, then `browser`), so a pass that built on the wrong parent fails instead of smoking the same image twice, and each runs the smoke under `POWBOX_SMOKE_REQUIRE_IMAGE=1`, so an absent image is a hard error rather than a run whose image-gated checks self-skip into a false green. That flag reaches only the image-dependent skips: the hosted runner exposes no `/dev/net/tun`, so Stage 3's nested half self-skips there — see "Partial runs, host gates, and skipping" above — and a green Tier 1 is a partial smoke, not a full one. Additionally path-gated to image-affecting paths and to PRs targeting `main`.

See README "Continuous Integration" for the trigger paths and caching.

## The PowerShell mirror

`commands/smoke-test.ps1` runs the same inventory wherever `pwsh` runs, including a native-Linux host, and takes `-SkipDb -SkipPodman -SkipSelfHosted -SkipDirMount -SkipWorktreeMeta` plus `-RequireImage` in place of the environment variables.

Its eight Stage 0 entries match the Bash targets.
Stage 6 mirrors the mountpoint-ownership assertions too (task 053a): both drivers hand each container the same shared inner script — `scripts/smoke-test-worktree-metadata-container-a.bash` (task 053a) and `scripts/smoke-test-worktree-metadata-container-b.bash` (task 053b) — so neither half can drift, while each driver implements the ~40 host-side lines natively.
The PowerShell driver reads both files with an explicit `-Encoding UTF8`, which is required rather than tidy: Windows PowerShell 5.1 decodes a BOM-less file with the system ANSI codepage, so a non-ASCII byte in a shared file (Container B's script has one, an em dash) would otherwise reach `bash -c` mangled from the PowerShell driver and intact from the Bash one — drift reintroduced through the loader rather than through a second copy.
Both drivers also fail closed on an empty shared file, so a truncated checkout cannot hand the container a no-op payload that exits 0 and reads as a pass.
One deliberate, narrower divergence remains: the PowerShell driver runs those ownership assertions only on a native-Linux host and records a counted `Note-Skip` otherwise, because a Windows/macOS bind mount squashes `uid:gid` and every comparison would then pass vacuously — a green that proves nothing is worse than an announced skip.
The gate is documented in `scripts/smoke-test-worktree-metadata.ps1`'s header.

The mirror is not left to host runs alone: Tier 1 (`.github/workflows/native-linux-build.yml`) runs `scripts/smoke-test-worktree-metadata.ps1` in its own step after the Bash umbrella, because `commands/smoke-test.sh` never invokes the PowerShell driver and the hosted runner — native Linux, rootful daemon, unprivileged `runner` invoker — is the only automated configuration where those assertions have teeth.
That step is stricter than the umbrella in two ways: a runtime self-skip fails it (on that runner every skip reason is impossible, so a skip means the coverage stopped running), and it counts the three `ok: mountpoint ownership` lines, so a green proves the assertions were reached rather than merely that the driver started.
Only Stage 6 runs there; the other PowerShell stages would re-check what the Bash umbrella just checked.

Stage 1b, the capability gate and the banner live in `scripts/smoke-test-lib.sh`, which the Bash umbrella sources, and its mirror `scripts/smoke-test-lib.ps1`, which the PowerShell umbrella dot-sources; the two agree case for case and message for message, except that the ASCII-only `.ps1` files use a hyphen wherever the `.sh` files use an em dash (`Stage 1b - layer-set probes (<set>)`).
The PowerShell reader decodes `smoke-probes.txt` from its bytes with a strict UTF-8 decoder, for the same reason the shared Stage 6 scripts are read with `-Encoding UTF8`, and one step stricter: an invalid byte is refused rather than decoded to U+FFFD, since the Bash reader would keep the raw byte and run a different probe.
`scripts/test-smoke-probe-wrapper.sh` pins the parity: the reader's output for CRLF, comment, blank, BOM and non-ASCII fixtures, the gate's decisions, the banner text, and both umbrellas end to end against a fake `docker`.
