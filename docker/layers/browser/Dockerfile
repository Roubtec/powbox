# The "browser" layer set: a headless browser stack on top of the lean base,
# for document and diagram work such as a Marp deck to PDF, a Mermaid diagram
# to SVG, or an HTML page printed to PDF. Select it by writing `browser` into
# .powbox-layers (see .powbox-layers.example); scripts/build-image.{sh,ps1}
# then bake this file into powbox-agent-layers:latest and build the agent image
# on it. It is a set of its own, not a layer under `full`: a build selects
# exactly one set.
#
# It ships no tools yet; the browser stack moves here from the base later. It
# is also the set Tier 1 CI builds and smokes, so it is what exercises the
# base -> layers -> agent chain there (the maintainer's `full` set is never
# built in CI).
#
# The contract every layer Dockerfile follows (README "Layer sets"):
#   - start with the two lines below, so the build scripts can pass the base,
#     and build the final stage on it (directly or through a stage that is):
#     the build refuses a layer image whose filesystem layers do not start
#     with the base's;
#   - switch to USER root for installs and end with USER node, the user the
#     base ends with and the agent Dockerfile assumes;
#   - give every COPY and ADD a --chmod=<mode>: the build context is this
#     directory alone, and its digest (scripts/layers-digest.{sh,ps1}) covers
#     file contents, not modes, so a mode must come from this file;
#   - bind-mount no build context in a RUN (a --mount= without type= is a
#     bind too): it shows this directory's files with their checkout modes.
#     A bind from=<stage-or-image> and cache, tmpfs, secret and ssh mounts
#     are fine;
#   - keep only regular files in the directory (a symlink or an empty
#     directory is rejected; create those in a RUN);
#   - use no ONBUILD: a trigger runs in the agent build, from the repo-root
#     context, where it could read files the digest does not cover;
#   - set no powbox.* labels: the bake target stamps them;
#   - keep the default backslash escape (no `# escape=` naming another).
ARG BASE_IMAGE=powbox-agent-base:latest
FROM ${BASE_IMAGE}

USER root

USER node
