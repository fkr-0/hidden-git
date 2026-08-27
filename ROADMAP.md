# HiddenGit Roadmap

## Status

HiddenGit `0.1.0` is the current release line. It adds schema-v1 configuration convergence, a smaller SSH-only network surface, Soft Serve v0.12.2 security updates, stale-config E2E protection, and release-bound documentation for `hiddengit.fkr.dev` on top of the `0.0.3` hardening baseline.

The project remains pre-`1.0.0`: interfaces and deployment procedures may still change when a change materially improves security, recovery, or operability.

## Release principles

- Security and recoverability outrank feature count.
- Every release keeps `VERSION`, `env.example`, `README.org`, and `CHANGELOG.md` aligned.
- Backward compatibility is explicit; migrations require rollback evidence.
- No release is tagged while a mandatory static, integration, build, or vulnerability gate fails.
- Remote publication is a separate operator action. A local tag does not imply a push, deployment, registry upload, hosted release, or Pages deployment.
- Public documentation is a release artifact: a published GitHub Release triggers a build from its exact tag, not from mutable `main`.

## `0.0.3` — release baseline

Status: released 2026-07-26.

Delivered:

- loopback-safe Soft Serve listeners and Tor-only remote access;
- required first-boot administrator key;
- stable non-root service UIDs, read-only roots, dropped capabilities, and `no-new-privileges`;
- deterministic static validation and real onion SSH integration testing;
- rootless Docker, ownership migration, and encrypted restore coverage;
- preserve-or-rotate identity recovery semantics;
- digest-pinned build inputs, immutable CI actions, provenance, SBOMs, and a strict HIGH/CRITICAL vulnerability gate;
- architecture, release, SemVer, and roadmap documentation.

## `0.1.0` — configuration contract and release documentation

Status: release process requires full local qualification and green tag-triggered CI before hosted publication.

Delivered:

- machine-readable `HIDDEN_GIT_CONFIG_VERSION=1` contract distinguishing deployment intent, bootstrap-only inputs, release-managed pins, advanced overrides, recovery fields, internal constants, and migration-only legacy keys (`HG-011`);
- Docker-free `config check`, secret-safe `config migrate`, atomic mode-0600 rollback, and second-apply byte/no-backup idempotency;
- duplicate/unknown-key rejection before Compose, closing the historical first-reader/last-reader split-brain class;
- fixed internal SSH `23231`, derived Tor target, decoupled `LOCAL_SSH_PORT`, container-loopback stats, and no default host publication for auxiliary protocols;
- default HTTP, native `git://`, LFS, and SSH-LFS disabled until a reviewed extension establishes a real requirement and threat model;
- Soft Serve v0.12.2 plus reviewed dependency versions aligned to its selected upstream graph;
- E2E regression that seeds a conflicting historical persistent Soft Serve config and proves generated config, actual sockets, Docker publication, and Tor mapping remain authoritative across recreate;
- comprehensive tutorials, how-to guides, reference, explanation, extension, development, changelog/roadmap/security/release records, and custom-domain Pages setup;
- release-triggered GitHub Pages workflow for `hiddengit.fkr.dev` that verifies `release.tag_name == v<VERSION>`, builds from the exact tag, and restricts Pages write/OIDC permission to the deploy job.

Release procedure gates:

- full build, backup/restore, non-root migration, E2E, and rootless-Docker suites;
- strict release evidence/SBOM/provenance/vulnerability policy for the v0.12.2 image set;
- one-time repository Pages source/custom-domain configuration plus DNS/certificate validation before the first public docs release.

## `0.2.0` — private-access lifecycle

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

## `0.3.0` — maintainable control plane

Goal: reduce operator-CLI coupling without changing the command contract.

Planned:

- split `run.sh` into small sourced libraries for runtime, connectivity, backup, migration, and release operations (`HG-010`), preserving the existing schema/configctl contract;
- expand command-level Docker-free fixtures beyond the config engine;
- extend representative upgrade coverage to each subsequently supported schema/minor line;
- normalize machine-readable diagnostics while preserving the human-readable UI;
- reduce complexity in the Python evidence and inventory helpers.

Exit criteria:

- no command module exceeds the agreed complexity or size threshold without an explicit exception;
- public commands and exit-status semantics remain compatible;
- the already-delivered schema validation/migration API remains compatible or ships an explicit next schema migration;
- upgrade tests cover the latest two minor release lines.

## `0.4.0` — recovery operations

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
