---
title: Tutorial — backup and recovery
---

# Backup and recovery drill

A backup is useful only if it can be decrypted, verified, and restored while the
recovery identity is still available. HiddenGit therefore separates the public
age recipient from its offline secret identity and provides explicit
preserve/rotate onion-identity modes.

## 1. Generate the recovery identity once

```sh
./run.sh backup-keygen
```

Move the generated `.agekey` file to offline/durable storage. Keep only the
public `age1...` recipient in `.env` as `BACKUP_RECIPIENT`.

## 2. Stop for a consistent snapshot

```sh
./run.sh down
```

The stopped-state design intentionally trades availability for simple,
reviewable consistency across Git repositories, SQLite state, SSH identities,
and Tor identity.

## 3. Create and verify the encrypted backup

```sh
./run.sh backup
./run.sh verify-backup \
  backups/hidden-git-current-backup-YYYYmmddTHHMMSSZ.tar.age \
  /offline/backup-identity.agekey
```

Verification checks both the encrypted artifact checksum and the per-file
manifest after decryption. It does not restore state.

## 4. Copy the archive off-host

Store the encrypted archive and checksum sidecar on independent storage. Keep
the age secret identity separately; copying encrypted data and its only decryption
key to the same failure domain defeats part of the recovery design.

## 5. Choose recovery identity semantics

`preserve` restores the prior Tor identity:

```sh
./run.sh restore <archive> /offline/backup-identity.agekey preserve
```

Use it when continuity of the onion hostname is required and the identity is not
suspected compromised.

`rotate` restores application state but deliberately omits the Tor identity:

```sh
./run.sh restore <archive> /offline/backup-identity.agekey rotate
```

On next startup Tor creates a new onion hostname. Use it after identity compromise
or when intentional service-address rotation is required.

## 6. Post-restore checks

```sh
./run.sh config check
./run.sh doctor --strict
./run.sh up
./run.sh status
```

Then verify:

- expected repositories and access controls exist;
- SSH host identity matches the selected recovery expectation;
- onion hostname is preserved or changed exactly as intended;
- local and onion SSH work;
- a new backup can be created from the recovered instance.

## Recovery failure rules

- Never restore over non-empty target directories.
- Never “merge” two Soft Serve databases or two onion identities as a discovery
  technique.
- Never expose the age identity in CI, logs, screenshots, or bug reports.
- If both legacy and current state layouts exist, use the secret-safe inventory
  and reconciliation workflow before deleting anything.
