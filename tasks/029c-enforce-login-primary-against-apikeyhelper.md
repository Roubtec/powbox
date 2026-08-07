# 029c — Enforce `peer-review-run`'s login-primary policy against `apiKeyHelper`

## Why this task exists

Powbox documents a credential policy for a delegated peer review: the logged-in subscription session is **primary**, and an inherited env credential is the **fallback**. That is the reverse of Claude Code's own precedence, so it only holds because `peer-review-run` drives it — in `login` mode it prefixes the provider command with `env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN` (`docker/shared/peer-review-run:966`) so the stored login is what authenticates.

The clear covers the three **environment** credentials. It does not cover a `settings.json` `apiKeyHelper`, which Claude Code also checks ahead of the stored login — the helper's own comment at `docker/shared/peer-review-run:954` already names that ordering (`ANTHROPIC_AUTH_TOKEN`, then `ANTHROPIC_API_KEY`, then `apiKeyHelper`, then `CLAUDE_CODE_OAUTH_TOKEN`, then the `/login` credentials). So on a host where `apiKeyHelper` is configured, a `login`-mode peer review still authenticates through the helper's key: the "primary" subscription session is bypassed and the review can bill to the API account instead.

This was found reviewing PR #143, by a peer reviewer that reproduced it directly — an isolated `claude --safe-mode auth status` with both a stored login and a configured `apiKeyHelper` reported `authMethod: api_key_helper`. `--safe-mode` disables CLAUDE.md, skills, plugins, hooks and MCP, but it does not neutralize auth settings, so the adapter's existing isolation flags do not close this.

Nothing is *broken* today for the common case: powbox does not configure `apiKeyHelper` anywhere, and no in-repo path sets one. The gap is that a user who configures one on their host silently loses a documented guarantee, in the direction that costs money. That is why this is queued rather than deferred — the condition can occur now, on any host, with no further functionality needed.

## Scope

**In scope:**

1. Make `login` mode actually reach the stored login when an `apiKeyHelper` is configured, or make the helper report honestly that it could not.
2. Cover the chosen behavior in `scripts/test-peer-review-run.sh`, alongside the existing `10j-login` / `10j-nologin` env-credential cases.
3. Reconcile the documentation with whatever is implemented: the README "Cross-Agent Delegation" policy paragraph currently states this exception explicitly and points here, and `docs/architecture.md`'s `peer-review-run` bullet describes the auth-precedence handling.

**Out of scope:**

- The interactive-session approval prompt for a detected `ANTHROPIC_API_KEY`. That is Claude Code's own UX and does not affect the headless peer, which is what this policy governs.
- The statusline's `env auth` label (`docker/claude/agent-container/statusline-command.sh`). It deliberately under-claims — it reports that an env credential is present, not which credential won — and its comment already records that `apiKeyHelper` is invisible to it. Changing the peer's auth handling does not change what a statusline can observe.
- Codex-side auth. `CODEX_API_KEY` is a first-class auth path for that provider and has no login-primary policy to enforce.

## Approach options

Decide between these rather than assuming the first; record the reasoning.

- **Neutralize it for the invocation.** Claude Code reads `apiKeyHelper` from settings. If a documented flag or config override can suppress it per-invocation, that is the cleanest analog to the existing `env -u` — same shape, same place in `build_cmd_claude`. Verify against the installed CLI rather than assuming the flag exists; the helper already has a capability-probe mechanism (`provider_supports`) for exactly this kind of version-dependent flag, and the probe result should decide whether the guarantee can be made.
- **Detect and report.** If it cannot be suppressed, read the effective settings for an `apiKeyHelper` before a `login`-mode attempt and, when one is present, either refuse `login` mode with a clear `reason`, or proceed while recording in the result that the login-primary guarantee did not hold. The result contract already carries `reason`, and the schema's additive-within-v1 convention allows a new field if one is genuinely needed.
- **Document only.** If neither is workable, keep the README exception permanently and say so in the helper header too, so the next reader does not re-discover it. This is the weakest outcome and should be chosen only if the first two are demonstrably impossible.

Whichever is chosen, the honesty rule the helper already follows applies: it must never report a clean login-mode result while the login was not what authenticated.

## Target files or areas

- `docker/shared/peer-review-run` — `build_cmd_claude` (~lines 945-967), where the `env -u` prefix is applied and the precedence comment at ~954 already names `apiKeyHelper`; the auth-mode selection and fallback retry (~1563-1640).
- `scripts/test-peer-review-run.sh` — the auth-precedence cases (~lines 809-1000), which already shim `claude` and assert on a recorded env log. An `apiKeyHelper` case fits the same fixture shape.
- `README.md` — the "Credential policy for a delegated peer" paragraph in Cross-Agent Delegation, which currently documents this as a known unenforced exception and links here. Update it to match the implemented behavior.
- `docs/architecture.md` — the `peer-review-run` bullet's auth-precedence sentences.

## Acceptance criteria

- With a stored login **and** a configured `apiKeyHelper`, a `login`-mode peer review either authenticates through the stored login, or the emitted result makes it unambiguous that it did not — no run reports a normal login-mode success while the helper's key authenticated.
- `scripts/test-peer-review-run.sh` covers the `apiKeyHelper`-present case in both `login` and `key` modes and fails if the behavior regresses.
- The env-credential behavior is unchanged: the existing `10j-login` and `10j-nologin` assertions still pass, and `key` mode still leaves all three variables in place.
- README and `docs/architecture.md` describe what the code does, with no remaining "not currently enforced" exception if it was in fact enforced.
- `shellcheck` (error severity), `shfmt -d`, and the pure-shell runner pass.

## Validation

Run `scripts/test-peer-review-run.sh` (hermetic, fake `claude`/`codex` binaries — no live provider needed). Then, on a host with a real login, configure a throwaway `apiKeyHelper` in `settings.json` and confirm a `login`-mode invocation behaves as the chosen option specifies; remove it afterwards. Smoke Stage 0f targets the baked helper, so an image rebuild is needed only to validate the installed copy.

## Status

**Not started.** Queued, not deferred: the condition can occur on any host today. No prerequisites — the fix is local to `peer-review-run` and its suite.
