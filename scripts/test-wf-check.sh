#!/usr/bin/env bash

# Hermetic behavior test for docker/shared/wf-check. When an installed
# dev-skills@roubtec marketplace cache is available, its actual relocated wf-*
# sources are checked too; the synthetic cases remain the network-free fixture.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${WF_CHECK:-${ROOT_DIR}/docker/shared/wf-check}"
if [[ ! -x "$HELPER" ]]; then
	echo "test-wf-check: helper is not executable: $HELPER" >&2
	exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wf-check-test-047.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

checks=0
fails=0

ok() {
	checks=$((checks + 1))
	printf '  ok %s\n' "$1"
}

bad() {
	checks=$((checks + 1))
	fails=$((fails + 1))
	printf '  FAIL %s\n%s\n' "$1" "${2:-}" >&2
}

run_ok() {
	local label="$1" file="$2" output
	if output="$($HELPER "$file" 2>&1)"; then
		ok "$label"
	else
		bad "$label" "$output"
	fi
}

run_fail() {
	local label="$1" file="$2" pattern="$3" output
	if output="$($HELPER "$file" 2>&1)"; then
		bad "$label" "unexpected pass: $output"
	elif grep -Fq -- "$pattern" <<<"$output"; then
		ok "$label"
	else
		bad "$label" "expected '$pattern' in: $output"
	fi
}

cat >"$WORK/valid.js" <<'EOF'
// Leading comments are trivia, not the first statement.
export const meta = {
  name: "valid",
  description: `literal template`,
  whenToUse: "tests",
  phases: [
    { title: "One", detail: "detail", model: "sonnet" },
    { title: "Two" },
  ],
  extra: { negative: -4, flags: [true, false, null], pattern: /ok/u },
};

await log("checking");
phase("One");
const values = await parallel([async () => agent("one")]);
return { values, args, budget, workflow, pipeline };
EOF
run_ok "valid literal metadata and every async-body hook pass" "$WORK/valid.js"

cat >"$WORK/top-return.js" <<'EOF'
export const meta = { name: "top-return", description: "return is inside the runtime wrapper" };
return "ok";
EOF
run_ok "top-level return passes" "$WORK/top-return.js"

cat >"$WORK/runtime-phase-filter.js" <<'EOF'
export const meta = {
  name: "phase-filter",
  description: "the installed runtime ignores malformed optional phase entries",
  phases: [null, {}, { title: 4 }, { title: "kept", detail: 9 }],
};
return null;
EOF
run_ok "optional phases follow the installed runtime's filtering behavior" "$WORK/runtime-phase-filter.js"

cat >"$WORK/missing-meta.js" <<'EOF'
return "missing";
EOF
run_fail "missing meta fails" "$WORK/missing-meta.js" "expected 'export'"

cat >"$WORK/meta-not-first.js" <<'EOF'
const NAME = "computed";
export const meta = { name: NAME, description: "not first" };
return null;
EOF
run_fail "meta must be the first statement" "$WORK/meta-not-first.js" "expected 'export'"

cat >"$WORK/computed-value.js" <<'EOF'
export const meta = { name: NAME_CONST, description: "computed value" };
return null;
EOF
run_fail "computed meta value fails with the literal rule" "$WORK/computed-value.js" "non-literal node type in meta"

cat >"$WORK/computed-key.js" <<'EOF'
export const meta = { ["name"]: "computed-key", description: "computed key" };
return null;
EOF
run_fail "computed meta key fails with the literal rule" "$WORK/computed-key.js" "computed keys not allowed in meta"

cat >"$WORK/missing-name.js" <<'EOF'
export const meta = { description: "missing name" };
return null;
EOF
run_fail "required meta.name is enforced" "$WORK/missing-name.js" "meta.name must be a non-empty string"

cat >"$WORK/body-syntax.js" <<'EOF'
export const meta = {
  name: "body-syntax",
  description: "the syntax error below is line mapped",
};

const stillValid = true;
if (stillValid) {
  const broken = ;
}
return null;
EOF
run_fail "body syntax error reports the original source line" "$WORK/body-syntax.js" "$WORK/body-syntax.js:8"

{
	printf 'export const meta = { name: "oversize", description: "limit" };\n/*'
	head -c 524289 /dev/zero | tr '\0' x
	printf '*/\n'
} >"$WORK/oversize.js"
run_fail "runtime source-size limit is enforced" "$WORK/oversize.js" "runtime limit of 524288 characters"

if "$HELPER" --help | grep -Fq "Top-level await and return"; then
	ok "help documents async-wrapper semantics"
else
	bad "help documents async-wrapper semantics"
fi

marketplace_root="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}/plugins/cache/roubtec/dev-skills"
marketplace_count=0
while IFS= read -r -d '' workflow; do
	marketplace_count=$((marketplace_count + 1))
	run_ok "relocated marketplace fixture $(basename "$workflow") passes" "$workflow"
done < <(find "$marketplace_root" -path '*/workflows/*.js' -type f -print0 2>/dev/null | sort -zu)
if [[ "$marketplace_count" -eq 0 ]]; then
	printf '  skip no installed dev-skills@roubtec workflow cache; synthetic fixture still ran\n'
fi

if [[ "$fails" -ne 0 ]]; then
	echo "wf-check unit test: $fails/$checks checks FAILED." >&2
	exit 1
fi
echo "wf-check unit test passed ($checks checks; $marketplace_count marketplace fixtures)."
