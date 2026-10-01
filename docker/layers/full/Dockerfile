# The "full" layer set: the maintainer's bundle of toolchains on top of the lean
# base. Select it by writing `full` into .powbox-layers (see
# .powbox-layers.example); scripts/build-image.{sh,ps1} then bake this file into
# powbox-agent-layers:latest and build the agent image on it.
#
# It installs nothing yet; it exists so the base -> layers -> agent chain is
# built and exercised before any tool moves here.
#
# The contract every layer Dockerfile follows (README "Layer sets"):
#   - start with the two lines below, so the build scripts can pass the base,
#     and build the final stage on it (directly or through a stage that is):
#     the bake labels this image with the base's ID as proof of the chain;
#   - switch to USER root for installs and end with USER node, the user the
#     base ends with and the agent Dockerfile assumes;
#   - give every COPY and ADD a --chmod=<mode>: the build context is this
#     directory alone, and its digest (scripts/layers-digest.{sh,ps1}) covers
#     file contents, not modes, so a mode must come from this file;
#   - keep only regular files in the directory (a symlink is rejected; create
#     links in a RUN);
#   - set no powbox.* labels: the bake target stamps them;
#   - keep the default backslash escape (no `# escape=` naming another).
ARG BASE_IMAGE=powbox-agent-base:latest
FROM ${BASE_IMAGE}

USER root

USER node
