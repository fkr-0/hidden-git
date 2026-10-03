---
title: Command reference
---

# Command reference

`run.sh` is the supported operator entry point.

| Command | Mutates? | Requires Docker? | Purpose |
|---|---|---|---|
| `init` | yes, local files | no | Create private `.env` and state directories; refuses overwrite. |
| `config check` | no | no | Validate exact schema, keys, types, pins, duplicates, and mode. |
| `config migrate` | no | no | Secret-safe preview of legacy-to-current config convergence. |
| `config migrate --apply` | `.env` only | no | Private rollback + atomic canonical rewrite; idempotent. |
| `config` / `config render` | no | yes | Schema-check then render full Compose config. |
| `doctor [--strict]` | creates missing dirs; otherwise audit | yes | Operational posture audit; strict turns warnings into failure. |
| `up` | yes | yes | Build/start/wait/verify complete onion SSH path. |
| `down` | containers/network | yes | Stop stack without deleting bind-mounted application state. |
| `restart` | containers/network | yes | `down` then guarded `up`. |
| `status` | no | yes | Compose state and local/onion connection hints. |
| `logs` | no | yes | Follow Compose logs. |
| `test` | no application mutation | yes | Bounded live onion SSH connectivity test. |
| `build` | images/cache | yes | Build release images using current reviewed config. |
| `sync-pins` | `.env` | no Docker execution | Backup `.env`, replace release-managed values. |
| `fix-permissions` | modes | yes | Repair supported private modes. |
| `migrate-users` | ownership | yes | Stable service UID migration; existing state requires confirmation. |
| `backup-keygen` | recovery key files | yes | Create age identity + recipient; move identity offline. |
| `backup` | backup artifacts | yes | Stopped-state encrypted backup of current deployment. |
| `backup-state` | backup artifacts | yes | Explicit current/legacy layout backup. |
| `verify-backup` | no application state | yes | Decrypt and validate archive/manifest without restoring. |
| `restore` | persistent state | yes | Restore only into empty target, preserve or rotate onion identity. |
| `legacy-state` | no | yes | Secret-safe comparison of old/current layouts. |
| `state-inventory` | no | yes | Secret-safe repository/user metadata from stopped DB copies. |
| `reconcile-state` | destructive archival/migration | yes | Guarded, backed-up legacy-state retirement. |
| `evidence` | generated evidence/images/cache | yes | Provenance, SBOM and vulnerability policy artifacts. |
| `issues` | no | no | Print tracked project issue status. |
| `version` | no | no | Print canonical `VERSION`. |
| `help` | no | no | Show command contract. |

## Exit behavior

Commands fail non-zero on unmet invariants. Do not wrap release or recovery
commands in `|| true`. A failed safety check is part of the operator contract.
