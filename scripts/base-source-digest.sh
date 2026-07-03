#!/usr/bin/env bash
# Compute a deterministic digest over the powbox source files baked into the
# BASE image layer (docker/base/Dockerfile plus every file it COPYs, listed in
# scripts/base-source-files.txt).
#
# build-image.sh stamps the result as the powbox.base.recipe.digest label on the
# base image; check-updates.sh recomputes it from the working tree and compares —
# a mismatch means a base-layer source change and marks the base stale, the
# powbox-source analogue of the existing upstream node:24-trixie-slim digest
# trigger. Because build-time and check-time recomputation MUST agree exactly (a
# drift would produce permanent false-positive staleness), both call THIS one
# script, and the .ps1 sibling reproduces a byte-identical digest for the same
# tree. Keep the two in lockstep.
#
# Algorithm (must match base-source-digest.ps1):
#   - read the manifest, dropping blank lines and #-comments, trimming whitespace
#   - sort the paths in byte order (LC_ALL=C) so manifest ordering is irrelevant
#   - for each path emit "<sha256-of-file-bytes>  <path>\n" (two spaces, LF)
#   - the digest is "sha256:" + sha256 of that concatenated buffer
# A missing listed input is a hard error (a silently dropped file would make the
# build/check digests disagree forever), and prints nothing so callers can treat
# an empty result as "undeterminable" and never force a needless rebuild.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${ROOT_DIR}/scripts/base-source-files.txt"

if [ ! -f "$MANIFEST" ]; then
	echo "base-source-digest: manifest not found: $MANIFEST" >&2
	exit 1
fi

# Lowercase hex sha256 of stdin, no filename. Mirrors launch-agent.sh's hashing
# fallbacks so the digest is computable on any host with one of the three tools.
sha256_hex() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | cut -d' ' -f1
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 | sed 's/^.*[ =]//'
	else
		echo "base-source-digest: no sha256 tool (need sha256sum, shasum, or openssl)" >&2
		return 1
	fi
}

# Filter + trim + byte-sort the manifest once, in the main shell, so the read
# loop below is not a pipeline subshell and its `exit 1` on a missing file aborts
# the whole script (a pipe subshell's exit would be swallowed).
manifest_sorted="$(
	grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$MANIFEST" |
		sed 's/^[[:space:]]*//; s/[[:space:]]*$//' |
		LC_ALL=C sort
)"

buffer=""
while IFS= read -r rel; do
	[ -n "$rel" ] || continue
	file="${ROOT_DIR}/${rel}"
	if [ ! -f "$file" ]; then
		echo "base-source-digest: listed input missing: $rel" >&2
		exit 1
	fi
	buffer="${buffer}$(sha256_hex <"$file")  ${rel}"$'\n'
done <<EOF
${manifest_sorted}
EOF

printf 'sha256:%s\n' "$(printf '%s' "$buffer" | sha256_hex)"
