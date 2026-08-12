# Task 029c: Preserve the configured Codex model and expose peer review prose

## Why this task exists

`peer-review-run` correctly isolates a Codex peer with `--ignore-user-config`, but that isolation also discards the top-level `model` selected in `$CODEX_HOME/config.toml` by the container's rolling `/model` workflow.

The helper explicitly re-injects `model_reasoning_effort` through a `-c` override, so effort passthrough works today, while an omitted Codex `--model` leaves `MODEL` empty, adds no `-m` argument, and reports `model:null`; the peer therefore uses the bare CLI default instead of the configured high-capability rolling model.

The stable `powbox.peer-review-run/v1` result also returns only `artifactDir`, not a provider-neutral location or field containing the full human-readable review prose; Claude's prose is nested in provider-native JSON in `provider.stdout`, while Codex uses a different final-message artifact, so a caller must currently know undocumented filenames and formats to relay findings verbatim.

Roubtec/agent-skills task 015 is adopting this helper in the canonical review skills, but its Claude-led renderings must retain a raw isolated `codex exec` launch until the helper preserves the configured Codex model without embedding a dated model ID, and all renderings need a stable way to retrieve the peer's full review prose before they can replace their provider-specific extraction.

## Scope

- Preserve the configured top-level Codex model across `peer-review-run`'s user-config isolation when the caller does not provide an explicit model.
- Add a stable provider-neutral result pointer to the full review prose for successful `passed` and `issues` outcomes from both providers, while retaining `artifactDir` and provider-native artifacts for debugging and audit.
- Keep the public command provider-neutral: `--model <ID>` remains the explicit per-invocation override for either provider, while an omitted model resolves through the selected provider's documented default policy.
- Keep explicit effort selection independent from model selection and continue passing Codex effort through `-c model_reasoning_effort=<LEVEL>`.
- Continue reporting the model and effort that the helper actually applied in the existing result contract.
- Document both helper-boundary changes as powbox-owned prerequisites for Roubtec/agent-skills task 015.

Out of scope: loading the rest of Codex user configuration into the peer, weakening project-config/rules/hooks/MCP isolation, selecting or hard-coding a dated Codex model ID, changing Claude's current `opus` default, changing review policy in Roubtec/agent-skills, or changing provider-native artifact retention.

## Context and references

