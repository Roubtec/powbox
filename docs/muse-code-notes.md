# Muse Code operational notes

These are field notes on getting Muse Code to behave as a peer reviewer the way Codex and Claude already do in powbox containers. The opt-in build, the login and the review command are covered in the README's [Optional third harness: Muse Code](../README.md#optional-third-harness-muse-code-reviewer-only) section; this chapter keeps what was learned the hard way and is not obvious from Muse's own help.

The observations were made with Muse 1.4.20 in November 2026. Muse changes quickly, so re-check anything here against the binary in front of you before building on it.

## Telling the "unavailable" causes apart

`peer-review-run --provider muse` reports several different failures as `unavailable`, and they need different fixes. `muse usage` is the first thing to run, but a passing `muse usage` proves only that the login works.

- **Logged out:** `muse usage` exits non-zero. Run `muse login` once from any container; the login lives on the shared `muse-config` volume.
- **Allowance exhausted:** `muse usage` succeeds but shows the window or the weekly allowance at or near 100%. Reviews then fail with what `peer-review-run` reports as an authentication or usage/quota problem. Wait for the reset or raise the plan.
- **No models served:** `muse usage` succeeds with allowance to spare, yet a bare `muse` exits with `failed to fetch model catalog: model catalog has no visible models`. With an explicit `--model`, Muse warns `model catalog has no visible models; continuing with model …` and the server then refuses every model with `does not exist or you lack access`, contributor variants included. Retrying with another model does not help. See the next section.

A cheap end-to-end probe that separates all three is a one-word prompt, run from a scratch directory:

```bash
printf 'Reply with the single word: hello\n' > prompt.md
muse exec --prompt-file prompt.md --disable-write --no-foreign-personal-context
```

A reply of `hello` means models are served and the allowance has room. On stderr, a scratch directory also draws harmless notes that agent delegation is unavailable and project MCP servers are not loaded because the workspace is untrusted.

## The model catalog is filtered by network

The "no models served" case is not a login or subscription problem. Calling `GET https://api.meta.ai/v1/models` with the account's API key returns HTTP 200 with an empty `data` list, so the account is authenticated and the catalog is filtered on the server per request.

What decides the filter appears to be the network a request comes from, not the account or the country:

- The same account, at the same time, is served every model from a residential connection and none from a datacenter VPS.
- A fresh `muse login` approved through a VPN exiting in the VPS's own country changed nothing, and the residential network is in a different country with no visible difference in policy.
- Codex and Claude run without trouble on that same VPS, so nothing powbox does on the network side is involved.

The most likely explanation is that datacenter address space is filtered. That is unconfirmed and unpublished; Meta support could clarify it for a specific account, given the request IDs Muse prints on failing runs. Expect GitHub-hosted Actions runners to be filtered too, since they also run on datacenter networks.

Two ways around it were considered. One is sending only Muse's traffic out through a residential connection the user owns, using the configurable egress exceptions and the [tailnet proxy guide](tailnet-proxy-guide.md). The other is running Muse reviews from a self-hosted runner on a residential network; that plan was drafted but is kept outside `main` while the proxy route is tried.

## Settings and contributor mode

- Muse's saved settings are `~/.config/muse/settings.json`, which on powbox lives on the shared `muse-config` volume, so a change applies to every container on the machine.
- The file is a flat JSON document that must carry `"schema_version": 1`. Without it Muse refuses to start with `malformed settings file … no schema_version member`, which matters when writing the file by hand or from a script.
- `"contributor_mode_enabled": true` turns contributor mode on. Requests then go to the `-contributor` variant of the chosen model (for example `muse-wonder-1.0-contributor`). Muse may ask once, interactively, for the contributor disclosure to be acknowledged (`contributor_mode_disclosure_acknowledged`), so do that from an interactive shell before relying on it headlessly.
- `MUSE_CONTRIBUTOR_MODE=0` or `=1` overrides the saved setting for one `peer-review-run` without touching the file.
- `"endpoint_transport": {"proxy": "http://<host>:<port>"}` sends Muse's model requests through a forward proxy; `muse exec -c 'endpoint_transport.proxy="…"'` does the same for one run. Muse's public docs do not describe it; the [tailnet proxy guide](tailnet-proxy-guide.md#muse) says how it was confirmed and what it was not shown to cover.

## Headless `muse exec` pitfalls

- **Working directory under `~/.config/muse`:** `muse exec` fails with `policy store path must not be under a protected root`. Run it from the checkout under review or a scratch directory.
- **The caller's personal instructions:** without `--no-foreign-personal-context`, Muse loads the invoking user's `~/.claude/CLAUDE.md` and truncates it past 32,000 bytes. The review form always passes the flag.
- **`--disable-write` is an instruction, not a sandbox:** it withholds the file-writing tools and tells the model the session is read-only, while the shell stays available. A review prompt should still say that builds, tests and file changes are out of scope.
- **The exit status does not show whether a review succeeded.** Read the verdict from the answer text, as `peer-review-run` does. `--json` streams JSONL events, and the `run.terminal.completed` record carries the final answer as `text`.

## Models

`muse-wonder-1.0` is the default and the fallback. `muse-wonder-full-1.0` is stronger and only available on plans that include it; a run that exits within seconds saying the model `does not exist or you lack access` while other models work means the plan lacks it. `muse-spark-1.3` also exists. `peer-review-run` prefers the full model and spends its second attempt on the default one.
