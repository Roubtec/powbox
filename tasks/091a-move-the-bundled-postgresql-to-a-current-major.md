# 091a — Move the bundled PostgreSQL to a current major

**Relates to:** 091 (the pin refresh this was split from, because it grows beyond a version bump), 088 and 089 (they change `pg-dev-up` too). Touches the PostgreSQL block of `docker/layers/full/Dockerfile`, `docker/layers/full/pg-dev-up`, the PostgreSQL image the shared Podman store pre-caches (`docker/layers/full/seed-image-store.sh`), `docker/layers/full/agent-notes.md`, `docker/layers/full/smoke-probes.txt`, `scripts/test-pg-dev-up-scoped.sh`, `docs/architecture.md` "Bundled PostgreSQL", the `full` set's description in `.powbox-layers.example`, and the README and Podman docs that name the major.

## Why this task exists

The `full` layer set bakes PostgreSQL 16 from the PGDG repository, pinned to the major on the grounds that it matches what projects pin. PGDG publishes newer majors for trixie, so the pin trails what new projects start on. The maintainer's stance on pins is to update freely, breaking upgrades included, and to fix up projects and guidance afterwards.

Unlike the other pins task 091 moved, this one is not a version literal. The major is part of package names, of the server binary paths `pg-dev-up` resolves, of the pre-cached container image, and of the agent-facing text. A data directory created by one major cannot be started by another.

## Goal

The `full` image bakes the newest PostgreSQL major that PGDG ships for the base distribution, unless a stated reason holds it back. `pg-dev-up`, the pre-cached image, the smoke probes and every agent-facing mention agree on that major. An agent whose container still holds a cluster made by the old major gets a clear message or a recreated cluster, not a cryptic startup failure.

## Direction and constraints

- Decide whether to name the major in one place and derive the rest, or to keep literal copies and say beside each one which set it belongs to. Either way, the next major bump should be a small edit.
- `pg-dev-up` clusters are throwaway by design, so recreating a cluster made by the old major is acceptable. Losing data silently is not acceptable when the user asked for it to persist. Coordinate with 088's durability modes.
- The pre-cached `postgres` image in the shared Podman store is a separate choice from the baked server. Projects' compose files name their own tag, so decide whether the cached tag follows the baked major or the tag projects most commonly use, and write down which.
- Say in the PR what the bump breaks for projects that assumed 16 (client/server version skew, extensions, `pg_dump` format), so they can be fixed up afterwards.

## Validation

`full` changes need the maintainer's host build. The scoped `pg-dev-up` suite runs only against a `full` image, through the host smoke run.
