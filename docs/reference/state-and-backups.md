---
title: State and backup reference
---

# Persistent state and recovery boundaries

| Path | Owner | Contains | Git/build context |
|---|---:|---|---|
| `data/soft-serve/` | 10001:10001 | repositories, SQLite DB, Soft Serve SSH identities | excluded |
| `data/tor/` | 10002:10002 | Tor state and persistent onion identity | excluded |
| `backups/` | operator | encrypted archives, checksum sidecars, possibly local recovery key before offlining | excluded |
| `retired-state/` | operator | explicitly archived legacy deployment | excluded |

The Soft Serve and Tor trees form one logical recovery unit. Restoring only one
can pair application state with an unexpected onion or SSH identity.

## Config state is different

`.env` is declarative local configuration. Its migration can be atomic,
rollbackable, and idempotent without touching application state. This is why
`config migrate --apply` does **not** share the same confirmation policy as
database/Tor mutations.

## Consistency model

Backups are stopped-state snapshots. HiddenGit does not promise an online SQLite
+ Git repository snapshot protocol. The simple policy makes the recovery unit
auditable and testable.

## Identity choices on restore

- `preserve`: continuity of onion service identity.
- `rotate`: intentionally generate a new onion identity after restoring Soft
  Serve state.

These modes say nothing about client SSH keys stored in Soft Serve; review user
authorization separately after an incident.
