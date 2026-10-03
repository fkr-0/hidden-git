---
title: Tutorial — upgrade and migrate
---

# Upgrade an older deployment without port drift

The configuration migration is intentionally separate from persistent-state
migrations. Its job is to make old `.env` files converge to the current schema
without rewriting repositories, the Soft Serve database, SSH identities, or the
Tor onion identity.

## Why migration exists

Older HiddenGit releases represented one network fact in several places:

```text
SOFT_SERVE_SSH_PORT ─┬─ Soft Serve listener
                     ├─ host publication
                     └─ health check
ONION_TARGET_PORT ───── Tor target
SOFT_SERVE_SSH_PUBLIC_URL ─ clone hint
```

That created drift opportunities. Duplicate `.env` keys were worse: the shell
reader and Docker Compose could choose different occurrences. Current schema
validation rejects duplicates before Compose executes.

The target model is:

```text
internal SSH = 23231  ← managed constant
       ↑          ↑
       │          └── Tor onion:<ONION_PUBLIC_PORT>
       └───────────── host 127.0.0.1:<LOCAL_SSH_PORT>
```

## 1. Stop and back up before upgrading software

A config-only migration does not need application-state mutation, but a software
upgrade deserves a recovery point:

```sh
./run.sh down
./run.sh backup
./run.sh verify-backup backups/<archive>.tar.age /offline/identity.agekey
```

Keep the old checkout/tag available as rollback source.

## 2. Update the source without overwriting `.env`

Switch to the reviewed release/tag using your normal Git workflow. Never copy
`env.example` on top of the existing deployment file.

## 3. Preview the config transformation

```sh
./run.sh config migrate
```

The preview:

- never prints values classified as secret-bearing;
- reports keys added, removed, and changed;
- maps an old custom `SOFT_SERVE_SSH_PORT` to `LOCAL_SSH_PORT`;
- removes `ONION_TARGET_PORT`, `SOFT_SERVE_DATA_PATH`, and `CI` when they match
  supported legacy invariants;
- drops old HTTP/Git/stats internal port settings because those services are no
  longer host-published in the default profile;
- updates release-managed pins to the checked-out release;
- fails closed on duplicate keys, unknown keys, conflicting old/new SSH ports,
  mismatched old SSH/Tor targets, or an unsupported custom internal data path.

Warnings about a formerly customized HTTP/Git/stats port mean the old deployment
used a topology the new secure default intentionally removes. Decide whether to
accept the reduced surface or maintain a reviewed extension; do not hide the
warning by inventing a new `.env` knob.

## 4. Apply only after reviewing the plan

```sh
./run.sh config migrate --apply
```

If a change is needed, the command first creates a timestamped mode-0600 copy:

```text
.env.pre-config-YYYYmmddTHHMMSSZ
```

The replacement is written atomically and fsynced. No rollback copy is created
when the file is already canonical.

## 5. Prove convergence

```sh
sha256sum .env
./run.sh config migrate --apply
sha256sum .env
```

The second command should say:

```text
Configuration migration: already canonical
No changes applied; no rollback copy created
```

The hashes must match. This is the operational definition of migration
idempotency.

## 6. Validate and restart

```sh
./run.sh config check
./run.sh doctor
./run.sh up
./run.sh status
```

Verify local SSH on `LOCAL_SSH_PORT` and onion SSH on `ONION_PUBLIC_PORT`.

## Rollback

If the declarative migration itself is wrong and services have not been started,
restore the private pre-config copy to `.env`, preserving mode `0600`, and use
the prior source release. If application state has already been upgraded or
changed, use the release-specific recovery procedure rather than assuming an
`.env` rollback reverses database changes.

## Unsupported legacy topology

The migration intentionally stops rather than guessing when an old deployment
changed an internal invariant such as `SOFT_SERVE_DATA_PATH`. Capture the old
Compose/config, back up state, and design an explicit migration. This is safer
than turning every historical implementation detail into a permanent public API.
