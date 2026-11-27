# 083 — Remove the remaining `printf | grep -q` races from the shell suites

**Relates to:** PR #191, which fixed this in `scripts/test-context-mount-config.sh`. Also `scripts/test-egress-allow-list.sh` and `scripts/test-launcher-volatile.sh`, which already use the in-process pattern, and `scripts/run-pure-shell-tests.sh` / Tier 0.

## Why this task exists

Under `set -o pipefail`, a check of the form `printf '%s' "$text" | grep -q …` fails at random. `grep -q` exits on its first match and closes the pipe. If `printf` is still writing a large text, it dies of SIGPIPE, and the pipeline reports failure although the needle was present. A negated check inverts this and passes when it should not. Any early-exiting consumer behaves the same way, including `awk … exit` and `head`. Tier 0 hit it on an unrelated PR and needed a rerun. Several suites still use the shape on texts that can grow large, for example `scripts/test-seed-marker-source.sh`.

## Goal

No suite in the pure-shell runner, or in the smoke-only set, matches captured output through a pipe into an early-exiting consumer while `pipefail` is set.

## Direction and constraints

- Prefer in-process matching (`[[ $text == *"$needle"* ]]`) for fixed strings, as the fixed suites do. For regex or anchored-line checks, either use `[[ =~ ]]` or feed the consumer without a pipe, for example with a here-string. Note that anchored `^…$` patterns are per-line in grep but not in `[[ =~ ]]`, so keep each check's meaning intact rather than swapping mechanically.
- Some occurrences are deliberate: `scripts/test-smoke-probe-wrapper.sh` uses such pipelines as probe payloads under test, not as its own assertions. Leave those alone.
- Consider a cheap Tier 0 guard (a grep over `scripts/test-*.sh`) so the shape does not creep back. Give it an explicit escape for the deliberate cases above.
