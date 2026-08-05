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

cat >"$WORK/hook-shadowing.js" <<'EOF'
export const meta = { name: "hook-shadowing", description: "runtime hooks are globals, not wrapper parameters" };
const agent = 1;
const parallel = 2;
const pipeline = 3;
const log = 4;
const phase = 5;
const args = 6;
const budget = 7;
const workflow = 8;
return agent + parallel + pipeline + log + phase + args + budget + workflow;
EOF
run_ok "local bindings may shadow runtime hook globals" "$WORK/hook-shadowing.js"

cat >"$WORK/reserved-identifier.js" <<'EOF'
export const meta = { name: "reserved-identifier", description: "compiler scratch identifiers are reserved" };
const __wRg$collision = 1;
return __wRg$collision;
EOF
run_fail "compiler-reserved identifier prefix fails" "$WORK/reserved-identifier.js" "Identifier '__wRg\$collision' is reserved."

cat >"$WORK/await-using.js" <<'EOF'
export const meta = { name: "await-using", description: "compiler cannot transform await using" };
await using value = resource;
return value;
EOF
run_fail "await using declarations fail the compiler pass" "$WORK/await-using.js" "'await using' declarations are not supported"

cat >"$WORK/reserved-text.js" <<'EOF'
export const meta = { name: "reserved-text", description: "reserved-prefix text is not an identifier" };
// __wRg$insideAComment is harmless.
const marker = "__wRg$insideAString";
return marker;
EOF
run_ok "reserved prefix in strings and comments is not rejected" "$WORK/reserved-text.js"

cat >"$WORK/escaped-property-identifiers.js" <<'EOF'
export const meta = {
  n\u0061me: "escaped-property-identifiers",
  descr\u0069ption: "Acorn decodes valid escaped identifier keys",
};
return null;
EOF
run_ok "valid escaped metadata property identifiers pass" "$WORK/escaped-property-identifiers.js"

cat >"$WORK/uninterpreted-phases.js" <<'EOF'
export const meta = {
  name: "phase-metadata",
  description: "optional literal metadata is accepted without interpretation",
  phases: [null, {}, { title: 4 }, { title: "kept", detail: 9 }],
};
return null;
EOF
run_ok "optional literal phase metadata is accepted without interpretation" "$WORK/uninterpreted-phases.js"

cat >"$WORK/missing-meta.js" <<'EOF'
return "missing";
EOF
run_fail "missing meta fails" "$WORK/missing-meta.js" "must be the FIRST statement"

cat >"$WORK/meta-not-first.js" <<'EOF'
const NAME = "computed";
export const meta = { name: NAME, description: "not first" };
return null;
EOF
run_fail "meta must be the first statement" "$WORK/meta-not-first.js" "must be the FIRST statement"

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

cat >"$WORK/meta-binary-expression.js" <<'EOF'
export const meta = { name: "binary", description: "initializer is not an object" } + 1;
return null;
EOF
run_fail "non-object meta initializer follows the runtime AST check" "$WORK/meta-binary-expression.js" "must be the FIRST statement"

cat >"$WORK/strict-octal-escape.js" <<'EOF'
export const meta = { name: "octal", description: "\1" };
return null;
EOF
run_fail "module-strict-invalid octal string escapes fail" "$WORK/strict-octal-escape.js" "Octal literal in strict mode"

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
run_fail "runtime ASCII source-size limit is enforced" "$WORK/oversize.js" "runtime limit of 524288 bytes"

{
	printf 'export const meta = { name: "oversize-multibyte", description: "byte limit" };\n/*'
	node -e 'process.stdout.write("é".repeat(262145))'
	printf '*/\n'
} >"$WORK/oversize-multibyte.js"
run_fail "runtime source-size limit counts UTF-8 bytes" "$WORK/oversize-multibyte.js" "runtime limit of 524288 bytes"

node - "$WORK/max-invalid-utf8.js" <<'NODE'
const fs = require("fs");
const target = process.argv[2];
const limit = 524288;
const prefix = Buffer.from('export const meta = { name: "max-invalid-utf8", description: "raw byte accounting" };\n/*');
const suffix = Buffer.from('*/\nreturn null;\n');
const source = Buffer.alloc(limit, 0xff);
prefix.copy(source);
suffix.copy(source, source.byteLength - suffix.byteLength);
fs.writeFileSync(target, source);
NODE
run_ok "runtime accepts exactly-limit raw bytes even when decoded UTF-8 re-encodes larger" "$WORK/max-invalid-utf8.js"

node - "$WORK/oversize-invalid-utf8.js" <<'NODE'
const fs = require("fs");
const target = process.argv[2];
const source = Buffer.alloc(524289, 0xff);
Buffer.from('export const meta = { name: "oversize-invalid-utf8", description: "raw byte accounting" };\n/*').copy(source);
fs.writeFileSync(target, source);
NODE
run_fail "runtime rejects limit-plus-one invalid UTF-8 raw byte" "$WORK/oversize-invalid-utf8.js" "runtime limit of 524288 bytes"

mkfifo "$WORK/unbounded-source.js"
yes '/* open-ended workflow source */' >"$WORK/unbounded-source.js" 2>/dev/null &
writer_pid=$!
if output="$(timeout 5 "$HELPER" "$WORK/unbounded-source.js" 2>&1)"; then
	bad "source reads stop after limit-plus-one bytes" "unexpected pass: $output"
else
	status=$?
	if [[ "$status" -eq 124 ]]; then
		bad "source reads stop after limit-plus-one bytes" "helper timed out while reading an open-ended stream"
	elif grep -Fq -- "runtime limit of 524288 bytes" <<<"$output"; then
		ok "source reads stop after limit-plus-one bytes"
	else
		bad "source reads stop after limit-plus-one bytes" "expected size-limit failure in: $output"
	fi
fi
kill "$writer_pid" 2>/dev/null || true
wait "$writer_pid" 2>/dev/null || true

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
