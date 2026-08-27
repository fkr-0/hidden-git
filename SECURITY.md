# Security and operator guidance

HiddenGit reduces accidental exposure, but it is not a substitute for host
hardening, key management, encrypted backups, or a reviewed threat model.

## Check the deployment

Run `./run.sh config check` before Compose and `./run.sh doctor` before starting
or upgrading the stack. Schema validation rejects duplicate, unknown, stale,
malformed, and release-pin-drifted configuration before different consumers can
interpret it differently. `doctor` distinguishes invalid configuration from
risky-but-valid runtime choices and prints a concrete fix for every warning.
Use `./run.sh doctor --strict` in release reviews and automation when warnings
should fail the check.

The audit covers secret permissions, loopback-only publication, immutable
dependency references, administrator-key posture, Docker isolation, explicit
container users, and encrypted-backup freshness.

Use `./run.sh sync-pins` to adopt reviewed release and scanner digests while
preserving deployment intent. It is not a schema migration. For a historical
`.env`, first use `./run.sh config migrate` to preview the secret-safe transform;
`--apply` creates a private rollback copy and atomically converges only the
declarative environment file. Ambiguous inputs fail before mutation, and a
second apply must be a no-op.

`./run.sh fix-permissions` repairs local file and directory modes without
deleting or rewriting runtime content.

## Backups

Generate an age identity with `./run.sh backup-keygen`. Store the identity
offline and put only the displayed public recipient in `BACKUP_RECIPIENT`.
Stop the stack before `./run.sh backup`; this avoids inconsistent SQLite and Git
repository snapshots.

Restore accepts only an empty target. The `preserve` mode restores the Tor onion
identity, while `rotate` deliberately omits it so Tor creates a new address on
the next start. Every archive is authenticated by age, contains a SHA-256 file
manifest, and has an outer checksum sidecar.

## Service users and migration

Soft Serve uses UID/GID `10001:10001`; Tor uses `10002:10002`. Both services
have a read-only root filesystem, all Linux capabilities dropped, and
`no-new-privileges`. Existing state is not silently chowned: back it up first,
then run `./run.sh migrate-users --confirm-existing` while the stack is stopped.

If `doctor` reports legacy runtime directories, use `./run.sh legacy-state`.
It prints only file counts, recency, and same/different identity results. Never
merge or delete distinct databases or onion identities without verified backups.

## Network exposure and known limitations

The default product profile intentionally exposes authenticated SSH only:

- Soft Serve SSH is fixed at internal `:23231`;
- the host maps loopback `LOCAL_SSH_PORT` to internal `23231`;
- Tor maps `ONION_PUBLIC_PORT` to `soft-serve:23231`;
- HTTP and native `git://` are disabled;
- LFS and SSH LFS are disabled;
- stats is bound only to `127.0.0.1:23233` inside the Soft Serve container.

Widening `HOST_BIND_ADDRESS` or enabling an auxiliary protocol is an advanced
security decision, not normal port configuration, and requires its own threat
model and positive/negative reachability tests.

Known limitations:

- The host operator may still choose a rootful Docker daemon. The release test
  suite also validates the complete Compose path against rootless Docker.
- Tor v3 client authorization is not yet managed by the project (`HG-003`). SSH
  public-key authentication remains mandatory at Soft Serve.

Report suspected vulnerabilities privately to the repository maintainer rather
than opening a public issue containing exploit details or secrets.

## Release evidence

`./run.sh evidence` uses a temporary Docker-container BuildKit builder to create
SLSA v1 provenance. A digest-pinned Trivy container generates CycloneDX SBOMs
and timestamped vulnerability reports. Evidence output is ignored by Git and is
uploaded by CI for tagged releases and explicit manual runs.

Release evidence uses strict policy and fails on every HIGH or CRITICAL finding,
whether or not an upstream fixed version is already advertised.

OS packages and embedded Go modules remain included in both the SBOM and
vulnerability reports. Release runtimes use a digest-pinned Alpine base to keep
the package surface small.

Release 0.1.2 targets Soft Serve v0.12.2 so the
application-level security fixes delivered in v0.12.0-v0.12.2 are included. The
explicit Go dependency versions are aligned to the selected v0.12.2 upstream
module graph at review time rather than carrying v0.11.6-era overrides forward
blindly. Future Soft Serve upgrades must repeat that source/module/security
review; dependency overrides are not a substitute for an upstream application
fix.

Every override remains explicitly versioned and recorded in build provenance.

The Soft Serve healthcheck validates the service's managed internal SSH banner
on `127.0.0.1:23231` directly. No SSH client is installed in that runtime image,
reducing package and vulnerability surface without changing authenticated
operator access from the host.

## Documentation publication security

The Pages build job has read-only repository permission and assembles only
tracked public documentation plus `config/schema.json`. It explicitly verifies
that `.env`, `data/`, and `backups/` are absent from the site artifact. Only the
separate deploy job receives `pages:write` and OIDC permission through the
`github-pages` environment, and every Pages action is pinned to a full commit
SHA. The custom-domain repository setting and DNS are separate administrator
actions. The custom Actions-based Pages workflow intentionally carries no
repository `CNAME` file.
