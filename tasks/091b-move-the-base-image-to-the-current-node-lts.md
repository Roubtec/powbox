# 091b — Move the base image to the current Node.js LTS

**Relates to:** 091 (the pin refresh this was split from, because it changes the runtime of every image and every project). Touches the `FROM` line and `BASE_SOURCE_IMAGE` of `docker/base/Dockerfile`, the `BASE_SOURCE_IMAGE` default in `docker-bake.hcl`, the fallback helper image in `commands/reset-claude-history.{sh,ps1}`, the comments in `commands/check-updates.{sh,ps1}` and `scripts/build-image.{sh,ps1}` that name the base, and README.

## Why this task exists

The lean base is `node:24-trixie-slim`. Node.js 26 is a newer LTS line than 24. The base image's major is a pin like any other, and the maintainer's stance is to update freely, breaking upgrades included.

It is not a plain version bump, though. The base image's Node is the Node every downstream project runs under, its bundled npm comes along with it, and every layer above the base is rebuilt. A project that pins `engines.node` to 24, or depends on a native addon built for it, can break.

## Goal

The lean base builds on the current Node.js LTS. Every place that names the base agrees with it.

## Direction and constraints

- `agent-check-updates` compares the recorded upstream digest with the registry. Check that a base from a new major is reported correctly, and that the "base is stale" logic still holds.
- Historical notes that name `node:24` as the base at some past point (the Podman chapter's migration record, for example) describe the past and stay as they are.
- The global pnpm honors a project's `packageManager` field, and the pnpm shadow wrapper locates pnpm's entry files by layout. Check that both still hold under the new Node and its bundled npm.
- Say in the PR what the bump breaks for projects that pinned `engines.node` to 24.

## Validation

The base is built and smoke-tested by Tier 1 on the PR. Rebuilding every image on the host is the maintainer's step after merge.
