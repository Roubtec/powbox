# Task 029a: Preserve the configured Codex model through peer-review-run

## Why this task exists

`peer-review-run` correctly isolates a Codex peer with `--ignore-user-config`, but that isolation also discards the top-level `model` selected in `$CODEX_HOME/config.toml` by the container's rolling `/model` workflow.

The helper explicitly re-injects `model_reasoning_effort` through a `-c` override, so effort passthrough works today, while an omitted Codex `--model` leaves `MODEL` empty, adds no `-m` argument, and reports `model:null`; the peer therefore uses the bare CLI default instead of the configured high-capability rolling model.

Roubtec/agent-skills task 015 is adopting this helper in the canonical review skills, but its Claude-led renderings must retain a raw isolated `codex exec` launch until the helper can preserve the configured Codex model without embedding a dated model ID downstream.

## Scope

- Preserve the configured top-level Codex model across `peer-review-run`'s user-config isolation when the caller does not provide an explicit model.
- Keep the public command provider-neutral: `--model <ID>` remains the explicit per-invocation override for either provider, while an omitted model resolves through the selected provider's documented default policy.
- Keep explicit effort selection independent from model selection and continue passing Codex effort through `-c model_reasoning_effort=<LEVEL>`.
- Continue reporting the model and effort that the helper actually applied in the existing `powbox.peer-review-run/v1` result.
- Document the behavior as the powbox-owned prerequisite that lets Roubtec/agent-skills task 015 replace its remaining raw Codex launch.

Out of scope: loading the rest of Codex user configuration into the peer, weakening project-config/rules/hooks/MCP isolation, selecting or hard-coding a dated Codex model ID, changing Claude's current `opus` default, or changing review policy in Roubtec/agent-skills.

## Context and references

