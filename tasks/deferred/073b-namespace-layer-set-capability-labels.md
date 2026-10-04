# 073b — Give layer-set capability labels their own namespace

## Why this task is deferred

The risk it addresses is small. Only a power user writing a `custom` set can hit it, and only by declaring a `powbox.*` label that collides with a reserved one by accident. Labels a custom set needs for its own purposes are free to use any other prefix. The maintainer chose to keep the status quo when task 073 landed (2026-10-04): no enforcement, and no rename. Move this to `tasks/` if label collisions prove contentious, for example when a collision is reported or someone asks for the rule to be enforced.

## Why this task exists

The layer-set contract (the header of each `docker/layers/<set>/Dockerfile` and README "Layer sets") says a set sets no `powbox.*` labels. The bake target stamps `powbox.layers.*` and `powbox.commit.layers`, the base stamps its own (such as `powbox.base.selfhosted`, which the launchers read), and the agent image inherits them all. A set that declares one of those labels can mask or fake it.

Task 073 added one deliberate exception: `full`'s Podman block declares `LABEL powbox.podman="1"`, which gates the launchers' image-store writer and which smoke Stage 3 checks against the `podman` binary. The contract now allows "a capability label for a tool the set installs, declared in that tool's block". That wording is a judgement call rather than a pattern, so no script can check it, and nothing enforces the rule today.

## Scope

**In scope:**

1. Give capability labels a reserved sub-namespace, for example `powbox.cap.<tool>`, and rename `powbox.podman` to match.
2. Reword the contract to "no `powbox.*` labels except `powbox.cap.*`" in both set Dockerfile headers and README "Layer sets".
3. Optionally enforce it: have the Tier 0 layer-set contract scan (`scripts/layers-digest.{sh,ps1}`) fail a set that declares a `powbox.*` label outside `powbox.cap.*`.

**Out of scope:**

- Labels outside the `powbox.` prefix, which custom sets may use freely.
- Changing what the Podman gate decides.

## Context and references

- `docker/layers/full/Dockerfile` (the Podman block's `LABEL powbox.podman` and the contract header) and `docker/layers/browser/Dockerfile` (the contract header).
- Every reader of `powbox.podman` must follow the rename. Grep for it: at the time of writing that is `scripts/launch-agent.sh` (`powbox_image_store_writer_wanted`), `scripts/launch-agent.ps1` (`Test-PowboxImageStoreWriterWanted`), `scripts/smoke-test-lib.{sh,ps1}` (the Stage 3 label check) and its comments in `commands/smoke-test.{sh,ps1}` and `docker/layers/full/smoke-probes.txt`, `scripts/test-image-store-writer-gate.sh`, `scripts/test-smoke-probe-wrapper.sh`, README and `docs/`. Match the name exactly: `powbox.podman-devices` is a different, container-level label and is not part of this.
- An image built before the rename carries only the old label, so a launcher reading only the new name starts no writer until the image is rebuilt. Either accept that (the base recipe digest change already marks the image stale) or read both names for a transition period.

## Acceptance criteria

- No file outside `tasks/` reads or declares `powbox.podman` under its old name, unless a transition period was chosen and is documented.
- The contract text names the `powbox.cap.*` exception as a pattern.
- If enforcement was added, Tier 0 fails a set declaring, for example, `LABEL powbox.base.selfhosted=""`, and passes the committed sets.
