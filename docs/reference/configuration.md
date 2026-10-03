---
title: Configuration reference
---

# Configuration reference

The public configuration contract is versioned by
`HIDDEN_GIT_CONFIG_VERSION`. The machine-readable source is published with each
release as [`assets/config-schema.json`](../../assets/config-schema.json).

## Deployment and bootstrap fields

| Key | Class | Default | Meaning |
|---|---|---:|---|
| `HIDDEN_GIT_CONFIG_VERSION` | schema | `1` | Exact config contract understood by this release. |
| `SOFT_SERVE_NAME` | user intent | `HiddenGit` | Human-facing forge name. |
| `SOFT_SERVE_INITIAL_ADMIN_KEYS` | bootstrap-only | empty | Public SSH key(s) used only to initialize fresh state. Never a private key. |
| `ONION_PUBLIC_PORT` | user intent | `8002` | Port clients address on the onion service. |
| `LOCAL_SSH_PORT` | user intent | `23231` | Loopback host port mapped to managed internal SSH `23231`. |
| `HOST_BIND_ADDRESS` | advanced override | `127.0.0.1` | Host binding for local SSH publication. Wider binding expands attack surface. |
| `SOFT_SERVE_SSH_PUBLIC_URL` | advanced override | empty | Optional clone-hint URL. Empty derives `ssh://localhost:<LOCAL_SSH_PORT>`. |
| `SOFT_SERVE_SSH_USER` | diagnostic | `admin` | Username used by readiness/connectivity helpers. |
| `CHECK_TIMEOUT_SECONDS` | diagnostic | `180` | Overall bounded onion SSH verification allowance. |

## Recovery fields

| Key | Class | Meaning |
|---|---|---|
| `BACKUP_RECIPIENT` | recovery | Public age recipient used to encrypt backups. Safe to store in `.env`; still deployment metadata. |
| `BACKUP_IDENTITY_FILE` | recovery/secret-bearing | Optional local path to the offline age identity for explicit restore/verify commands. Never commit the identity itself. |

## Release-managed fields

These describe the reviewed software/supply-chain set, not deployment topology:

- `HIDDEN_GIT_VERSION`
- `ALPINE_IMAGE`
- `GO_IMAGE`
- `SOFT_SERVE_VERSION`
- `SOFT_SERVE_WISH_VERSION`
- `SOFT_SERVE_GO_GIT_VERSION`
- `SOFT_SERVE_GO_JOSE_VERSION`
- `SOFT_SERVE_X_CRYPTO_VERSION`
- `SOFT_SERVE_X_NET_VERSION`
- `TRIVY_IMAGE`
- `BUILDKIT_IMAGE`
- `DIND_ROOTLESS_IMAGE`

Use `./run.sh sync-pins` to align them with the checked-out release. `config
check` fails when a release-managed value differs, preventing an unreviewed mix
of application source and dependency/image pins.

## Managed internal constants

These are **not** supported `.env` fields:

| Internal fact | Value/policy |
|---|---|
| Soft Serve data path | `/var/lib/soft-serve` |
| Soft Serve SSH | `:23231`, enabled |
| Tor target | `soft-serve:23231` |
| Soft Serve HTTP | `127.0.0.1:23232`, disabled |
| Soft Serve stats | `127.0.0.1:23233`, enabled container-local only |
| Soft Serve native Git | `127.0.0.1:9418`, disabled |
| LFS | disabled; SSH LFS disabled |
| container CI mode | internal image setting |

If a deployment truly needs to change one of these, it is no longer using the
default HiddenGit topology and should carry a reviewed extension/Compose override
with tests.

## Removed legacy fields

`config migrate` recognizes historical keys such as:

- `SOFT_SERVE_SSH_PORT`
- `SOFT_SERVE_HTTP_PORT`
- `SOFT_SERVE_STATS_PORT`
- `SOFT_SERVE_GIT_PORT`
- `ONION_TARGET_PORT`
- `SOFT_SERVE_DATA_PATH`
- `CI`
- HTTP/Git public URL hints

They are accepted **only as migration inputs**, never by `config check` as a
current config. Unknown keys and duplicate assignments fail closed.

## Why public URL is not forced to equal a listener

A public URL describes what clients should use; a listener describes a local
socket. Reverse proxies, Tor, SSH config aliases, and port mappings can make them
intentionally different. HiddenGit derives a safe localhost SSH hint when the
override is empty, but preserves a valid explicit `ssh://` value instead of
inventing a false equality invariant.
