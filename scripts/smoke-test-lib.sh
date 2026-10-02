# shellcheck shell=bash
# Helpers sourced by commands/smoke-test.sh: the layer-set probe stage
# (Stage 1b), the capability gate that decides whether Stages 2 and 3 apply to
# the image, and the end-of-run banner. scripts/smoke-test-lib.ps1 is the
# PowerShell mirror and must agree with this file case for case, message for
# message (a hyphen where this file has an em dash, as in the umbrellas).
#
# They live here rather than inline so scripts/test-smoke-probe-wrapper.sh can
# drive them against a fake `docker`: while Stage 1's core list still asserts
# pg-dev-up and podman, an image without them stops at Stage 1, so the
# not-applicable paths are unreachable end to end and only a fake can cover
# them.
#
# The callers own two arrays these functions append to: `skipped` (whole or
# partial stages that did not run, which make the run PARTIAL) and
# `not_applicable` (stages the image has no tool for, which do not).

# The set-name rule scripts/layers-select.sh enforces on .powbox-layers. The
# label comes from the image, not from the selector, so it is checked again
# before it is used to build a path into the working tree.
SMOKE_LAYER_SET_RE='^[a-z0-9][a-z0-9._-]*$'

# smoke_image_label <image> <label>: print the label's value, empty when the
# image does not carry it. Returns 1 when the image cannot be inspected, so an
# unreadable image is never mistaken for an unlabelled (lean) one. The label
# name is a Go raw string (`...`) so the template matches the .ps1's byte for
# byte; the .ps1 cannot use "..." (see Get-SmokeImageLabel there).
smoke_image_label() {
	local v
	[[ $2 =~ ^[A-Za-z0-9._-]+$ ]] || return 1
	v="$(docker image inspect "$1" --format "{{ index .Config.Labels \`$2\` }}" 2>/dev/null)" || return 1
	[ "$v" = "<no value>" ] && v=""
	printf '%s' "$v"
}

# smoke_read_probe_file <file>: load the probes of a layer set's
# smoke-probes.txt into the global array SMOKE_PROBES, in file order.
#
# One probe per line, split on LF only. A trailing CR is stripped; a leading
# UTF-8 BOM is dropped. Blank lines (spaces and tabs only) and lines whose first
# non-space, non-tab character is `#` are ignored. Nothing else is interpreted:
# every other line reaches scripts/smoke-test-image.sh byte for byte, so the
# driver's own checks (empty, multi-line, trailing line continuation) still
# apply to it. Returns 1, with a message, for a file that is not valid UTF-8 or
# holds a NUL byte: the .ps1 mirror decodes strictly and keeps NULs while `read`
# drops them, so either would let the two drivers run different probes.
smoke_read_probe_file() {
	local file="$1" line first=true ws=$' \t' trimmed
	SMOKE_PROBES=()
	if ! command -v iconv >/dev/null 2>&1; then
		echo "ERROR: no iconv tool to check that $file is valid UTF-8." >&2
		return 1
	fi
	# iconv checks the structure; the grep covers what some iconv builds still
	# pass (code points above U+10FFFF and encoded surrogates), as in
	# scripts/layers-digest.sh.
	if ! iconv -f UTF-8 -t UTF-8 <"$file" >/dev/null 2>&1 ||
		LC_ALL=C grep -q -a -e $'[\xf5-\xfd]' -e $'\xf4[\x90-\xbf]' -e $'\xed[\xa0-\xbf]' "$file"; then
		echo "ERROR: $file is not valid UTF-8." >&2
		return 1
	fi
	# A tr or cmp that fails reads as a NUL, so the check fails closed.
	# shellcheck disable=SC2094 # both ends only read the file
	if ! tr -d '\000' <"$file" | cmp -s - "$file"; then
		echo "ERROR: $file contains a NUL byte." >&2
		return 1
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		if $first; then
			line="${line#$'\xef\xbb\xbf'}"
			first=false
		fi
		line="${line%$'\r'}"
		trimmed="${line#"${line%%[!"$ws"]*}"}"
		case "$trimmed" in
		"" | "#"*) continue ;;
		esac
		SMOKE_PROBES+=("$line")
	done <"$file"
	return 0
}

# smoke_image_has <image> <tool>: 0 when <tool> is on the image's login-shell
# PATH (the PATH every probe runs with), 1 when it is not, 2 when the check
# gave no answer. The container prints an explicit word rather than relying on
# `command -v`'s status, so a docker failure cannot read as "absent" and turn a
# broken run into a not-applicable stage. <tool> is a plain token, passed as a
# positional argument and left unquoted in the script so the text carries no
# double quote for the .ps1 mirror's native-argument quoting to mangle.
smoke_image_has() {
	local out
	case "$2" in
	"" | *[!A-Za-z0-9._-]*) return 2 ;;
	esac
	# shellcheck disable=SC2016 # $1 expands in the container shell
	out="$(docker run --rm --entrypoint /bin/sh "$1" -lc 'if command -v $1 >/dev/null 2>&1; then echo present; else echo absent; fi' smoke-gate "$2" 2>/dev/null)" || return 2
	case "${out##*$'\n'}" in
	present) return 0 ;;
	absent) return 1 ;;
	*) return 2 ;;
	esac
}

