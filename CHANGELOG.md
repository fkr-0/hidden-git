# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.3] - 2026-07-26

### Added

- Architecture, roadmap, and release-process documents covering trust
  boundaries, state ownership, recovery semantics, SemVer policy, release
  gates, and the path to a stable operator contract.
- Static validation that the canonical version is valid SemVer, all release
  metadata agrees, and a CI tag exactly matches `v<VERSION>`.
- GitHub Actions coverage for static checks, image builds, and the isolated
  authenticated onion SSH end-to-end test (`HG-004`).
- Dependabot review configuration for Docker and GitHub Actions dependencies.
- Actionable `doctor` PASS/WARN/FAIL reporting, strict audit mode, connection
  hints in `status`, permission repair, and an issue-summary command.
- Encrypted age backups with internal file manifests, checksum sidecars,
  empty-target restore protection, and preserve-or-rotate onion identity modes.
- A tested maintenance image and end-to-end backup/restore regression test.
- Security and operator guidance in `SECURITY.md`.
- A release-evidence command and tag-only CI artifact containing SLSA v1
  provenance, CycloneDX SBOMs, and vulnerability reports for every image.
- Safe `sync-pins` migration for existing environment files.
- A vulnerability policy report with strict release gating for every high or
  critical finding.
- Dedicated Soft Serve and Tor users with stable UIDs, an idempotent stopped-
  stack migration, read-only root filesystems, dropped capabilities, and
  `no-new-privileges`.
- Tor readiness now requires control-port-confirmed 100% bootstrap rather than
  treating creation of the onion hostname as network readiness.
- The pinned Soft Serve source is rebuilt with explicit fixed versions of Wish,
  go-git, go-jose, `x/crypto`, and `x/net`; the binary retains version v0.11.6.
- Soft Serve readiness uses an SSH-banner TCP probe, allowing the unused
  OpenSSH client package to be removed from the runtime image.
- Permission repair now preserves host ownership of top-level bind mounts while
  retaining private modes and dedicated ownership below them.
- State detection now runs inside the maintenance container, preventing
  unreadable root-owned databases from being misclassified as fresh installs.
- Doctor and `legacy-state` identify distinct legacy/current deployments without
  printing database content, private keys, or onion addresses.
- Secret-safe database inventory, explicit current/legacy backup selection,
  standalone archive verification, and guarded state reconciliation tooling.
- A real rootless-Docker integration harness using a digest-pinned daemon image.
- MIT licensing in the canonical root `LICENSE` file.

### Changed

- `issues.yml` now targets the next `0.1.0` milestone and records the remaining
  access-control, maintainability, configuration-compatibility, and recovery
  work after the `0.0.3` baseline.
- Alpine and Go base images are pinned to reviewed multi-architecture OCI
  digests while retaining readable image tags (`HG-005`).
- GitHub Actions are pinned to immutable full commit SHAs.
- The vulnerability scanner image is pinned by OCI digest and runs outside the
  workflow action ecosystem.
- The temporary provenance builder uses a digest-pinned BuildKit worker image.
- All release runtimes moved from Debian to Alpine 3.23, reducing every image's
  strict Trivy HIGH/CRITICAL count to zero.
- Release evidence now enforces strict rejection of every HIGH or CRITICAL
  finding, including advisories without an advertised fixed version.

### Fixed

- The rootless-Docker harness stores its disposable inner daemon state in the
  temporary test workspace instead of the outer container layer, preventing
  host Docker storage exhaustion during clean image builds.
- Backup creation no longer mutates ownership or permissions of read-only source
  state, and restore once again verifies the outer checksum sidecar.
- Rootless Docker ownership checks now run in the daemon's container namespace
  rather than comparing misleading host-side remapped numeric IDs.
- Existing root-owned databases are no longer mistaken for fresh deployments.
- Backup freshness detects labeled current/legacy archive names.
- Maintenance image lookup no longer depends on inconsistent Compose image-list
  output.
- Removed a duplicated `HG-003` title and duplicate project-map entry.

### Security

- Both distinct local deployments were encrypted and independently verified
  before the retired one was archived; neither database contained repositories.
- The reconciliation age identity is mode 0600 and must be moved offline.
- Rootless Docker, non-root service users, read-only roots, dropped capabilities,
  and `no-new-privileges` are covered by integration tests.

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

