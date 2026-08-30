# HiddenGit developer notes

This file records implementation-specific rationale that is useful when reviewing future changes. User-facing contracts belong in `README.org` and `docs/`; long-term architectural invariants belong in `ARCHITECTURE.md`.

## Configuration hardening lineage

### Historical failure

Pre-0.0.2 deployments could change port values in `.env`/Compose without updating the already-generated persistent Soft Serve configuration. Containers and Tor therefore had enough independent state to disagree about the real listener.

0.0.2 introduced a managed `soft-serve.config.yaml.template`, generated `/run/hidden-git/soft-serve.config.yaml`, and `SOFT_SERVE_CONFIG_LOCATION`. That correctly removed the persistent generated config from runtime authority.

The remaining design still had too many independently configurable representations:

- four Soft Serve internal listener ports;
- one Tor target port required to equal the SSH listener;
- four 1:1 host publications;
- three public URL hints;
- an operator-configurable internal data path and CI mode.

A later forensic pass also demonstrated a parser split-brain: `run.sh`'s first-match environment reader and Docker Compose's last-assignment behavior could disagree when duplicate keys existed. Unknown keys were accepted silently.

### Current resolution

Configuration schema v2 finalizes the abstraction and ownership split:

```text
operator intent                         implementation policy
────────────────────────────────       ───────────────────────────────
LOCAL_SSH_PORT ───────────────┐
                              ├───────> Soft Serve SSH :23231
ONION_PUBLIC_PORT ── Tor ─────┘

SOFT_SERVE_NAME                         data path /var/lib/soft-serve
HOST_BIND_ADDRESS                       HTTP disabled
optional SSH public URL                 git:// disabled
bootstrap public key                    stats disabled
recovery values                         LFS + SSH LFS disabled
```

`config/schema.json` is the machine-readable classification. `scripts/configctl.py` parses both operator config and tracked `config/release.env` without `source`/`eval`, rejects duplicate and unknown keys, and owns deterministic legacy normalization. Release pins are no longer operator `.env` values.

### Migration semantics

`./run.sh config migrate` is preview-only. `--apply`:

1. parses the original file and fails before mutation on ambiguity;
2. renders canonical ordering from `env.example`;
3. creates a mode-0600 timestamped rollback copy only when bytes/mode need change;
4. writes via same-directory temporary file + fsync + atomic replace;
5. fsyncs the parent directory;
6. leaves application state untouched.

A second identical apply must write nothing and create no backup. This is tested.

Legacy custom SSH ports are interpreted as host-facing intent and migrate to `LOCAL_SSH_PORT`. Default historical auxiliary topology retires automatically. A non-default HTTP/Git/stats port or public URL is `BLOCKED_LOSSY`: ordinary apply writes nothing and creates no backup; only `--accept-retired-auxiliary-topology` acknowledges that specific retirement. Unsupported persistence changes, duplicate/unknown input, old/new SSH conflicts, mismatched SSH/Tor targets, and future schema versions still fail closed.

## Soft Serve update discipline

The hardening work stays on upstream Soft Serve v0.12.2. The five historical downstream Go override settings exactly matched the selected v0.12.2 graph, so schema v2 removes them and the Dockerfile builds that reviewed upstream `go.mod`/`go.sum` graph directly with `go mod verify`. A future override is an exception requiring a separately reviewed reason, advisory/removal condition, and machine comparison; no exception machinery is carried while no override exists.

## Default service profile

HiddenGit is SSH-over-Tor, not a generic multi-protocol Soft Serve appliance.

- SSH is enabled on managed `:23231`.
- Local host publication maps `LOCAL_SSH_PORT` to internal `23231` and defaults to loopback.
- Tor maps `ONION_PUBLIC_PORT` to `soft-serve:23231`.
- HTTP is disabled.
- native `git://` is disabled.
- LFS and SSH LFS are disabled.
- stats is disabled and opens no `23233` socket, even inside the Soft Serve container.

Soft Serve v0.12.2 still treats configured `initial_admin_keys` as server-admin
authority after DB creation. HiddenGit therefore unsets
`SOFT_SERVE_INITIAL_ADMIN_KEYS` in the process environment before exec whenever
`soft-serve.db` already exists. The E2E test persists a non-admin user, places
that user's key into the stale bootstrap field, recreates Soft Serve, and proves
global `settings`/`user` operations remain unauthorized.

An extension that widens this profile must carry explicit threat-model, migration, documentation, positive socket tests, and negative reachability tests.

## Stale config regression

The E2E harness seeds an old persistent `config.yaml` containing conflicting `2999x` listeners before first startup. It then asserts the generated `/run` config, real sockets, Docker host publication, and Tor target all follow the managed current topology. A force-recreate must generate the same runtime config hash.

This test exists specifically to prevent regression to the original persistent-config bug.

## Documentation release design

`hiddengit.fkr.dev` is intended to be a released-source site, not a main-branch snapshot.

`.github/workflows/pages.yml` runs on `release.published`, checks out the exact release tag, verifies it equals `v<VERSION>`, runs static/docs checks, prepares a staging tree, builds with GitHub Pages/Jekyll, and deploys through the `github-pages` environment.

`scripts/prepare-docs-site.sh` republishes canonical root records into `/project/` in the site artifact and includes the public config schema. It never copies `.env`, state, backups, or release evidence.

The custom domain is configured through GitHub Pages settings/API and DNS. A
repository `CNAME` file is intentionally absent because custom Actions-based
Pages deployments ignore it.
