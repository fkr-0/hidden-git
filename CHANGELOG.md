# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- GitHub Actions coverage for static checks, image builds, and the isolated
  authenticated onion SSH end-to-end test (`HG-004`).
- Dependabot review configuration for Docker and GitHub Actions dependencies.

### Changed

- Debian and Go base images are pinned to reviewed multi-architecture OCI
  digests while retaining readable image tags (`HG-005`).

## [0.0.2] - 2026-07-18

### Added

- A managed Soft Serve configuration template so all documented service ports
  are applied consistently instead of relying on an already-generated runtime
  configuration.
- Finite, reusable onion SSH health checks with a dedicated checker image.
- `init`, `config`, `doctor`, `version`, and `help` operator commands.
- Static release checks for shell, YAML, Compose interpolation, secrets hygiene,
  and version consistency.
- An isolated end-to-end harness that validates fresh initialization and
  authenticated SSH locally and through the onion service.
- A structured `issues.yml` backlog for larger operational and security work.

### Changed

- Local Soft Serve ports now bind to `127.0.0.1` by default rather than all
  host interfaces. Set `HOST_BIND_ADDRESS` explicitly to opt into wider access.
- New optional environment settings have backward-compatible defaults so
  existing pre-0.0.2 deployments continue to render and build.
- Soft Serve waits for a real SSH listener health check before Tor starts.
- Tor health now requires a generated onion hostname rather than only a valid
  configuration file.
- The Go builder image is updated to `golang:1.26.5-bookworm`; Soft Serve stays
  pinned to upstream release `v0.11.6`.
- Runtime state, databases, private keys, onion identities, and local `.env`
  files are excluded from Git.
- Docker build contexts exclude local configuration, databases, SSH keys, and
  Tor hidden-service identities.

### Fixed

- `run.sh help` and `run.sh version` no longer require Docker or a local `.env`.
- Inline comments in `.env` values no longer corrupt port and user parsing.
- `status` no longer aborts when services have not started yet.
- Onion checks no longer modify the operator's SSH `known_hosts` file.
- Onion checks now time out with diagnostics instead of looping forever.
- Individual Tor/SSH attempts have hard subprocess deadlines, so proxy-level
  connection stalls cannot overrun the overall check indefinitely.
- First boot now refuses to start without an initial administrator public key.
- Soft Serve HTTP, SSH, stats, and Git ports now match the configured values.

### Security

- Fresh deployments require `SOFT_SERVE_INITIAL_ADMIN_KEYS` before the database
  is created.
- Host-published ports are loopback-only by default.
- Runtime secret material is covered by repository hygiene checks.

## [0.0.1] - 2025-01-06

### Added

- Initial Docker Compose stack combining Soft Serve with a Tor onion service.
- Basic build, start, stop, status, and connectivity helper commands.