- Powbox issue [#145](https://github.com/Roubtec/powbox/issues/145) records the downstream adoption blocker; configured-model passthrough is the strength gap it describes, while provider-neutral review-prose retrieval is a distinct helper-result gap discovered while preparing the same task 015 adoption and does not require mutating that issue.
- Roubtec/agent-skills task 015 is `tasks/015-adopt-peer-review-run-in-review-skills.md` on its task branch and should consume both helper behaviors after they land.
- Completed powbox task `tasks/done/029-provider-neutral-peer-review-runner.md` defines the original provider-neutral invocation and result contract.
- The historical powbox task 029a was the peer-verdict-notes task re-homed to Roubtec/agent-skills task 015a, and `tasks/deferred/029b-peer-writable-overlay-for-test-execution.md` already exists, so this follow-up uses the next unambiguous suffix, 029c.
- `docker/shared/peer-review-run` documents the strength knobs and result schema in its header, resolves provider defaults in the pre-filesystem strength-knob block, builds provider argv, parses provider final messages, and emits effective strength in the final result object.
- `docs/architecture.md` describes `peer-review-run` in “Rules the file map does not state” and is the durable downstream adoption boundary.

## Desired interface and model semantics

- Do not add a Codex-only caller flag: keep `--model <ID>` as the single provider-neutral explicit override.
- When `--provider codex` is selected and `--model` is omitted, resolve only the root top-level `model` string from `${CODEX_HOME:-$HOME/.codex}/config.toml`, the location managed by the container's `/model` workflow, before launching the isolated peer, then pass that resolved value as one `-m` argv element.
- Put configured-model resolution, TOML parsing, validation, and warnings in the existing strength-knob block alongside the `-*` model check, before artifact-root creation, `SESSION_DIR`, help-probe files, or any other filesystem side effect.
- Parse TOML as TOML with an already-baked runtime facility; do not source the file, use `eval`, or approximate TOML with a regex that can misread comments, quoted values, tables, or escapes.
- An explicit `--model` always wins, is validated by the existing flag-shaped-value rule, and bypasses configured-model lookup entirely, so an unreadable or invalid config cannot affect an explicit invocation.
- A missing config file or a valid config with no root top-level `model` remains the backward-compatible unconfigured case: pass no `-m` and report `model:null` so Codex uses its CLI default.
- Profiles are deliberately outside the passthrough contract: never read a model from `[profiles.*]`; if the root `profile` key selects a profile, do not forward even a root `model`, pass no `-m`, report `model:null`, and warn that profile-dependent selection cannot be preserved through isolated execution.
- If an existing config cannot be read or parsed, or its root `model` is empty, non-string, or flag-shaped, preserve today's otherwise-valid isolated review by passing no `-m`, reporting `model:null`, and emitting a clear stderr warning that configured-model passthrough degraded; this follows the helper's existing honest-degradation precedent rather than turning unrelated user-config damage into an exit-64 failure.
- Continue adding `--ignore-user-config`, `--ignore-rules`, `--disable hooks`, the MCP/approval/project-document overrides, and all existing read-only/session-isolation flags exactly as capability probing permits; only a successfully resolved root model crosses the isolation boundary.
- Keep Claude behavior unchanged: omitted `--model` resolves to `opus`, and an explicit model still overrides it.

## Provider-neutral review payload

- Add an additive `reviewFile` field to `powbox.peer-review-run/v1`; for `passed` and `issues`, it is an absolute path inside `artifactDir` to an owner-only UTF-8 plain-text file containing the full provider final review message used for verdict parsing, with provider JSON envelopes decoded and no helper-authored summary substituted for the provider's prose.
- For `passed` and `issues`, `reviewFile` must be non-null, the file must exist when the result is emitted, and the same semantics must hold for Claude and Codex; other outcomes report `reviewFile:null` unless a future contract explicitly defines usable review prose for them.
- Callers read the path from the result and must not construct provider-specific paths, inspect `provider.stdout`, know Codex's final-message filename, or parse provider-native JSON.
- Preserve `artifactDir` unchanged as the returned final-attempt directory containing that attempt's provider-native artifacts; earlier retry-attempt directories remain siblings under the existing parent session tree, and the normalized review file inside the returned `artifactDir` is an additional stable consumption surface rather than a replacement for diagnostic evidence.

## Result reporting and compatibility

- Keep schema `powbox.peer-review-run/v1`, all existing field names, and all existing outcome semantics; `reviewFile` is an additive field under the schema's documented name-based consumer compatibility rule.
- For a Codex run whose configured model was resolved and passed with `-m`, return that exact applied value in `model`; continue returning the explicit override when one was supplied.
- Keep `effort` independent and report the explicitly applied level even when the model came from configuration.
- Never report a configured model merely because it was present in the file: the field is non-null only when the adapter actually added it to provider argv, profile-selected or degraded resolution reports null, and an unavailable run that never reached the command builder continues to report null strength fields.
- Preserve existing callers: consumers that ignore unknown result keys keep working, explicit model invocations, Claude invocations, and Codex installations with no usable configured root model retain their current command behavior, and `artifactDir` remains the returned final-attempt directory.

## Target files or areas

- `docker/shared/peer-review-run`: pre-filesystem strength-default resolution and warnings, safe Codex model extraction, `build_cmd_codex()`, normalized review-file creation, header contract, `usage()`'s hard-coded `sed -n` range, diagnostics, and final result fields.
- `scripts/test-peer-review-run.sh`: extend the strength-knob cases around case 14 with hermetic fake Codex/config fixtures and argv/result assertions, and cover normalized review prose for both fake providers without provider-native caller knowledge.
- `README.md` “Cross-Agent Delegation” peer-review helper guidance: explain configured-model preservation, independent effort pinning, `reviewFile` consumption, and continued native artifact retention.
- `docs/architecture.md` “Rules the file map does not state”: update the `peer-review-run` adapter/result contract and both Roubtec/agent-skills task 015 adoption dependencies.
- The helper is already copied into the agent image and exercised by the source and baked-helper smoke paths; change Dockerfiles or source manifests only if inspection shows that implementation introduces a new baked dependency or source file.

## Implementation notes

- Grow the header's `--model` paragraph to describe root configured-model resolution and degraded fallback, then extend the line range in `usage()` so `--help` prints the complete header rather than truncating mid-sentence.
- Resolve the configured model in the strength-knob block before any artifact/session path is created; do not defer it to `build_cmd_codex()` or temporarily run Codex without isolation to discover it.
- Read only the root `model` and root `profile` keys from shared Codex config and do not forward profiles, project trust, hooks, MCP servers, approval policy, sandbox settings, instructions, or any other user-config value.
- Treat the parsed model as data and append it through the existing Bash argv array so whitespace, quotes, or shell metacharacters cannot become shell syntax.
- Preserve precedence: explicit CLI model, then a usable root configured Codex model when no profile is selected, then the bare Codex CLI default with honest warning/null reporting for unsupported or degraded configured selection.
- Preserve the existing effort floor and validation independently of model resolution; a configured `model_reasoning_effort` must not override the helper's default or caller-selected `--effort`.
- Keep config lookup outside the reviewed worktree and do not copy the config or its unrelated contents into retained attempt artifacts or diagnostics.
- Normalize the already-parsed final provider message into an owner-only file inside the final attempt's returned `artifactDir` before constructing the terminal result; retain earlier attempts as sibling directories under the existing session parent, and do not make the stable payload path an alias for undocumented provider-native files.
- Use fixture-only model names in tests so neither implementation nor documentation acquires a dated production model pin.

## Acceptance criteria

- A Codex-provider invocation without `--model` reads a valid configured root model when no profile is selected, passes that exact value as one `-m` argument despite `--ignore-user-config`, and reports it in `.model`.
- The same invocation reports the independently requested or defaulted reasoning level in `.effort` and passes the matching `model_reasoning_effort` override.
- An explicit `--model` wins over configuration, bypasses config parsing, and is the only model sent to the provider.
- Missing config and a valid config without a root model preserve the current no-`-m`, `model:null` fallback.
- An active root `profile`, and existing but unreadable, malformed, empty, non-string, or flag-shaped root model values, launch without `-m`, report `model:null`, and emit a clear stderr warning before any artifact/session filesystem side effect; resolving configuration never invokes the provider as a discovery mechanism.
- Tests prove `--ignore-user-config`, rules/hooks isolation, MCP disabling, approvals-off behavior, project-document disabling, read-only sandboxing, and ephemeral execution remain present alongside configured-model passthrough.
- Claude defaults and explicit model behavior remain unchanged.
- Every `passed` or `issues` result from either provider has a non-null absolute `.reviewFile` inside `.artifactDir` whose plain-text contents are the complete provider review message used for the verdict; callers can relay it without inspecting native artifacts or parsing provider formats.
- Non-success outcomes follow the documented null rule, existing `.artifactDir` final-attempt behavior and sibling retry-attempt retention under the session parent are unchanged, and existing schema-v1 consumers that ignore the additive field remain compatible.
- The result contract keeps `.model` and `.effort` describing values actually applied rather than merely requested or discovered.
- No implementation, test, or documentation requires Roubtec/agent-skills to name a dated Codex model ID or to know provider-native result filenames/formats.

## Validation

- Run `shellcheck docker/shared/peer-review-run scripts/test-peer-review-run.sh`.
- Run `shfmt -d docker/shared/peer-review-run scripts/test-peer-review-run.sh` and compare any advisory output with the base branch under the repository's extensionless-helper formatting policy.
- Run `markdownlint-cli2 "**/*.md"` in-container and compare findings with the base branch because the repository documents existing advisory debt.
- Run `./scripts/test-peer-review-run.sh` and `./scripts/run-pure-shell-tests.sh` in-container.
- In hermetic tests, give the helper a temporary `CODEX_HOME` containing representative TOML, capture fake Codex argv, and assert configured resolution, explicit precedence/bypass, missing-key fallback, profile fallback, parse/type/value degradation, warnings before artifact creation, independent effort, result reporting, and unchanged isolation flags.
- In hermetic tests for both providers, produce distinct multiline final messages and assert `.reviewFile` is absolute, inside `.artifactDir`, owner-only, and text-equal to the parsed provider message while the caller test never opens `provider.stdout`, constructs a final-message filename, or parses provider-native JSON.
- This is baked agent-image behavior: rebuild the agent image on the host or in CI, relaunch a container, and run a live Codex-provider review against a disposable worktree without `--model`.
- For the rebuilt-image live smoke, use a root-model/no-profile fixture or record the expected root model with a TOML-aware read of active `$CODEX_HOME/config.toml`, invoke `peer-review-run --provider codex` with an explicit review effort, retain the result and `artifactDir`, and verify `.model` matches the expected configured value, `.effort` matches the requested level, and `.reviewFile` contains a usable full verdict without reading provider-native artifacts.

## Review plan

Review the model-resolution precedence, the explicit-model config bypass, TOML/profile handling, pre-filesystem warning paths, argv construction, effective-result reporting, and every retained isolation flag. Confirm fake-provider tests prove what Codex actually receives and that both providers expose identical stable review-file semantics without format knowledge, then inspect rebuilt-image smoke evidence for configured-model equality, effort equality, and relayable review prose before unblocking the remaining Roubtec/agent-skills task 015 adoption.
