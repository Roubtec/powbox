# shellcheck shell=bash
# Image-inspection decisions for scripts/build-image.sh, sourced by it and by
# scripts/test-layer-sets.sh. They only read local images through
# `docker image inspect`, so the test drives them against a fake `docker`.
# scripts/build-image-lib.ps1 is the PowerShell twin; keep the two in lockstep,
# since an image built by one driver is judged by the other on the next build.

POWBOX_BASE_TAG="powbox-agent-base:latest"
POWBOX_LAYERS_TAG="powbox-agent-layers:latest"
POWBOX_AGENT_TAG="powbox-agent:latest"

# Echo a label value off a local image, or empty when the image/label is absent.
image_label() {
	local v
	v="$(docker image inspect "$1" --format "{{ index .Config.Labels \"$2\" }}" 2>/dev/null)" || return 0
	[ "$v" = "<no value>" ] && v=""
	printf '%s' "$v"
}

# Image ID of a local image, or empty when it is absent.
image_id() {
	docker image inspect "$1" --format '{{.Id}}' 2>/dev/null || true
}

_powbox_sha256_hex() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 | cut -d' ' -f1
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 | sed 's/^.*[ =]//'
	else
		return 1
	fi
}

# Signature of an image as a parent of the agent's Codex install layer:
# "sha256:" + sha256 of one inspect line (plus LF) holding the layer chain and
# the inherited config a RUN executes under (environment, SHELL, WORKDIR, USER),
# in that fixed order. It approximates BuildKit's cache key for that layer's
# parent, so it deliberately leaves out .Config.Labels and the image ID: a
# label-only change to the parent (a base baked at a new commit) keeps the Codex
# layer cached and must keep its commit too. Empty when the image is absent or
# no sha256 tool exists.
parent_signature() {
	local raw hex
	raw="$(docker image inspect "$1" --format '{{json .RootFS.Layers}} {{json .Config.Env}} {{json .Config.Shell}} {{json .Config.WorkingDir}} {{json .Config.User}}' 2>/dev/null)" || return 0
	[ -n "$raw" ] || return 0
	hex="$(printf '%s\n' "$raw" | _powbox_sha256_hex)" || return 0
	[ -n "$hex" ] && printf 'sha256:%s\n' "$hex"
	return 0
}

# The JSON list of an image's filesystem layer digests, or empty when absent.
image_rootfs() {
	docker image inspect "$1" --format '{{json .RootFS.Layers}}' 2>/dev/null || true
}

# Print why powbox-agent-layers:latest is not built on the
# powbox-agent-base:latest that exists now, or nothing when it is: the base's
# filesystem layers must open the layer-set image's. The bake stamps
# powbox.layers.base.id with the base it passes in, whatever image the set's
# final stage actually starts from, so this is what proves the chain; the
# Dockerfile scan in scripts/layers-digest.sh only catches the plain mistake
# early.
layers_base_mismatch() {
	local base_layers layers
	base_layers="$(image_rootfs "$POWBOX_BASE_TAG")"
	layers="$(image_rootfs "$POWBOX_LAYERS_TAG")"
	if [ -z "$base_layers" ] || [ -z "$layers" ]; then
		echo "the filesystem layers of $POWBOX_LAYERS_TAG and $POWBOX_BASE_TAG could not be read"
		return 0
	fi
	case "$layers" in
	"$base_layers" | "${base_layers%]},"*) ;;
	*) echo "$POWBOX_LAYERS_TAG is not built on $POWBOX_BASE_TAG: its filesystem layers do not start with the base's" ;;
	esac
}

# Usage: layers_stale_reason <set> <digest>
# Print why powbox-agent-layers:latest must be baked for the selected set, or
# nothing when it is current: present, labelled with this set and this digest,
# and built FROM the powbox-agent-base:latest that exists now. Call it after the
# run's base step, so a base rebuilt earlier in the same run is the one compared.
# The base is compared by image ID, not by layer chain, so a base change that
# alters only its config (an ENV line, a label) still reaches the agent; the
# layer chain is checked as well, by layers_base_mismatch. An empty digest
# (undeterminable) never counts as current.
layers_stale_reason() {
	local set="$1" digest="$2" baked base_id
	if ! docker image inspect "$POWBOX_LAYERS_TAG" >/dev/null 2>&1; then
		echo "$POWBOX_LAYERS_TAG does not exist"
		return 0
	fi
	baked="$(image_label "$POWBOX_LAYERS_TAG" powbox.layers.set)"
	if [ "$baked" != "$set" ]; then
		echo "$POWBOX_LAYERS_TAG was built from layer set '${baked:-none}', not '${set}'"
		return 0
	fi
	baked="$(image_label "$POWBOX_LAYERS_TAG" powbox.layers.digest)"
	if [ -z "$digest" ]; then
		echo "the digest of layer set '${set}' could not be computed"
		return 0
	fi
	if [ "$baked" != "$digest" ]; then
		echo "layer set '${set}' changed since $POWBOX_LAYERS_TAG was built"
		return 0
	fi
	base_id="$(image_id "$POWBOX_BASE_TAG")"
	baked="$(image_label "$POWBOX_LAYERS_TAG" powbox.layers.base.id)"
	if [ -z "$base_id" ] || [ "$baked" != "$base_id" ]; then
		echo "$POWBOX_LAYERS_TAG was built on a different $POWBOX_BASE_TAG"
		return 0
	fi
	layers_base_mismatch
}

# Usage: resolve_codex_commit <head-commit> <codex-version> <parent-signature> <no-cache:true|false>
# Print the commit to record for the agent's Codex install layer. Stamping it
# inside that layer would bust its cache on every commit, so it is predicted
# here: <head-commit> when the layer will be rebuilt, otherwise the commit the
# previous powbox-agent:latest recorded, carried forward. The layer is taken as
# reused when the agent's parent has the signature the previous agent recorded
# (powbox.parent.signature) and CODEX_VERSION is the one it was built with:
# that is the layer's cache key as far as the host can see it. Call it once the
# parent is in place, after this run's base and layer-set steps; a base or
# layer-set image rebuilt with identical layers and config keeps the commit.
resolve_codex_commit() {
	local head="$1" codex_version="$2" signature="$3" no_cache="$4"
	local prev_signature prev_ver prev_commit
	if [ "$no_cache" = true ] || ! docker image inspect "$POWBOX_AGENT_TAG" >/dev/null 2>&1; then
		printf '%s\n' "$head"
		return 0
	fi
	prev_signature="$(image_label "$POWBOX_AGENT_TAG" powbox.parent.signature)"
	if [ -z "$signature" ] || [ "$signature" != "$prev_signature" ]; then
		printf '%s\n' "$head"
		return 0
	fi
	prev_ver="$(image_label "$POWBOX_AGENT_TAG" powbox.codex.version)"
	prev_commit="$(image_label "$POWBOX_AGENT_TAG" powbox.commit.codex)"
	# An image built before provenance labelling has no commit to carry, and the
	# commit that built the reused layer is unknowable, so record "unknown"
	# rather than misattributing this build's HEAD to it.
	if [ "$prev_ver" = "$codex_version" ]; then
		printf '%s\n' "${prev_commit:-unknown}"
	else
		printf '%s\n' "$head"
	fi
}
