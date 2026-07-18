# Security and operator guidance

HiddenGit reduces accidental exposure, but it is not a substitute for host
hardening, key management, encrypted backups, or a reviewed threat model.

## Check the deployment

Run `./run.sh doctor` before starting or upgrading the stack. It distinguishes
invalid configuration from risky-but-valid choices and prints a concrete fix
for every warning. Use `./run.sh doctor --strict` in release reviews and
automation when warnings should fail the check.

The audit covers secret permissions, loopback-only publication, immutable
dependency references, administrator-key posture, Docker isolation, explicit
container users, and encrypted-backup freshness.

Use `./run.sh sync-pins` to adopt reviewed release and scanner digests while
preserving deployment-specific ports, keys, names, and URLs.

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

## Known limitations

- The service processes are non-root, but the local Docker daemon may still be
  rootful. A rootless Docker or Podman compatibility pass remains in `HG-001`.
- Tor v3 client authorization is not yet managed by the project (`HG-003`). SSH
  public-key authentication remains mandatory at Soft Serve.
- A project license still requires an explicit maintainer decision (`HG-006`).

Report suspected vulnerabilities privately to the repository maintainer rather
than opening a public issue containing exploit details or secrets.

## Release evidence

`./run.sh evidence` uses a temporary Docker-container BuildKit builder to create
SLSA v1 provenance. A digest-pinned Trivy container generates CycloneDX SBOMs
and timestamped vulnerability reports. Evidence output is ignored by Git and is
uploaded by CI for tagged releases and explicit manual runs.

The default evidence policy fails when Trivy reports a high or critical finding
with an available fixed version. Unfixed high or critical findings are retained
for explicit triage under `HG-008`; set `VULNERABILITY_POLICY_STRICT=1` to reject
those as well.

The scanner excludes Debian's gettext helper JAR directories from Java analysis;
they are not executed by HiddenGit. OS packages and embedded Go modules remain
included in both the SBOM and vulnerability reports.

When the pinned Soft Serve release contains a dependency with an available
security fix, the builder downloads the checksummed upstream module source and
applies only explicitly versioned `go get` overrides before compiling. The
upstream release version remains embedded in the binary and every override is
recorded in build provenance.

The Soft Serve healthcheck validates the service's SSH banner directly. No SSH
client is installed in that runtime image, reducing package and vulnerability
surface without changing authenticated operator access from the host.
