# HiddenGit Architecture

## Purpose

HiddenGit is a small self-hosted Git forge that exposes Soft Serve's SSH interface through a Tor v3 onion service. Release `0.1.2` targets a narrow operating model:

- one Docker Compose deployment;
- one persistent Soft Serve state tree;
- one persistent Tor identity;
- SSH public-key authentication at the forge;
- no direct public-network listener;
- explicit encrypted backup and restore.

Security policy lives in `SECURITY.md`. Planned work lives in `ROADMAP.md` and `issues.yml`.

## System context

```text
Git/SSH client
      |
      | onion SSH connection
      v
Tor network
      |
      v
+---------------- HiddenGit host ----------------+
|                                                  |
|  Tor service ---- private Compose network ----+  |
|       |                                        |  |
|  data/tor/                                     v  |
|                                         Soft Serve|
|                                               |  |
|                                      data/soft-serve/
|                                                  |
|  Operator CLI -> Docker Compose -> services      |
|       |
|       +-> maintenance container -> backups/      |
+--------------------------------------------------+
```

The onion address keeps the host's public location out of clone URLs, but it is not an authorization mechanism. Soft Serve repository permissions and SSH-key authentication remain authoritative.

## Runtime components

### Operator CLI

`run.sh` is the public control surface. It validates the versioned local configuration contract before Compose and dispatches lifecycle, diagnostics, migration, backup, restore, and release-evidence operations. `scripts/configctl.py` owns schema parsing and deterministic declarative migration; it never evaluates `.env` as shell code.

The CLI fails closed for duplicate/unknown/stale configuration, first boot, destructive restoration, state reconciliation, and release evidence. Complex state operations are delegated to scripts under `scripts/`.

### Soft Serve

The `soft-serve` container provides the Git forge and SSH UI.

- Stable UID/GID `10001:10001`.
- Read-only root filesystem.
- All Linux capabilities dropped.
- `no-new-privileges` enabled.
- Repositories, SQLite state, and SSH identities persisted under `data/soft-serve/`.
- Managed SSH listener fixed at `:23231`; `LOCAL_SSH_PORT` controls only the loopback-facing host mapping.
- HTTP, native `git://`, LFS, and SSH LFS disabled in the default profile.
- Statistics bound to `127.0.0.1:23233` inside the container and not host-published.
- `/run/hidden-git/soft-serve.config.yaml` is regenerated on every start and explicitly selected with `SOFT_SERVE_CONFIG_LOCATION`, so stale persistent config cannot regain authority.

### Tor

The `tor` container publishes the Soft Serve SSH listener as a Tor v3 hidden service.

- Stable UID/GID `10002:10002`.
- Read-only root filesystem.
- All Linux capabilities dropped.
- `no-new-privileges` enabled.
- Tor state and the onion identity persisted under `data/tor/`.
- Operator chooses only `ONION_PUBLIC_PORT`; the internal target is the managed constant `soft-serve:23231`.
- Starts only after Soft Serve reports healthy.
- Reports healthy only after control-port bootstrap reaches 100% and the onion hostname exists.

### Maintenance service

The profile-gated `maintenance` container performs administrative operations without network access:

- permission repair and stable-UID migration;
- age key generation;
- encrypted backup creation and verification;
- preserve-identity or rotate-identity restore;
- secret-safe state inspection and reconciliation.

Backup and restore require the application services to be stopped so database and repository state form one consistent snapshot.

### Tor checker

The one-shot checker joins Tor's network namespace and verifies authenticated SSH through the onion service. Every connection attempt and the overall probe have finite timeouts.

### Release evidence

`scripts/release-evidence.sh` builds OCI archives with provenance, extracts SLSA v1 metadata, generates CycloneDX SBOMs, and applies a strict vulnerability policy. Any HIGH or CRITICAL finding fails the release gate.

### Release documentation

