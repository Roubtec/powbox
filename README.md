# PowBox Dockerized Development Sandbox

This repository contains the code for building Dockerized development containers for CLI agents where they can run with full permissions in isolated environments with no ability to affect the host system.

The functionality depends on Docker being installed on the system.

The Codex container image includes the Linux `bubblewrap` helper that Codex expects for its native sandbox backend.

## License

This project is licensed under the MIT License.
See [LICENSE](LICENSE).