# smoke_gate <image> <tool> <skip-request>: print `na` when the image has no
# <tool>, otherwise `skip` when <skip-request> is non-empty and `run` when it
# is empty. The capability check comes first, so an explicit skip on an image
# without the tool is still not applicable rather than a skip. Returns 1, with a
# message, when the check cannot tell.
smoke_gate() {
	local rc=0
	smoke_image_has "$1" "$2" || rc=$?
	case "$rc" in
	0)
		if [ -n "$3" ]; then
			echo skip
		else
			echo run
		fi
		;;
	1) echo na ;;
	*)
		echo "ERROR: could not tell whether image '$1' has $2 on its PATH: the capability check did not answer present or absent." >&2
		return 1
		;;
	esac
}

# smoke_layer_stage <image> <repo-root>: Stage 1b. Reads the layer set the
# IMAGE was built from (its powbox.layers.set label, not .powbox-layers: the
# smoke test describes the image it was given) and runs
# docker/layers/<set>/smoke-probes.txt from the working tree through
# scripts/smoke-test-image.sh. Returns 1 when the run must fail; appends to
# `skipped` when the stage cannot run. docs/smoke-tests.md ("Layer-set probes")
# lists the cases.
smoke_layer_stage() {
	local image="$1" root="$2" layer_set rel dir file baked_digest tree_digest rc
	if ! layer_set="$(smoke_image_label "$image" powbox.layers.set)"; then
		echo "ERROR: could not read the labels of image '$image' to find its layer set." >&2
		return 1
	fi
	if [ -z "$layer_set" ]; then
		echo "Stage 1b does not apply: image '$image' carries no powbox.layers.set label (a lean image)."
		return 0
	fi
	if ! [[ "$layer_set" =~ $SMOKE_LAYER_SET_RE ]]; then
		echo "ERROR: image '$image' names an invalid layer set '$layer_set' in its powbox.layers.set label (must match ^[a-z0-9][a-z0-9._-]*\$)." >&2
		return 1
	fi
	rel="docker/layers/$layer_set"
	dir="$root/$rel"
	file="$dir/smoke-probes.txt"
	# `full` is the committed set: its probe file is what makes a lost tool a
	# failure, so neither a missing directory nor a missing file may soften into
	# a note or a skip.
	if [ ! -d "$dir" ]; then
		if [ "$layer_set" = full ]; then
			echo "ERROR: image '$image' was built from the 'full' layer set, but $rel/ is missing from this working tree; its smoke-probes.txt is what fails a full image that lost a tool." >&2
			return 1
		fi
		if [ -n "${POWBOX_SMOKE_REQUIRE_IMAGE:-}" ]; then
			echo "ERROR: image '$image' was built from layer set '$layer_set', but $rel/ is not in this working tree, and POWBOX_SMOKE_REQUIRE_IMAGE is set - refusing to skip its probes." >&2
			return 1
		fi
		echo "WARNING: image '$image' was built from layer set '$layer_set', but $rel/ is not in this working tree; skipping its probes."
		skipped+=("Stage 1b: layer-set probes for set $layer_set ($rel/ is not in this working tree)")
		return 0
	fi
	if [ ! -e "$file" ] && [ ! -L "$file" ]; then
		if [ "$layer_set" = full ]; then
			echo "ERROR: image '$image' was built from the 'full' layer set, but $rel/smoke-probes.txt is missing from this working tree; it is what fails a full image that lost a tool." >&2
			return 1
		fi
		echo "Note: layer set '$layer_set' ships no $rel/smoke-probes.txt; Stage 1b has nothing to run."
		return 0
	fi
	if [ ! -f "$file" ] || [ -L "$file" ]; then
		echo "ERROR: $rel/smoke-probes.txt is not a regular file." >&2
		return 1
	fi
	smoke_read_probe_file "$file" || return 1
	if [ "${#SMOKE_PROBES[@]}" -eq 0 ]; then
		echo "Note: $rel/smoke-probes.txt holds no probe line; Stage 1b has nothing to run."
		return 0
	fi
	baked_digest="$(smoke_image_label "$image" powbox.layers.digest)" || baked_digest=""
	rc=0
	tree_digest="$("$root/scripts/layers-digest.sh" "$dir")" || rc=$?
	if [ "$rc" -ne 0 ]; then
		echo "WARNING: could not compute the digest of $rel/ (layers-digest exit $rc), so whether image '$image' is stale relative to these probes is unknown. Running them anyway."
	elif [ "$tree_digest" != "$baked_digest" ]; then
		echo "WARNING: image '$image' was built from $rel/ at ${baked_digest:-<no digest label>}, but the working tree is at $tree_digest: the image is stale relative to these probes. Running them anyway; rebuild it if a probe fails for that reason."
	fi
	echo "Running Stage 1b — layer-set probes ($layer_set): ${#SMOKE_PROBES[@]} probe(s) from $rel/smoke-probes.txt ..."
	"$root/scripts/smoke-test-image.sh" "$image" "${SMOKE_PROBES[@]}" || return 1
}

