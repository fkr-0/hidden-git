---
title: Command reference
---

# Command reference

`run.sh` is the supported operator entry point.

| Command | Mutates? | Requires Docker? | Purpose |
|---|---|---|---|
| `init` | yes, local files | no | Create private `.env` and state directories; refuses overwrite. |
| `config check` | no | no | Validate exact v2 operator schema plus tracked release metadata, duplicates, types, and mode. |
| `config migrate` | no | no | Secret-safe preview of legacy-to-current config convergence. |
| `config migrate --apply` | `.env` only | no | Private rollback + atomic canonical rewrite; idempotent. |
| `config migrate --apply --accept-retired-auxiliary-topology` | `.env` only | no | Acknowledge retirement of non-default legacy HTTP/Git/stats topology; cannot bypass any other invalid state. |
| `config` / `config render` | no | yes | Schema-check then render full Compose config. |
| `doctor [--strict]` | creates missing dirs; otherwise audit | yes | Operational posture audit; strict turns warnings into failure. |
| `up` | yes | yes | Build/start/wait/verify complete onion SSH path. |
| `down` | containers/network | yes | Stop stack without deleting bind-mounted application state. |
| `restart` | containers/network | yes | `down` then guarded `up`. |
| `status` | no | yes | Compose state and local/onion connection hints. |
| `logs` | no | yes | Follow Compose logs. |
| `test` | no application mutation | yes | Bounded live onion SSH connectivity test. |
| `build` | images/cache | yes | Build release images using current reviewed config. |
| `sync-pins` | no | no Docker execution | Compatibility validation of tracked `config/release.env`; never writes `.env`. |
| `fix-permissions` | modes | yes | Repair supported private modes. |
| `migrate-users` | ownership | yes | Stable service UID migration; existing state requires confirmation. |
| `backup-keygen` | recovery key files | yes | Create age identity + recipient; move identity offline. |
| `backup` | backup artifacts | yes | Stopped-state encrypted backup of current deployment. |
| `backup-state` | backup artifacts | yes | Explicit current/legacy layout backup. |
| `verify-backup <archive> <identity>` | no application state | yes | Decrypt and validate archive/manifest using an explicit identity path; no `.env` fallback. |
| `restore <archive> <identity> [preserve|rotate]` | persistent state | yes | Restore only into empty target with explicit recovery identity, preserve or rotate onion identity. |
| `legacy-state` | no | yes | Secret-safe comparison of old/current layouts. |
| `state-inventory` | no | yes | Secret-safe repository/user metadata from stopped DB copies. |
| `reconcile-state` | destructive archival/migration | yes | Guarded, backed-up legacy-state retirement. |
| `autoboot install` | user systemd unit/timer | yes | After an already-qualified running stack, install and enable boot/periodic reconciliation; requires login linger. |
| `autoboot status` | no | no | Read timer enable/active state, managed-unit freshness, installed paths, and recorded/current Docker-context agreement. |
| `autoboot remove` | user systemd unit/timer | no container mutation | Disable/remove autoboot without stopping HiddenGit containers. |
| `autoboot reconcile` | containers only when stopped/missing | yes | Validate config, no-op when both services run, otherwise `compose up --no-build --wait`. |
| `evidence` | generated evidence/images/cache | yes | Provenance, SBOM and vulnerability policy artifacts. |
| `issues` | no | no | Print tracked project issue status. |
| `version` | no | no | Print canonical `VERSION`. |
| `help` | no | no | Show command contract. |

## Exit behavior

Commands fail non-zero on unmet invariants. Do not wrap release or recovery
commands in `|| true`. A failed safety check is part of the operator contract.