`docs/` contains tutorials, how-to guides, reference, explanation, extension guidance, and development documentation. `scripts/prepare-docs-site.sh` assembles those pages with canonical root project records and the public config schema. `.github/workflows/pages.yml` deploys only after a GitHub Release is published: it checks out the exact release tag, verifies `v<VERSION>`, rebuilds the site, and publishes through the `github-pages` environment to the configured `hiddengit.fkr.dev` custom domain.

## Main flows

### First boot

1. `./run.sh init` creates a private schema-v1 `.env` and runtime directories.
2. The operator supplies at least one complete administrator SSH public key.
3. `./run.sh config check` rejects duplicate, unknown, stale, malformed, or release-pin-drifted configuration before Docker is needed.
4. `./run.sh doctor` validates configuration, permissions, pinning, and runtime posture.
5. `./run.sh up` migrates only empty fresh state ownership, starts Soft Serve, waits for fixed internal SSH `23231`, starts Tor, and verifies onion SSH reachability.

Existing state is never recursively re-owned during normal startup. A stopped, explicit migration command is required.

### Git access

1. A client opens SSH to the onion hostname and `ONION_PUBLIC_PORT`.
2. Tor maps that virtual port to the fixed `soft-serve:23231` SSH endpoint.
3. Soft Serve authenticates the SSH key and applies forge/repository authorization.
4. Git protocol data remains inside the Tor circuit until it reaches the HiddenGit host.
5. Local operator SSH independently maps `HOST_BIND_ADDRESS:LOCAL_SSH_PORT` to the same internal `23231`; it does not alter Tor or Soft Serve topology.

### Backup

1. The operator stops the stack.
2. The maintenance container archives the selected state layout.
3. A per-file SHA-256 manifest is embedded in the archive.
4. The archive is encrypted with an age recipient.
5. A checksum sidecar covers the encrypted artifact.
6. Verification decrypts and validates both the outer checksum and internal manifest without restoring state.

The matching age identity is an offline recovery credential and must not remain inside this repository.

### Restore

Restore is allowed only into empty target directories. The operator must choose one identity policy:

- `preserve`: restore the prior Tor identity;
- `rotate`: restore application state and deliberately create a new Tor identity.

The choice is explicit because accidental identity replacement permanently changes the service address.

## Trust boundaries

| Boundary | Trusted side | Less-trusted side | Primary control |
|---|---|---|---|
| Network to onion service | Tor service | remote network and clients | Tor v3 transport, finite probes |
| Tor to forge | private Compose network | Tor-facing input | single mapped SSH target |
| Forge authentication | Soft Serve authorization DB | presented client keys | SSH public-key authentication |
| Host to containers | reviewed Compose and images | container workload | non-root users, read-only roots, dropped capabilities |
| Runtime state to Git | ignored private directories | repository history/build context | `.gitignore`, `.dockerignore`, hygiene tests |
| Backup to recovery key | offline age identity | backup storage | authenticated encryption and checksums |
| Configuration to Compose/runtime | schema-v1 validated intent | malformed/legacy `.env` input | duplicate/unknown rejection, explicit migration, fixed internal topology |
| Source to release artifact | pinned build inputs | registries and upstream source | digest pinning, SBOM, provenance, vulnerability gate |
| Release source to public docs | exact published release tag | mutable repository branches | tag/version verification, pinned Pages actions, `github-pages` environment |

## Persistent state

| Path | Owner | Contents | Recovery role |
|---|---:|---|---|
| `data/soft-serve/` | `10001:10001` | repositories, SQLite DB, SSH keys | required |
| `data/tor/` | `10002:10002` | Tor state and onion identity | required |
| `backups/` | host operator | encrypted archives and sidecars | copy off-host |
| `retired-state/` | host operator | explicitly archived legacy deployment | retain until verified retirement |

The Soft Serve and Tor trees form one logical recovery unit. Backing up only one can separate application state from its expected onion identity.

## Architectural invariants

Release checks enforce or document these invariants:

