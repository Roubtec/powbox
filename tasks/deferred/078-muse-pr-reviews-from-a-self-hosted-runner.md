# 078 — Muse PR reviews from a self-hosted runner

**Relates to:** the optional Muse Code peer reviewer (README "Optional third harness: Muse Code", `peer-review-run --provider muse`).

## Why this task exists

Muse Code serves no models to the maintainer's always-on VPS, so the Muse peer reviewer cannot run in powbox containers there. The same Muse account works all day, with every model, from the maintainer's home machine in Slovakia. Reviews by Muse are still wanted, so they need to run from a network Meta serves.

## What we learned (2026-11-13/14, Muse 1.4.20)

- **Symptom:** in a container on a German VPS, a bare `muse` exits with `failed to fetch model catalog: model catalog has no visible models`. With an explicit `--model`, Muse warns `model catalog has no visible models; continuing with model …` and the server then refuses every model with `does not exist or you lack access`. That covers `muse-wonder-full-1.0`, `muse-wonder-1.0`, `muse-spark-1.3` and, with contributor mode on, `muse-wonder-1.0-contributor`.
- **The login is not the problem.** `muse usage` succeeds and reports an active Power Usage subscription. Calling `GET https://api.meta.ai/v1/models` with the stored API key returns HTTP 200 with an empty `data` list. So the account is authenticated, and the catalog is filtered on the server per request.
- **The filter seems to depend on the network a request comes from, not the country or the login.** Slovakia and Germany are both EU, and the home machine is served. A fresh `muse login` approved through a German VPN changed nothing. Most likely the VPS's datacenter network is filtered. This is unconfirmed and unpublished. Meta support could allow it. Request IDs from failing runs to send them: `7c2947b3-19f6-45e6-a339-a4d13f9dc4d0`, `bd4893ac-7869-4f18-bb67-bfa6a383f329`, `32841b9d-817f-407f-9415-509559981829`, `01853646-781f-474e-91fb-8703367d2dec`. Deliberately routing around the filter is out of scope.
- **Expect GitHub-hosted runners to be filtered too**, since they also run on datacenter networks. That is why this task uses a runner on a residential connection rather than a hosted action.
- **There is no official Muse GitHub integration.** At the time, only third-party write-ups existed, and some of them say Meta's GitHub examples drive the Meta Model API through OpenCode rather than Muse Code. `muse exec` is the headless entry point, and `--json` streams JSONL events whose `run.terminal.completed` record carries the answer as `text`.
- **Muse's saved settings** live in `~/.config/muse/settings.json`, a flat document that must carry `"schema_version": 1`; without it Muse refuses to start (`malformed settings file … no schema_version member`). `"contributor_mode_enabled": true` turns on contributor mode, and requests then go to the `-contributor` variant of the model. Muse may also ask once, interactively, for the contributor disclosure to be acknowledged (`contributor_mode_disclosure_acknowledged`). On powbox this file lives on the shared `muse-config` volume, which now has contributor mode on.
- **Pitfalls seen while probing:** running `muse exec` with the working directory under `~/.config/muse` fails with `policy store path must not be under a protected root`. Without `--no-foreign-personal-context`, Muse loads the invoking user's `~/.claude/CLAUDE.md` and truncates it beyond 32,000 bytes.
- **Powbox's side of the symptom:** `peer-review-run` reports an empty Muse catalog as `unavailable`, with no second attempt on the fallback model. The agents' delegation notes say that a passing `muse usage` does not prove models are served.

## Goal

When a PR is opened or updated, it gets a review from Muse posted back to GitHub, run from a machine on a residential network that Meta serves. The VPS stays the always-on workhorse for everything else.

## Direction

The maintainer is leaning toward an old PC on the home network, dedicated to this as a self-hosted GitHub Actions runner. It builds nothing: it checks out the PR, hands the repository state and a review prompt to `muse exec`, and posts the answer to the PR. A workflow triggered by pull requests targets the runner by a label. If the PC is offline, GitHub keeps a self-hosted job queued for up to 24 hours, so reviews catch up when it comes back.

A lighter fallback, if no machine can be dedicated: a script the maintainer runs by hand on the home machine. It lists open PRs with `gh`, reviews each with `muse exec` and posts the result.

## Landmines

- **Untrusted PR code must not reach a privileged runner.** Use the `pull_request` trigger, not `pull_request_target`, and do not run fork PRs on the self-hosted runner. A persistent runner keeps whatever a job leaves behind, and GitHub advises against self-hosted runners for public repositories. Keep the runner's machine and account limited to what this job needs.
- **Keep the review read-only.** `--disable-write` is an instruction, not a sandbox: Muse's shell stays available. The runner's checkout should be disposable, and the token the job holds should only be able to comment.
- **Credentials:** the runner needs a Muse login, or a `META_API_KEY` if Meta issues one that works headlessly, plus a GitHub token that can comment on PRs. Muse's device-code login has to be approved once, interactively, on that machine.
- **Muse's exit status does not show whether the review succeeded.** Read the verdict from the answer text, the way `peer-review-run` does, rather than relying on the exit code. Treat an empty catalog as "Muse unavailable" and say so on the PR, rather than failing the check red.
- **Pick how findings appear:** inline review comments per finding, which is the house review format in CLAUDE.md, or a single summary comment. Inline comments need the model's output in a structured form that can be mapped onto lines in the diff.
