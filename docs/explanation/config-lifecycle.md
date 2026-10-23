---
title: Explanation — configuration lifecycle
---

# Configuration lifecycle and upgrade contract

## Two ownership domains

Schema v2 separates two declarative inputs that have different owners:

```text
operator .env                         tracked config/release.env
─────────────                         ──────────────────────────
network/public intent                 immutable image references
bootstrap key                         Soft Serve v0.12.2
clone metadata                        release scanner/builder
checks/recovery recipient             rootless qualification image
                                       mandatory onion SSH port 2022
       │                                      │
       └──────── scripts/configctl.py ─────────┘
                         │
                         v
                 validated consumers
```

The operator file cannot override tracked release keys. `VERSION` is the sole
HiddenGit project-version authority.

## State machine

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

## Parse before action

`scripts/configctl.py` is the authoritative parser for operator configuration and
tracked release metadata. Commands that consume current deployment configuration
validate it before Compose or mutation. This closes the historical split-brain
class where a shell first-match reader and Compose could select different
assignments.

The parser never `source`s or `eval`s `.env`; it accepts a controlled assignment
syntax and treats content as data. Duplicate, unknown, malformed, stale, and
release-owned current keys fail closed.

`restart` deliberately validates before `down`: invalid config cannot stop a
working stack and then fail to bring it back.

## Schema version versus release version

`HIDDEN_GIT_CONFIG_VERSION=2` describes the public operator contract. `VERSION`
describes the HiddenGit software release. Release/build pins are tracked in
`config/release.env`; they are not operator config and there is no
`HIDDEN_GIT_VERSION` duplicate.

## Lossy legacy auxiliary topology

Historical default HTTP/Git/stats fields can retire automatically because they
represent the old default surface. A non-default historical HTTP, stats, or
native-Git port, or an HTTP/Git public URL, is evidence of operator intent.
Migration reports those key names as `BLOCKED_LOSSY` without printing their
values.

Ordinary `config migrate --apply` fails before backup or write. After preparing a
separately reviewed extension if the old behavior must survive, an operator may
acknowledge retirement with:

```sh
./run.sh config migrate --apply --accept-retired-auxiliary-topology
```

That flag is not a force switch. It cannot bypass duplicate/unknown/malformed
configuration, old/new SSH conflicts, mismatched old SSH/Tor targets,
unsupported data paths, or future schema versions.

## Release metadata and `sync-pins`

`config/release.env` is source-controlled release metadata. `sync-pins` remains
only for command compatibility: it validates the current v2 operator config and
tracked release file and writes no `.env` bytes. Changing release pins is a
source-review operation, not an operator mutation.

The five historical downstream Soft Serve dependency overrides were removed
because they matched the selected v0.12.2 graph. The Dockerfile builds upstream
v0.12.2 directly and verifies its module graph rather than mutating it with
`go get`.

## Serializer and idempotency

Legacy migration renders canonical order/comments from `env.example`; it does
not preserve historical comments/order. After a successful apply:

- when configuration bytes change, a mode-0600 rollback copy exists in the same
  directory and replacement is same-directory atomic and fsynced;
- a permission-only repair to mode 0600 changes no bytes and creates no rollback
  copy, because the original configuration bytes remain in place;
- application state is untouched;
- applying again writes nothing;
- file bytes remain identical;
- no new rollback copy appears;
- no service restart occurs as a side effect.

## Bootstrap administrator lifecycle

A missing DB requires a nonempty `SOFT_SERVE_INITIAL_ADMIN_KEYS`. Once the DB
exists, HiddenGit removes this variable from the Soft Serve process environment
before exec because upstream v0.12.2 still treats configured initial keys as
server-admin authority. This suppression does not create, delete, or change DB
users/admin flags. `doctor` warns when an established `.env` still contains a
bootstrap value so the operator can clear it declaratively.

## Recovery identity lifecycle

`BACKUP_RECIPIENT` may remain public recovery intent in `.env`. The age identity
path is not current declarative config: `verify-backup` and `restore` require an
explicit identity argument, and reconciliation does not persist an identity path
into `.env`.