1. `VERSION` is the canonical project version.
2. `VERSION`, `env.example`, the README subtitle, and `CHANGELOG.md` agree.
3. Release tags use the exact annotated form `v<SemVer>`.
4. Runtime state, local environment files, private keys, databases, backups, and generated evidence are not tracked or copied into image contexts.
5. Fresh initialization requires an administrator public key.
6. The default host publication is loopback SSH only; internal SSH is fixed at `23231`.
7. Tor always targets `soft-serve:23231`; `ONION_TARGET_PORT` is not operator configuration.
8. HTTP, native `git://`, LFS, and SSH LFS are disabled unless a reviewed extension changes the product profile.
9. Configuration is versioned and rejects duplicates, unknown keys, unsupported legacy keys, and drifted release pins before Compose.
10. Declarative config migration is preview-first, atomic, rollback-backed, and second-apply idempotent; it never mutates application state.
11. Connectivity checks always terminate.
12. Existing non-empty state is never silently re-owned or overwritten.
13. Restore requires an empty destination and an explicit identity policy.
14. Release images and workflow actions use immutable references.
15. HIGH or CRITICAL release-image vulnerabilities fail the release gate.
16. Public documentation is assembled from and deployed for the exact published release tag.

## Failure and recovery model

| Failure | Expected behavior | Recovery |
|---|---|---|
| Invalid/current-schema `.env` | startup fails before Compose/service mutation | fix current values; for known legacy input preview `config migrate` |
| Duplicate/unknown `.env` key | schema validation fails before Compose can choose different semantics | remove typo/duplicate or recover from an unambiguous rollback copy |
| Deterministic legacy `.env` | current check refuses it | preview `config migrate`, then explicitly apply and verify second-pass no-op |
| Missing first admin key | fresh startup refuses initialization | add a complete SSH public key |
| Soft Serve unhealthy | Tor remains blocked | inspect logs and local SSH listener |
| Tor bootstrap timeout | command exits with diagnostics | inspect Tor logs/network reachability |
| Onion SSH timeout | finite failure | inspect status, bootstrap, and key/user settings |
| Two state layouts exist | no automatic merge or deletion | inventory, back up both, reconcile explicitly |
| Incorrect state ownership | no implicit recursive chown | stop, back up, run `migrate-users` |
| Backup corruption | verification fails before restore | use another verified archive |
| Non-empty restore target | restore refuses overwrite | choose an empty destination |
| Vulnerability gate failure | evidence command fails | update/remove the dependency and regenerate evidence |

## Architecture decisions

### Docker Compose rather than a general orchestrator

The project targets a small single-host deployment. Compose keeps deployment state inspectable and avoids adding a cluster control plane. This design does not provide high availability.

### Soft Serve authorization remains authoritative

Tor provides location privacy and routing, not repository authorization. Tor client authorization is planned as defense in depth, not as a replacement for Soft Serve permissions.

### Stable numeric service users

Stable UIDs make ownership auditable across rootful and rootless Docker. The trade-off is an explicit migration step for older state.

### Stopped-state backup

The release favors a simple, verifiable consistent snapshot over online-backup complexity. Scheduled or near-zero-downtime backups require a documented database consistency strategy.

### One operator entry point

`run.sh` centralizes guardrails and keeps operations discoverable. Its size is now the main maintainability debt; decomposition must preserve the public command and failure contracts.

## Necessary next additions

The architecture is release-ready for an experimental single-host service, but not yet a high-assurance or stable `1.0.0` platform. The highest-value additions are:

1. Tor v3 client authorization lifecycle (`HG-003`).
2. Modularization of the operator CLI while preserving commands and failure semantics (`HG-010`).
3. Repeatable off-host recovery drills with freshness objectives and secret-safe evidence (`HG-012`).
4. A documented support and security-response policy before `1.0.0`.
5. Reviewed extension profiles only where a real need justifies expanding the SSH-only default surface.

The versioned configuration schema, explicit migration/rollback contract, representative legacy fixtures, and release-bound documentation pipeline are now implemented (`HG-011`).

See `ROADMAP.md` for sequencing and release criteria.
