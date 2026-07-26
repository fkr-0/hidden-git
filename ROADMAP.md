# HiddenGit Roadmap

## Status

HiddenGit `0.0.3` is the first release-ready experimental baseline. It provides an authenticated Soft Serve forge over Tor, hardened non-root containers, encrypted backup and restore, state reconciliation, integration tests, and strict release evidence.

The project remains pre-`1.0.0`: interfaces and deployment procedures may still change when a change materially improves security, recovery, or operability.

## Release principles

- Security and recoverability outrank feature count.
- Every release keeps `VERSION`, `env.example`, `README.org`, and `CHANGELOG.md` aligned.
- Backward compatibility is explicit; migrations require rollback evidence.
- No release is tagged while a mandatory static, integration, build, or vulnerability gate fails.
- Remote publication is a separate operator action. A local tag does not imply a push, deployment, registry upload, or hosted release.

## `0.0.3` — release baseline

Status: complete and ready for a local annotated tag.

Delivered:

- loopback-safe Soft Serve listeners and Tor-only remote access;
- required first-boot administrator key;
- stable non-root service UIDs, read-only roots, dropped capabilities, and `no-new-privileges`;
- deterministic static validation and real onion SSH integration testing;
- rootless Docker, ownership migration, and encrypted restore coverage;
- preserve-or-rotate identity recovery semantics;
- digest-pinned build inputs, immutable CI actions, provenance, SBOMs, and a strict HIGH/CRITICAL vulnerability gate;
- architecture, release, SemVer, and roadmap documentation.

## `0.1.0` — private-access lifecycle

Goal: make access enrollment and revocation operable without rebuilding images or manually editing Tor state.

Planned:

- implement Tor v3 client authorization (`HG-003`);
- add commands to enroll, list, rotate, and revoke authorized clients;
- keep client authorization material outside Git and image build contexts;
- document multi-device onboarding and lost-device recovery;
- test authorization, revocation, and rotation through a real onion service;
- define whether client authorization is required, optional, or profile-based for upgraded deployments.

Exit criteria:

- no client credential appears in command output, Git, CI artifacts, or logs;
- revocation is observable in an isolated integration test;
- backup and restore preserve or deliberately rotate authorization state;
- upgrade instructions cover existing `0.0.x` deployments.

## `0.2.0` — maintainable control plane

Goal: reduce operator-CLI coupling without changing the command contract.

Planned:

- split `run.sh` into small sourced libraries for configuration, runtime, connectivity, backup, migration, and release operations (`HG-010`);
- add command-level unit fixtures that do not require Docker;
- define a versioned environment/configuration schema (`HG-011`);
- test upgrades from representative earlier environment files and state modes;
- normalize machine-readable diagnostics while preserving the human-readable UI;
- reduce complexity in the Python evidence and inventory helpers.

Exit criteria:

- no command module exceeds the agreed complexity or size threshold without an explicit exception;
- public commands and exit-status semantics remain compatible;
- schema validation identifies removed, renamed, invalid, and unknown values;
- upgrade tests cover the latest two minor release lines.

## `0.3.0` — recovery operations

Goal: turn backup capability into a routinely verified recovery practice.

Planned:

- add an operator-defined backup freshness objective (`HG-012`);
- create a non-interactive verification command suitable for a timer;
- produce a small machine-readable recovery evidence record;
- document off-host and offline-key storage patterns;
- add a disposable full recovery drill that starts the restored forge and verifies repository and identity expectations;
- define retention and secure retirement guidance for old archives and identities.

Exit criteria:

- a documented drill restores a verified archive into an isolated deployment;
- preserve and rotate modes are both exercised end-to-end;
- recovery evidence contains no secret material;
- stale or unverifiable backups are visible to `doctor --strict`.

## `1.0.0` — stable operator contract

`1.0.0` requires more than feature completion. The following must be true:

- the command-line and configuration compatibility policy is documented;
- supported upgrade and rollback paths are tested;
- client authorization and recovery workflows are operationally complete;
- release artifacts can be independently checked against source, dependency, provenance, and vulnerability claims;
- security reporting and supported-release lifetimes are documented;
- no high-priority issue remains open without explicit risk acceptance;
- architecture and disaster-recovery documentation match tested behavior.

## Deliberate non-goals

Unless the project scope changes explicitly, HiddenGit does not aim to become:

- a public GitHub or GitLab replacement;
- a multi-node high-availability forge;
- a general-purpose Tor gateway;
- a browser-facing public web service;
- an automatic secret escrow or key-custody system.

## Definition of done

A roadmap item is complete only when implementation, documentation, migration impact, tests, security implications, and release notes are addressed. A command that works once on one deployment is not complete.
