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

Configuration schema v1 deliberately changes the abstraction:

```text
operator intent                         implementation policy
────────────────────────────────       ───────────────────────────────
LOCAL_SSH_PORT ───────────────┐
                              ├───────> Soft Serve SSH :23231
ONION_PUBLIC_PORT ── Tor ─────┘

SOFT_SERVE_NAME                         data path /var/lib/soft-serve
HOST_BIND_ADDRESS                       HTTP disabled
optional SSH public URL                 git:// disabled
bootstrap public key                    stats 127.0.0.1:23233
recovery values                         LFS + SSH LFS disabled
```

`config/schema.json` is the machine-readable classification. `scripts/configctl.py` parses data without `source`/`eval`, rejects duplicate and unknown keys, and owns deterministic legacy normalization.

### Migration semantics

`./run.sh config migrate` is preview-only. `--apply`:

1. parses the original file and fails before mutation on ambiguity;
2. renders canonical ordering from `env.example`;
3. creates a mode-0600 timestamped rollback copy only when bytes/mode need change;
4. writes via same-directory temporary file + fsync + atomic replace;
5. fsyncs the parent directory;
6. leaves application state untouched.

A second identical apply must write nothing and create no backup. This is tested.

Legacy custom SSH ports are interpreted as host-facing intent and migrate to `LOCAL_SSH_PORT`. Custom auxiliary listener ports are retired with a warning because HTTP/native Git are no longer part of the secure default. Unsupported changes to internal persistence path or conflicting SSH/Tor targets fail closed.

## Soft Serve update discipline

The hardening work moves from upstream Soft Serve v0.11.6 to v0.12.2 because v0.12.0-v0.12.2 contain application-level security fixes not replaced by the old dependency overrides. The explicit override defaults were aligned to the v0.12.2 selected module graph at review time:

- `charm.land/wish/v2 v2.0.3`
- `github.com/go-git/go-git/v5 v5.19.2`
- `github.com/go-jose/go-jose/v3 v3.0.5`
- `golang.org/x/crypto v0.54.0`
- `golang.org/x/net v0.57.0`

Future updates must re-audit the selected upstream module graph; this list is not a permanent recommendation.

## Default service profile

HiddenGit is SSH-over-Tor, not a generic multi-protocol Soft Serve appliance.

- SSH is enabled on managed `:23231`.
- Local host publication maps `LOCAL_SSH_PORT` to internal `23231` and defaults to loopback.
- Tor maps `ONION_PUBLIC_PORT` to `soft-serve:23231`.
- HTTP is disabled.
- native `git://` is disabled.
- LFS and SSH LFS are disabled.
- stats stays enabled on `127.0.0.1:23233` only.

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
