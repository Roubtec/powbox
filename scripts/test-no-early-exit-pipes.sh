#!/usr/bin/env bash
# Guard: no shell suite feeds a pipe into an early-exiting consumer (task 083).
#
# Every scripts/test-*.sh suite runs under `set -o pipefail`. There, a check like
# `printf '%s' "$text" | grep -q needle` fails at random: `grep -q` exits on its
# first match and closes the pipe, a producer still writing dies of SIGPIPE, and
# the pipeline reports failure although the needle was there. A negated check
# inverts this and passes when it should not. Every early-exiting consumer does
# the same (`grep -q/-m/-l`, `head`, `read`, `cmp`, `awk … exit`, `sed … q`),
# whatever the producer is, and whatever the size of its output: a small write
# only makes the race rarer.
#
# How to comply, instead of piping into such a consumer:
#   * a fixed string: match in-process, `[[ $text == *"$needle"* ]]`;
#   * a regex or anchored-line check: keep grep but feed it without a pipe,
#     `grep -q '^line$' <<<"$text"`, or `grep -m1 … "$file"` on the file itself
#     (`^…$` is per-line in grep but whole-string in `[[ =~ ]]`, so do not swap
#     one for the other mechanically);
#   * the first line of a command's output: capture it, then `${out%%$'\n'*}`;
#   * a producer whose exit status mattered: capture it with `out="$(cmd)" &&`
#     before matching, so its failure still fails the check.
#
# Escape hatch: a pipeline that is itself the payload under test (a smoke probe
# string, a fixture's text) is not an assertion of the suite that holds it. Mark
# it with `# early-exit-pipe-ok: <reason>`, either trailing on its line (any
# physical line of a continued pipeline) or as the comment line directly above
# it, which exempts that one logical line only. The reason is required.
#
# The scan is a line-local heuristic, not a shell parser: it joins lines that
# end in `|` or `\`, skips comment lines, and reads `||` as no pipe. It cannot
# see a consumer's `exit`/`q` on a later line of a multi-line quoted program, and
# text inside a string can trip it; the escape covers the latter. It also misses
# a consumer behind a subshell or option-taking wrapper (`( read x )`,
# `sudo -u u grep -q`), a loop that `break`s out of `while read`, a sed quitting
# with GNU `Q`, and a consumer whose arguments hold a lone `|` ahead of the part
# that quits (an awk `exit`, a sed `q`, a grep `-q`; for grep also `;`, `&` or
# `)`, in a pattern or any other argument). This suite is excluded from its own
# scan, because its fixtures are exactly the shape.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SELF="${BASH_SOURCE[0]##*/}"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/powbox-early-exit-pipes.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

failures=0
checks=0
ok() {
	checks=$((checks + 1))
	printf '  ok    %s\n' "$1"
}
ko() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  FAIL  %s\n' "$1"
	[ -z "${2:-}" ] || printf '%s\n' "$2" | sed 's/^/        /'
}

# scan <file>... — print `<file>:<line>: <text>` for every offending pipeline.
scan() {
	awk '
	function consumer_re(lead) {
		lead = "\\|&?[[:space:]]*(\\{[[:space:]]+)?(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|command|env|sudo)[[:space:]]+)*"
		return lead "(" \
			"(grep|egrep|fgrep)[[:space:]]([^|;&)]*[[:space:]])?(-[A-Za-z]*[qlLm]|--(quiet|silent|max-count|files-with-matches|files-without-match))" \
			"|head([[:space:]]|[)\"]|$)" \
			"|read([[:space:]]|$)" \
			"|awk[[:space:]][^|]*(^|[^A-Za-z0-9_])exit([^A-Za-z0-9_]|$)" \
			"|cmp([[:space:]]|$)" \
			"|sed([[:space:]][^|]*)?[[:space:];{'\''0-9/]q([0-9]|[[:space:];}'\''\")]|$)" \
			")"
	}
	function flush() {
		if (buf == "") return
		t = buf
		gsub(/\|\|/, "  ", t)
		if (!marked && t !~ MARK && t ~ RE)
			printf "%s:%d: %s\n", file, start, first
		buf = ""
		marked = 0
	}
	BEGIN {
		RE = consumer_re()
		MARK = "#[[:space:]]*early-exit-pipe-ok:[[:space:]]*[^[:space:]]"
	}
	FNR == 1 { flush(); file = FILENAME; marked = 0 }
	{
		if (buf == "") {
			if ($0 ~ /^[[:space:]]*#/) {
				marked = ($0 ~ ("^[[:space:]]*" MARK))
				next
			}
			start = FNR
			first = $0
			sub(/^[[:space:]]+/, "", first)
		}
		buf = buf " " $0
		if ($0 ~ /(^|[^|])\|[[:space:]]*$/ || $0 ~ /\\$/) next
		flush()
	}
	END { flush() }
	' "$@"
}