# smoke_print_banner: the end-of-run summary from `skipped` and
# `not_applicable`.
#
# Entries reach the skipped list from two different places - whole stages that
# never ran, and stages that ran with only a portion self-skipped - so nothing
# here may assert that a listed stage produced no coverage, or prescribe a
# variable as the remedy for a host-decided partial that no variable governs.
# A not-applicable stage is neither: the image has no tool for it to test, so
# it is reported as information and never makes the run partial.
# shellcheck disable=SC2154 # both arrays are the caller's, see the header
smoke_print_banner() {
	local s
	if [ "${#not_applicable[@]}" -gt 0 ]; then
		echo
		echo "Not applicable to this image - it does not ship the tool these"
		echo "stages test, so they did not run and the run is not partial:"
		for s in "${not_applicable[@]}"; do
			echo "  - $s"
		done
	fi
	if [ "${#skipped[@]}" -gt 0 ]; then
		echo
		echo "============== SMOKE TEST: SKIPPED OR PARTIAL =============="
		for s in "${skipped[@]}"; do
			echo "  - $s"
		done
		echo "This was a PARTIAL smoke test — each entry above either did not"
		echo "run at all, or ran only in part."
		echo "Entries naming an environment variable were skipped on request:"
		echo "unset it to run them, and set POWBOX_SMOKE_REQUIRE_IMAGE=1 to also"
		echo "fail on a missing image. The rest were decided by the host at"
		echo "runtime — nothing was set to skip them, and unsetting a variable"
		echo "will not recover them: hosted CI has no /dev/net/tun, so Stage 3's"
		echo "nested half self-skips there. See docs/smoke-tests.md."
		echo "==========================================================="
	elif [ "${#not_applicable[@]}" -gt 0 ]; then
		echo "Smoke test complete (every stage that applies to this image ran)."
	else
		echo "Smoke test complete (all stages ran)."
	fi
}
