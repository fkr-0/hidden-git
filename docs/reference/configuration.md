---
title: Configuration reference
---

# Configuration reference

The public operator configuration contract is versioned by
`HIDDEN_GIT_CONFIG_VERSION`. The machine-readable source is published with each
release as [`assets/config-schema.json`](../../assets/config-schema.json).
Schema v2 separates operator intent from tracked release/build metadata.

## Value syntax and parser boundary

`scripts/configctl.py` validates the operator file before Docker Compose is
allowed to consume it. Quoted `#` and `=` characters remain literal, and an
unquoted `#` begins an inline comment only after whitespace. To prevent Docker
Compose from assigning a second meaning to already-validated text, current
operator values containing `$` are rejected instead of being interpolated.
Double-quoted values support only `\"` and `\\` escapes; write a literal
control-like sequence such as `\n` by escaping its backslash (`\\n`) or by
using single quotes where suitable. `SOFT_SERVE_SSH_PUBLIC_URL` additionally
rejects whitespace, double quotes, and backslashes.

These restrictions are intentionally fail-closed: `./run.sh config check`
reports them before any container is started. Accepted presentation values such
as forge names are YAML-escaped by the Soft Serve entrypoint before being placed
in the generated managed configuration.

## Deployment and bootstrap fields

| Key | Class | Default | Meaning |
|---|---|---:|---|
| `HIDDEN_GIT_CONFIG_VERSION` | schema | `2` | Exact operator config contract understood by this release. |
| `SOFT_SERVE_NAME` | user intent | `HiddenGit` | Human-facing forge name. |
| `SOFT_SERVE_INITIAL_ADMIN_KEYS` | bootstrap-only | empty | Public SSH key(s) required to initialize fresh state. On an existing DB HiddenGit suppresses this variable before executing Soft Serve; clear it from `.env` after bootstrap. |
| `ONION_PUBLIC_PORT` | user intent | `8002` | Backward-compatible onion SSH virtual port. Mandatory port `2022` is exposed on the same identity independently; equal values collapse to one mapping. |
| `LOCAL_SSH_PORT` | user intent | `23231` | Host port mapped to managed internal SSH `23231`. |
| `HOST_BIND_ADDRESS` | advanced override | `127.0.0.1` | Host binding for local SSH publication. Wider binding expands attack surface. |
| `SOFT_SERVE_SSH_PUBLIC_URL` | advanced override | empty | Clone metadata only. Empty derives `ssh://localhost:<LOCAL_SSH_PORT>`; any valid explicit `ssh://` URL is preserved independently of routing ports. |
| `SOFT_SERVE_SSH_USER` | diagnostic | `admin` | Username used by readiness/connectivity helpers. |
| `CHECK_TIMEOUT_SECONDS` | diagnostic | `180` | Overall bounded onion SSH verification allowance. |

## Recovery fields

| Key | Class | Meaning |
|---|---|---|
| `BACKUP_RECIPIENT` | recovery | Public age recipient used to encrypt backups. Safe to store in `.env`; still deployment metadata. |

Recovery identities are not current declarative config. Pass the offline identity
path explicitly to `verify-backup` and `restore`. Historical
`BACKUP_IDENTITY_FILE` is recognized only so migration can remove it.

## Tracked release metadata

`config/release.env` is the canonical non-secret source for exactly these
release/build inputs:

- `ALPINE_IMAGE`
- `GO_IMAGE`
- `SOFT_SERVE_VERSION`
- `ONION_SSH_PORT` (`2022`, mandatory same-identity onion SSH policy)
- `TRIVY_IMAGE`
- `BUILDKIT_IMAGE`
- `DIND_ROOTLESS_IMAGE`

Image references are immutable digest pins and Soft Serve remains `v0.12.2`.
`scripts/configctl.py` validates and reads this file through the same parser
boundary as operator config. A current `.env` containing any release-owned key is
invalid; operator values cannot override the tracked release.

`VERSION` is the sole HiddenGit project-version authority. There is no
`HIDDEN_GIT_VERSION` in schema v2.

The five historical downstream Soft Serve dependency override variables are
removed. The Dockerfile builds the reviewed upstream v0.12.2 `go.mod`/`go.sum`
graph directly and runs `go mod verify`.

## Managed internal constants

These are **not** supported `.env` fields:

| Internal fact | Value/policy |
|---|---|
| Soft Serve data path | `/var/lib/soft-serve` |
| Soft Serve SSH | `:23231`, enabled |
| healthcheck target | `127.0.0.1:23231` |
| Tor target | `soft-serve:23231` |
| Soft Serve HTTP | `127.0.0.1:23232`, disabled |
| Soft Serve stats | disabled; inert template address `127.0.0.1:23233` |
| Soft Serve native Git | `127.0.0.1:9418`, disabled |
| LFS | disabled; SSH LFS disabled |
| container CI mode | internal image setting |

If a deployment truly needs to change one of these, it is no longer using the
default HiddenGit topology and should carry a reviewed extension/Compose override
with tests.

## Legacy migration states

`config migrate` recognizes historical fields only as migration inputs. Its
state machine is:

```text
parse
 |
 +-- duplicate/malformed ------------------------------> INVALID / no write
 |
 +-- syntactically valid
      |
      +-- current v2 ----------------------------------> CURRENT / no-op
      |
      +-- known v1/legacy
      |     |
      |     +-- deterministic -------------------------> MIGRATABLE
      |     |
      |     +-- non-default retired auxiliary --------> BLOCKED_LOSSY
      |                                                   |
      |                               explicit acknowledgement?
      |                                   no -> no write
      |                                   yes -> MIGRATABLE_ACK
      |
      +-- unknown/conflicting/unsupported/future ------> INVALID/UNSUPPORTED
```

The retired auxiliary fields are the historical HTTP, stats, native-Git ports
and HTTP/Git public URLs. Their default values retire automatically. A non-default
value is evidence of operator topology, so ordinary `--apply` creates no backup
and writes no bytes. `--accept-retired-auxiliary-topology` acknowledges only
that retirement; it cannot bypass duplicate/unknown/malformed input, SSH alias
conflicts, mismatched old SSH/Tor targets, unsupported data-path changes, or a
future schema.

Migration recognizes old release pins, `HIDDEN_GIT_VERSION`, historical
`BACKUP_IDENTITY_FILE`, `SOFT_SERVE_*_PORT`, `ONION_TARGET_PORT`,
`SOFT_SERVE_DATA_PATH`, and `CI` only to validate/drop/map them deterministically.

## Serializer behavior

Legacy migration renders canonical ordering and comments from `env.example`.
Semantic values are preserved according to migration policy, but original
ordering/comments are intentionally not preserved. An apply that rewrites
configuration bytes creates a mode-0600 same-directory rollback copy, fsyncs,
and atomically replaces the config. If only overly broad file permissions need
repair, migration restricts the existing file to mode 0600 without creating a
redundant byte rollback. An immediate second apply is byte-identical and creates
no backup.

## Why public URL is not forced to equal a listener

A public URL describes what clients should use; a listener describes a local
socket. Reverse proxies, Tor, SSH config aliases, and port mappings can make them
intentionally different. HiddenGit derives a safe localhost SSH hint when the
override is empty, but preserves a valid explicit `ssh://` value instead of
inventing an equality invariant among local, onion, internal, and advertised
ports.
