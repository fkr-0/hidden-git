# Security and operator guidance

HiddenGit reduces accidental exposure, but it is not a substitute for host
hardening, key management, encrypted backups, or a reviewed threat model.

## Check the deployment

Run `./run.sh config check` before Compose and `./run.sh doctor` before starting
or upgrading the stack. Schema validation rejects duplicate, unknown, stale,
malformed, and operator-owned release-pin configuration before different consumers can
interpret it differently; tracked `config/release.env` is validated through the
same parser boundary. `doctor` distinguishes invalid configuration from
risky-but-valid runtime choices and prints a concrete fix for every warning.
Use `./run.sh doctor --strict` in release reviews and automation when warnings
should fail the check.

The audit covers secret permissions, loopback-only publication, immutable
dependency references, administrator-key posture, Docker isolation, explicit
container users, and encrypted-backup freshness.

`./run.sh sync-pins` is retained only as a non-mutating compatibility check for
the tracked release metadata. For a historical `.env`, use `./run.sh config
migrate` to preview the secret-safe transform;
`--apply` creates a private rollback copy and atomically converges only the
declarative environment file. Ambiguous inputs fail before mutation, and a
second apply must be a no-op.

Non-default legacy HTTP/Git/stats ports or public URLs are treated as evidence
of intentional topology and reported as `BLOCKED_LOSSY`. Ordinary `--apply`
creates no rollback copy and writes no bytes. Preserve needed behavior in a
separately reviewed extension, or explicitly acknowledge only that retirement
with `--accept-retired-auxiliary-topology`.

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
- Tor always maps mandatory virtual SSH port `2022` to `soft-serve:23231` on the
  persisted hidden-service identity, and maps `ONION_PUBLIC_PORT` to that same
  backend only when it is distinct;
- HTTP and native `git://` are disabled;
- LFS and SSH LFS are disabled;
- stats is disabled entirely and opens no `23233` socket, including inside the Soft Serve container.

`SOFT_SERVE_INITIAL_ADMIN_KEYS` is a first-boot mechanism, not durable policy.
Soft Serve v0.12.2 still consults configured initial admin keys for server-admin
authorization after a DB exists, so HiddenGit unsets the variable before
executing Soft Serve whenever `soft-serve.db` already exists. `doctor` warns if
an established `.env` still carries a value; clear it declaratively. Runtime
suppression is the fail-safe and does not modify DB users or admin flags.

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

Release 0.1.3 targets Soft Serve v0.12.2 so the
application-level security fixes delivered in v0.12.0-v0.12.2 are included. The
five historical downstream dependency overrides matched the selected v0.12.2
module graph exactly and have therefore been removed. The build consumes the
reviewed upstream `go.mod`/`go.sum` graph directly and runs `go mod verify`.
Future Soft Serve upgrades must repeat the source/module/security review; a
future downstream override would require its own tracked rationale and removal
condition rather than becoming an operator `.env` knob.

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