echo "Test: the scanner flags early-exiting consumers and honors the escape"
flagged=(
	"printf '%s' \"\$x\" | grep -q foo"
	"cmd | grep -Fq foo"
	"cmd | grep -F -- needle -q"
	"cmd | grep --quiet foo"
	"cmd | grep -m1 -n foo | cut -d: -f1"
	"cmd | grep -l foo"
	"cmd | LC_ALL=C grep -qx foo"
	"cmd |& grep -q foo"
	"x=\"\$(cmd | head -n1)\""
	"x=\"\$(cmd | head)\""
	"cmd | IFS= read -r line"
	"cmd | awk '/x/ { print; exit }'"
	"cmd | sed q"
	"cmd | sed -n '/x/{p;q}'"
	"x=\"\$(cmd | sed 1q)\""
	"cmd | sed -n 1p\\;1q"
	"cmd | sed '/re/q'"
	"cmd | sed \"1q\""
	"cmd | sudo grep -q foo"
	"cmd | cmp -s - file"
	"cmd | { read -r x; }"
	"if ! cmd | grep -q foo; then :; fi"
	"cmd | grep -q foo # early-exit-pipe-ok:"
	"cmd | grep -q foo # early-exit-pipe-ok:   "
	"cmd || grep -q x | grep -q y"
	$'# early-exit-pipe-ok:\ncmd | grep -q x'
	$'# early-exit-pipe-ok: not across a plain comment\n# another comment\ncmd | grep -q x'
)
clean=(
	"grep -q foo <<<\"\$x\""
	"[[ \$x == *foo* ]]"
	"grep -m1 -n foo \"\$file\" | cut -d: -f1"
	"head -c 5 /dev/zero | tr '\\0' x"
	"cmd | grep -c foo || true"
	"[ \"\$(cmd | grep -c .)\" -eq 3 ]"
	"cmd | grep foo | sed -n 1p"
	"cmd | while IFS= read -r line; do :; done"
	"cmd | awk '{ print \$1 }'"
	"cmd | sed 's/q/x/'"
	"cmd | sed 's/a/q/'"
	"cmd | sed 's/a/q/g; s/1/2q/'"
	"cmd | sed -n '\$q'"
	"cmd | sed -e 's/^/  /'"
	"cmd | cmpfoo"
	"cmd | tail -n 2"
	"cmd || grep -q foo file"
	"# printf '%s' \"\$x\" | grep -q foo"
	"cmd | grep -q foo # early-exit-pipe-ok: probe payload under test"
	"'payload | grep -q x' # early-exit-pipe-ok: fixture text"
	$'# early-exit-pipe-ok: probe payload\n\'payload | grep -q x\''
)
for i in "${!flagged[@]}"; do
	printf '%s\n' "${flagged[$i]}" >"$TMP/flagged-$i.sh"
	if [ -n "$(scan "$TMP/flagged-$i.sh")" ]; then
		ok "flagged: ${flagged[$i]//$'\n'/ \\n }"
	else
		ko "not flagged: ${flagged[$i]//$'\n'/ \\n }"
	fi
done
for i in "${!clean[@]}"; do
	printf '%s\n' "${clean[$i]}" >"$TMP/clean-$i.sh"
	hits="$(scan "$TMP/clean-$i.sh")"
	if [ -z "$hits" ]; then
		ok "clean: ${clean[$i]//$'\n'/ \\n }"
	else
		ko "falsely flagged: ${clean[$i]//$'\n'/ \\n }" "$hits"
	fi
done

printf 'cmd |\n\tsed s/a/b/ |\n\tgrep -q x\n' >"$TMP/continued.sh"
hits="$(scan "$TMP/continued.sh")"
if [ "$hits" = "$TMP/continued.sh:1: cmd |" ]; then
	ok "a pipeline continued over lines is joined and reported at its first line"
else
	ko "a continued pipeline was not reported at line 1" "$hits"
fi
printf 'cmd |\n\tgrep -q x # early-exit-pipe-ok: payload\n' >"$TMP/continued-ok.sh"
hits="$(scan "$TMP/continued-ok.sh")"
if [ -z "$hits" ]; then
	ok "the escape on a later line of a continued pipeline is honored"
else
	ko "the escape on a continuation line was ignored" "$hits"
fi

printf '# early-exit-pipe-ok: payload\ncmd | grep -q x\ncmd | grep -q y\n' >"$TMP/marker-above.sh"
hits="$(scan "$TMP/marker-above.sh")"
if [ "$hits" = "$TMP/marker-above.sh:3: cmd | grep -q y" ]; then
	ok "a marker line above exempts only the next logical line"
else
	ko "a marker line above did not exempt exactly the next line" "$hits"
fi

echo "Test: no scripts/test-*.sh suite pipes into an early-exiting consumer"
shopt -s nullglob
suites=()
for f in "$SCRIPT_DIR"/test-*.sh; do
	[ "${f##*/}" = "$SELF" ] || suites+=("$f")
done
if [ "${#suites[@]}" -eq 0 ]; then
	ko "no scripts/test-*.sh suites found to scan"
else
	hits="$(scan "${suites[@]}")"
	if [ -z "$hits" ]; then
		ok "${#suites[@]} suites scanned, no early-exiting pipe consumer"
	else
		ko "pipe into an early-exiting consumer under pipefail; see this suite's header for the fix, or mark a deliberate payload with '# early-exit-pipe-ok: <reason>'" "${hits//"$SCRIPT_DIR/"/scripts/}"
	fi
fi

echo
if [ "$failures" -eq 0 ]; then
	echo "early-exit pipe guard: all $checks checks passed"
	exit 0
fi
echo "early-exit pipe guard: $failures of $checks checks FAILED" >&2
exit 1
