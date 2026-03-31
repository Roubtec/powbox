# Claude Code Container — Full CLI Tool Requirements

Reference document for humans.
Lists every tool available in the container image, grouped by category.
Derived from `Dockerfile` using `node:24-slim` (Debian 12 / bookworm) as the base image.

---

## Currently Installed

### Node.js / JavaScript

| Tool | Notes |
|---|---|
| `node` | v24 — from `node:24-slim` base image |
| `npm` | Bundled with Node.js |
| `pnpm` | Installed globally via `npm install -g pnpm`; store pinned to `/home/node/.local/share/pnpm/store` |
| `yarn` | Available via Corepack (bundled with Node.js v24) |
| `npx` | Bundled with npm |

### Version Control & Collaboration

| Tool | Notes |
|---|---|
| `git` | |
| `gh` | GitHub CLI — PRs, issues, checks, releases |

### Programming Languages

| Tool | Notes |
|---|---|
| `python3` | Debian 12 package |
| `pip3` | `python3-pip` |
| `perl` | Debian 12 base image |
| `gcc` / `g++` | `build-essential` |
| `make` | `build-essential` |

### PHP

| Tool | Notes |
|---|---|
| `php` | PHP 8.2 CLI (`php8.2-cli`) |
| `composer` | PHP dependency manager — installed via upstream installer |
| `php8.2-xml` | DOM, SimpleXML, XMLReader, XMLWriter |
| `php8.2-mbstring` | Multibyte string support |
| `php8.2-curl` | cURL bindings |
| `php8.2-zip` | Zip archive support (required by Composer) |
| `php8.2-intl` | Internationalization — required by many frameworks |
| `php8.2-sqlite3` | SQLite3 bindings — useful for test suites |
| `php8.2-bcmath` | Arbitrary precision math |
| `php8.2-mysql` | MySQL/MariaDB bindings |
| `php8.2-pgsql` | PostgreSQL bindings |

### Editors

| Tool | Notes |
|---|---|
| `vim` | |
| `nano` | |

### Search & File Navigation

| Tool | Notes |
|---|---|
| `rg` (ripgrep) | Fast content search — bundled with Claude Code |
| `fzf` | Fuzzy finder |
| `tree` | Directory visualisation |
| `fd` | Fast `find` replacement — `fd-find` package, symlinked to `fd` |
| `bat` | Syntax-highlighted file viewer — `bat` package, symlinked from `batcat` to `bat` |

### Shell Development

| Tool | Notes |
|---|---|
| `shellcheck` | Static analysis for shell scripts |
| `shfmt` | Shell script formatter |

### Networking & DNS

| Tool | Notes |
|---|---|
| `curl` | HTTP requests |
| `wget` | File downloads, recursive fetches |
| `openssl` | TLS/certificate inspection |
| `ssh` / `scp` / `ssh-keygen` | Remote access (`openssh-client`) |
| `dig` | DNS lookups (`dnsutils`) |
| `nslookup` | DNS lookups (`dnsutils`) |
| `ss` | Socket statistics (`iproute2`) |
| `ip` | Network interface management (`iproute2`) |
| `ping` | Basic reachability test (`iputils-ping`) |
| `nc` | TCP/UDP connectivity testing (`netcat-openbsd`) |
| `iptables` | Firewall rules — used by `init-firewall.sh` at container startup |

### Core Unix Utilities

| Tool | Notes |
|---|---|
| `sed`, `awk`, `xargs` | Text processing |
| `less` | Pager for git, man, etc. |
| `diff`, `patch` | File comparison and patching |
| `file` | File type identification |
| `tar`, `zip`, `unzip` | Archive handling |
| `bzip2`, `xz`, `zstd` | Additional compression formats |
| `base64`, `iconv`, `tee` | Encoding, conversion, stream duplication |
| `ps`, `kill`, `watch`, `timeout` | Process management and scheduling (`procps`) |
| `htop` | Interactive process monitor |
| `rsync` | Efficient file sync |
| `gpg` | Signing and encryption (`gnupg`) |
| `bc` | Command-line calculator |
| `lsof` | Lists open files and network connections |
| `strace` | Trace system calls |
| `xxd` | Hex dump for binary file inspection |
| `envsubst` | Substitute `$ENV_VAR` placeholders in template files (`gettext-base`) |

### Data Processing

| Tool | Notes |
|---|---|
| `jq` | JSON query and transform |
| `yq` | YAML query and transform — installed via `pip3 install yq` |
| `sqlite3` | Lightweight local database for scripting and prototyping |

### Document Processing

| Tool | Notes |
|---|---|
| `pdftotext` | Extract text from PDFs (`poppler-utils`) |
| `pdftoppm` | Render PDF pages to images (`poppler-utils`) — used by Claude Code's `Read` tool |
| `pdfinfo` | PDF metadata (`poppler-utils`) |

### Database

| Tool | Notes |
|---|---|
| `sqlcmd` | Azure SQL / SQL Server CLI (`mssql-tools18`) |
| `bcp` | Bulk copy utility for Azure SQL / SQL Server (`mssql-tools18`) |

### Package Management

| Tool | Notes |
|---|---|
| `apt` / `dpkg` | Debian package management |
| `sudo` | Scoped to `init-firewall.sh` and `apt-get` — see `/etc/sudoers.d/node` |

---

## Intentionally Not Included

These were evaluated and omitted. Some could be added per-session inside the container if needed.

| Tool | Reason |
|---|---|
| `delta` (`git-delta`) | Nice diff viewer but not essential; adds image weight |
| `az` (Azure CLI) | Deployment managed outside the container |
| `bun` | Not part of the project's runtime stack |
| Docker CLI | No Docker-in-Docker use case |
| `kubectl` | No Kubernetes deployment |
| Terraform / Pulumi | Infrastructure managed outside this container |
| Go, Rust, Ruby, Java | Not part of this project's stack |
| `psql`, `mysql`, `redis-cli` | Only Azure SQL is used |
| `cmake` | No CMake-based builds |
| `nmap` | Not a security testing container |
