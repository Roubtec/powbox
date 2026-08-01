# Task 002d — Stop `set -e` from masking every non-final clause of a multi-clause smoke probe

Generic follow-up from the PR #120 review (bake the .NET SDK into the base image): https://github.com/Roubtec/powbox/pull/120.
A fresh reviewer and the codex peer independently reached the same conclusion about the .NET probes added there.
The two .NET probes were fixed in that PR by hand; the **same defect exists in every other multi-clause probe** and was deliberately left out of scope, because a central fix flips the pass/fail behavior of many pre-existing probes at once and could redden CI for reasons unrelated to .NET.

## The defect

`scripts/smoke-test-image.sh` (lines 12-15) and `scripts/smoke-test-image.ps1` (line 15) join every probe into a **single** shell script prefixed with `set -e`, then run it as `docker run --entrypoint /bin/sh <image> -lc "<script>"`.

POSIX `set -e` exempts a failing command that is "part of any command executed in a `&&` or `||` list except the command following the final `&&` or `||`".
So in a probe written as `A && B && C`, a failure of `A` or `B` does **not** exit the shell.
The `&&` list still evaluates to non-zero — but because a probe is emitted as one *line* of a multi-line script and is (for every probe except the very last) followed by another line, the shell simply moves on and that non-zero status is discarded.
Net effect: **only the final clause of a multi-clause probe is enforced, and only when an earlier clause did not short-circuit past it.**

Minimal repro (verified in `dash`, `bash`, `bash --posix`, and `/bin/sh`):

```sh
# non-final failing element of an && list: exempt from set -e
$ dash -c 'set -e; [ 1 = 1 ] && [ -n "" ] && [ 2 = 2 ]; echo CONTINUED'
CONTINUED          # rc=0

# final element: honored
$ dash -c 'set -e; [ 1 = 1 ] && [ 2 = 2 ] && [ -n "" ]; echo CONTINUED'
                   # rc=1, aborts
```

And the same shape as the driver actually emits it — the probe is a **non-final line**, so even the list's own non-zero status is thrown away:

```sh
$ dash -c 'set -e
[ 1 = 1 ] && [ 2 = 2 ] && [ -n "" ]
true'
$ echo $?
0                  # the whole "script" reports success
```

## Which probes are affected

*(Line numbers below are as of PR #120's head, i.e. what you will see once it merges.)*

Every `&&`-chained probe in the Stage 1 list of `commands/smoke-test.sh` / `commands/smoke-test.ps1` whose real assertion is not the last clause. The reviewer's worked example:

- `commands/smoke-test.sh:294` (mirrored at `commands/smoke-test.ps1:265`) — the ccache functional probe. A failing `ccache gcc -c` short-circuits before the terminal `ccache --print-stats | grep -Eq …`, the failure is exempt, the line is discarded, and the probe reports a false **pass**. The one thing it is supposed to prove (that two identical compiles produce a cache hit) is therefore only checked when the compiler half already succeeded.
- The golangci-lint fixture probe at `commands/smoke-test.sh:303` — `mkdir && cd && git init && git commit && git worktree add`; every step but `git worktree add` is unenforced, so a broken fixture surfaces as a confusing failure on the *next* probe instead of this one.
- The opa probe (`:309`), the gobin probe (`:307`), and the ccache-config probe (`:293`) have the same shape. Most of them happen to put the meaningful assertion last, so they are not *currently* silently green — but nothing in the file enforces that ordering, and the .NET probes show how easily it is lost.

The two `.NET` probes (`commands/smoke-test.sh:311-312` and `commands/smoke-test.ps1:282-283`) are **already fixed** in PR #120 with a per-probe `|| { echo "SMOKE PROBE FAILED: …" >&2; exit 1; }` tail; this task generalizes that.

A second, related gap: **the driver cannot report which probe failed.** `scripts/smoke-test-image.sh` runs the joined script under `set -euo pipefail` and, on a non-zero `docker run`, aborts with no output naming the probe; `scripts/smoke-test-image.ps1` throws `"Smoke test failed. See container output above."` — but a bare `[ -f … ]` prints nothing, so there frequently *is* nothing above. Diagnosing a red Stage 1 today means bisecting the probe list by hand.

## Suggested fix (from the review)

Emit each probe wrapped by the driver, so no probe author has to remember the tail — closing both the masking and the diagnosability gap at once:

```sh
# scripts/smoke-test-image.sh, replacing the plain `SCRIPT+="${cmd}"$'\n'` join
for cmd in "$@"; do
	SCRIPT+="${cmd} || { echo \"SMOKE PROBE FAILED: ${cmd}\" >&2; exit 1; }"$'\n'
done
```

with the equivalent in `scripts/smoke-test-image.ps1`'s `-join` construction.

Points to settle during implementation:

- **Quoting.** Probe strings contain single quotes, double quotes, `$`, `&&`, backslashes and `|`. Interpolating a probe verbatim into a double-quoted `echo` argument inside the same script will break on some of them. Prefer a form that cannot re-parse the probe text — e.g. emit a stable index (`SMOKE PROBE 37 FAILED`) plus a separately-printed numbered manifest, or `printf '%s\n'` from a here-doc-fed variable. Do not ship something that only works for the probes present today.
- **Blast radius.** This makes every currently-masked clause binding for the first time. Expect probes that have been silently passing to turn red — that is the point, but the PR must actually run the full smoke on the host/CI and triage each new failure, not just land the driver change.
- **Probes that legitimately continue.** Confirm none of the existing probes rely on a non-zero intermediate status (e.g. `rm -rf` on a missing path, `ccache -z` on a cold cache). Any that do need explicit `|| true`.
- **Keep the two files in lockstep.** `commands/smoke-test.sh` and `commands/smoke-test.ps1` carry byte-identical probe strings today; whatever shape is chosen must preserve that, and `commands/smoke-test.ps1` must stay CRLF / pure-ASCII / no-BOM per `AGENTS.md` → "File Conventions".

## Target files or areas

- `scripts/smoke-test-image.sh`, `scripts/smoke-test-image.ps1` — the join and the failure reporting.
- `commands/smoke-test.sh`, `commands/smoke-test.ps1` — the Stage 1 probe lists; the .NET probes' now-redundant per-probe tails can be dropped once the driver does it centrally, and the explanatory comment block that documents the hazard should be retargeted at the driver.
- `docs/architecture.md` → "Bundled .NET SDK" — references this task and the per-probe tail; update when the central fix lands.

## Acceptance criteria

- A deliberately broken non-final clause in any Stage 1 probe fails the smoke run.
- The failure output names the offending probe unambiguously.
- Probe strings containing quotes, `$`, and `|` survive the wrapping unmangled — pinned by a pure-shell unit test over the join logic, so this is not a build-only assertion.
- A full host/CI smoke run is green afterwards, with any newly-surfaced pre-existing failure either fixed or explicitly triaged in the PR description.

## Validation

- In-container: `shellcheck` and `shfmt -d` on the touched shell files; PSScriptAnalyzer on the `.ps1` side; a new `scripts/test-*.sh` covering the join/quoting.
- Host/CI: `commands/smoke-test.sh` end to end against a freshly built image — this is the whole point of the task and cannot be skipped.

## Review plan

Reviewer checks that the wrapping is injection-proof for arbitrary probe text (not just today's set), that no probe silently gained an `|| true` to paper over a real failure, that the `.sh`/`.ps1` probe lists stayed byte-identical and the `.ps1` kept its CRLF/ASCII/no-BOM state, and that the PR reports the result of a real smoke run rather than static reasoning.
