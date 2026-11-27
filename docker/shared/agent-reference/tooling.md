# Tooling in this image

What is baked into this image, with the pinned versions and the caveats worth knowing before first use. Read it before concluding that a tool is missing or installing one, and before first using a linter, a document converter, or a tool a layer set adds.

This file is read from the image, so it describes the image you are running in. The instruction file is rendered onto a config volume that containers from other image builds share, so its own tool list can describe another image; this one cannot.

## Available tooling

Everything below is on `PATH` and ready to use — no installation needed.

| Category | Tools |
|----------|-------|
| Core runtime | `node`, `npm`, `pnpm`, `python3`, `pip3` |
| Git/GitHub | `git`, `gh`, `ssh` |
| Shell | `zsh`, `jq`, `yq`, `fzf`, `less`, `tree`, `file`, `htop`, `shfmt`, `strace`, `lsof`. `yq` is the jq wrapper for YAML (`yq --help` says so), so its filters are jq syntax, not the Go tool's. |
| Build | `make`, `patch`, `gcc`, `g++` |
| Shell linting | `shellcheck` 0.11.0 is the baked default, the same release GitHub's ubuntu runners ship, so a clean local pass predicts a clean CI pass; a repository's pinned version or wrapper stays authoritative when present. |
| GitHub Actions linting | `actionlint` 1.7.12 is the baked default; invoke it as `actionlint`, but use a repository's pinned version or wrapper when present. |
| Markdown linting | `markdownlint-cli2` 0.24.2 is the baked default; invoke it as `markdownlint-cli2`, but repository CI pins and wrappers remain authoritative, so use the wrapper or `npx --yes markdownlint-cli2@<pin>` when another version is required. It exits zero when its globs match no files, so a wrong path or an over-broad ignore reads as a clean pass: check the `Linting: N file(s)` line it prints. |
| Workflow debugging | `wf-check <script.js>` validates Claude Workflow metadata and async-body syntax without running it; `wf-status <runId-or-transcript-dir>` summarizes a run best-effort from its snapshot, journal, and agent transcripts. |
| Archives/transfer | `wget`, `curl`, `zip`, `unzip`, `rsync`, `bzip2`, `xz`, `zstd` |
| Data | `envsubst`, `bc`, `xxd` |
| Databases | `sqlite3` |
| Network | `ping`, `nc` |
| File search | `rg`, `fd`, `bat`. `rg` is a real binary at `/usr/bin/rg`, so scripts, Makefiles and test suites you run can call it too, not only your own shell. |
| Document processing | `pdftotext`, `pdftoppm`, `pdfinfo`, `pandoc`, `typst`. `pandoc` converts Markdown to Word, PowerPoint, HTML and EPUB, and to PDF through the baked Typst engine: `pandoc in.md -o out.pdf --pdf-engine=typst` (US Letter by default; add `-V papersize=a4` for A4, and `--extract-media=<dir>` when the input is a `.docx` that contains images, or Typst cannot find them). No headless browser and no LaTeX are part of this base image, so turning HTML or a slide deck into PDF needs a browser: use one the layer-set section at the end of this file documents when it is there, and otherwise install what you need for the session. |
| Editors | `nano`, `vim` |
| Sandbox | `bubblewrap` (`bwrap`) |

Tools that an optional layer set adds to this image are listed at the end of this file, under "Contributed by the … layer set", when the set documents them. The table above is the floor every image carries, not a complete list: a layer set can add tools without documenting them, so check with `command -v` before concluding that a tool is missing.

## Installing additional packages

- **System packages:** `sudo apt-get update && sudo apt-get install -y <package>` — `sudo apt-get` goes through a wrapper that manages packages from the configured repositories only. It refuses config options such as `-o`, local `.deb` files, paths, URLs and the less common verbs, and it has no terminal, so pass `-y` where apt would ask to confirm; `sudo apt-get --help` lists exactly what it accepts.
- **Python packages:** `pip3 install <package>` — no `--break-system-packages` flag needed.
