# HiddenGit development guide

HiddenGit favors small, auditable operational components over a broad configuration framework. Changes should reduce or explicitly justify new state, listeners, dependencies, and migration branches.

## Read first

Before changing behavior, review:

- `ARCHITECTURE.md` for trust boundaries and runtime invariants;
- `SECURITY.md` for release/security requirements;
- `ROADMAP.md` and `issues.yml` for accepted scope;
- `config/schema.json` for the public configuration contract;
- `docs/development/` for test and documentation conventions.

## Local workflow

Run focused checks first, then the aggregate gate:

```sh
./tests/test.sh
./run.sh config check
./run.sh config
./run.sh build
./tests/e2e.sh
```

Additional stateful suites:

```sh
./tests/rootless-docker.sh
./tests/backup-restore.sh
./tests/non-root-migration.sh
```

Tests must use disposable `.env` fixtures, generated credentials, isolated volumes, and bounded network probes. Never use the operator's real `.env`, repositories, database, SSH identities, backups, or Tor identity as a development fixture.

## Configuration changes

A public configuration change is incomplete until all of these agree:

1. `config/schema.json` classification and validation;
2. `env.example` canonical serialization order;
3. `scripts/configctl.py` migration semantics for supported prior releases;
4. `run.sh` preflight behavior;
5. Compose/templates/entrypoints;
6. migration, duplicate/unknown-key, and idempotency tests;
7. operator docs, configuration reference, architecture rationale, changelog, and roadmap.

Prefer removing an invariant over adding synchronization logic. Internal container ports, persistence paths, and Tor targets should remain implementation constants unless a demonstrated platform requirement makes them product intent.

## Network changes

For every new reachable socket, document and test:

- intended caller;
- bind scope;
- transport security;
- authentication/authorization;
- positive reachability from the intended scope;
- negative reachability from unintended scopes;
- backup/migration consequences;
- upstream security advisories relevant to the path.

A Compose diff is not enough. The E2E suite should prove actual sockets and protocol behavior.

## State mutations

Discover/read first. Persistent-state mutation must have an explicit preflight, a recoverable rollback point, bounded failure behavior, and a postflight probe. Database/repository/Tor identity operations are intentionally held to a stronger gate than declarative `.env` migration.

## Dependencies and upstream Soft Serve

A release pin is a reviewed set. When updating Soft Serve:

1. inspect the exact upstream release and security notes;
2. inspect its selected Go module graph;
3. remove or refresh downstream overrides rather than carrying stale versions blindly;
4. rebuild all affected images;
5. regenerate SBOM/provenance/vulnerability evidence;
6. rerun static, integration, and rootless gates.

## Documentation

The public documentation source is in `docs/`. Canonical project records remain at repository root and are copied into the release site by `scripts/prepare-docs-site.sh`. Do not maintain duplicate hand-written changelog/roadmap/security copies inside `docs/`.

A release documentation change should be checked with:

```sh
./scripts/prepare-docs-site.sh .docs-site
./tests/test.sh
```

The GitHub Pages workflow performs the authoritative Jekyll build from the exact published release tag.

## Release discipline

Do not push, tag, publish, or deploy as a side effect of development. Follow `RELEASING.md`, including the version/tag invariant, full CI, release evidence, and release-triggered documentation publication.