- Powbox issue [#145](https://github.com/Roubtec/powbox/issues/145) records the downstream blocker and required evidence.
- Roubtec/agent-skills task 015 is `tasks/015-adopt-peer-review-run-in-review-skills.md` on its task branch and should consume this helper behavior after it lands.
- Completed powbox task `tasks/done/029-provider-neutral-peer-review-runner.md` defines the original provider-neutral invocation and result contract.
- `docker/shared/peer-review-run` documents the strength knobs in its header, resolves provider defaults in the strength-knob validation block, builds Codex argv in `build_cmd_codex()`, and emits effective strength in the final result object.
- `docs/architecture.md` describes `peer-review-run` in “Rules the file map does not state” and is the durable downstream adoption boundary.

## Desired interface and semantics

- Do not add a Codex-only caller flag: keep `--model <ID>` as the single provider-neutral explicit override.
- When `--provider codex` is selected and `--model` is omitted, resolve only the top-level `model` string from `${CODEX_HOME:-$HOME/.codex}/config.toml` before launching the isolated peer, then pass that resolved value as one `-m` argv element.
- Parse TOML as TOML with an already-baked runtime facility; do not source the file, use `eval`, or approximate TOML with a regex that can misread comments, quoted values, tables, or escapes.
- An explicit `--model` always wins and must not require the config file to be readable or valid.
- A missing config file or a valid config with no top-level `model` remains the backward-compatible unconfigured case: pass no `-m` and report `model:null` so Codex uses its CLI default.
- If an existing config cannot be read or parsed, or its top-level `model` is not a non-empty string accepted by the helper's existing flag-shaped-value validation, fail clearly before launching the provider rather than silently claiming configured-model preservation while falling back to a different model.
- Continue adding `--ignore-user-config`, `--ignore-rules`, `--disable hooks`, the MCP/approval/project-document overrides, and all existing read-only/session-isolation flags exactly as capability probing permits; only the resolved model crosses the isolation boundary.
- Keep Claude behavior unchanged: omitted `--model` resolves to `opus`, and an explicit model still overrides it.

## Result reporting and compatibility

- Keep schema `powbox.peer-review-run/v1` and its existing field names and outcome semantics.
- For a Codex run whose configured model was resolved and passed with `-m`, return that exact applied value in `model`; continue returning the explicit override when one was supplied.
- Keep `effort` independent and report the explicitly applied level even when the model came from configuration.
- Never report a configured model merely because it was present in the file: the field is non-null only when the adapter actually added it to provider argv, and an unavailable run that never reached the command builder continues to report null strength fields.
- Preserve existing callers: explicit model invocations, Claude invocations, and Codex installations with no configured model retain their current interface and result shape.

## Target files or areas

- `docker/shared/peer-review-run`: strength-default resolution, safe Codex model extraction, `build_cmd_codex()`, header contract, diagnostics, and effective result fields.
- `scripts/test-peer-review-run.sh`: extend the strength-knob cases around case 14 with hermetic fake Codex/config fixtures and argv/result assertions.
- `README.md` “Cross-Agent Delegation” peer-review helper guidance: explain that the isolated Codex adapter preserves only the configured model and still pins effort independently.
- `docs/architecture.md` “Rules the file map does not state”: update the `peer-review-run` contract and the Roubtec/agent-skills adoption boundary.
- The helper is already copied into the agent image and already exercised by the source and baked-helper smoke paths; change Dockerfiles or source manifests only if inspection shows the implementation introduces a new baked dependency or source file.

## Implementation notes

- Resolve the configured model before `build_cmd_codex()` applies `--ignore-user-config`; do not temporarily run Codex without isolation to discover it.
- Read only the root `model` key from the shared Codex config and do not forward profiles, project trust, hooks, MCP servers, approval policy, sandbox settings, instructions, or any other user-config value.
- Treat the parsed model as data and append it through the existing Bash argv array so whitespace, quotes, or shell metacharacters cannot become shell syntax.
- Preserve the existing precedence: explicit CLI model, then the configured Codex model when available, then the bare Codex CLI default when no model is configured.
- Preserve the existing effort floor and validation independently of model resolution; a configured `model_reasoning_effort` must not override the helper's default or caller-selected `--effort`.
- Keep the config lookup outside the reviewed worktree and do not copy the config or its unrelated contents into the retained attempt artifacts.
- Use fixture-only model names in tests so neither implementation nor documentation acquires a dated production model pin.

## Acceptance criteria

- A Codex-provider invocation without `--model` reads a valid configured top-level model, passes that exact value as one `-m` argument despite `--ignore-user-config`, and reports it in `.model`.
- The same invocation reports the independently requested or defaulted reasoning level in `.effort` and passes the matching `model_reasoning_effort` override.
- An explicit `--model` wins over configuration and is the only model sent to the provider.
- Missing config and a valid config without a model preserve the current no-`-m`, `model:null` fallback.
- Existing but unreadable, malformed, empty, non-string, or flag-shaped configured model values fail clearly without launching the provider or leaking unrelated config data.
- Tests prove `--ignore-user-config`, rules/hooks isolation, MCP disabling, approvals-off behavior, project-document disabling, read-only sandboxing, and ephemeral execution remain present alongside configured-model passthrough.
- Claude defaults and explicit model behavior remain unchanged.
- The result contract remains `powbox.peer-review-run/v1`, with `.model` and `.effort` describing values actually applied rather than merely requested or discovered.
- No implementation, test, or documentation requires Roubtec/agent-skills to name a dated Codex model ID.

## Validation

- Run `shellcheck docker/shared/peer-review-run scripts/test-peer-review-run.sh`.
- Run `shfmt -d docker/shared/peer-review-run scripts/test-peer-review-run.sh` and compare any advisory output with the base branch under the repository's extensionless-helper formatting policy.
- Run `./scripts/test-peer-review-run.sh` and `./scripts/run-pure-shell-tests.sh` in-container.
- In hermetic tests, give the helper a temporary `CODEX_HOME` containing representative TOML, capture fake Codex argv, and assert configured resolution, explicit precedence, missing-key fallback, parse/type/value failures, independent effort, result reporting, and unchanged isolation flags.
- This is baked agent-image behavior: rebuild the agent image on the host or in CI, relaunch a container, and run a live Codex-provider review against a disposable worktree without `--model`.
- For the live smoke, record the expected top-level model using a TOML-aware read of the active `$CODEX_HOME/config.toml`, invoke `peer-review-run --provider codex` with an explicit review effort, retain the result and its `artifactDir`, and verify the result's `.model` matches the configured value while `.effort` matches the requested level and the peer returns a usable verdict.

## Review plan

Review the model-resolution precedence, TOML parsing and failure modes, argv construction, effective-result reporting, and every retained isolation flag. Confirm the fake-provider tests prove what Codex actually receives, then inspect the rebuilt-image smoke evidence for equality between the configured expected model and the helper result before unblocking the remaining Roubtec/agent-skills task 015 adoption.
