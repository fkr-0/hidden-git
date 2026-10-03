---
title: Tutorial — first deployment
---

# First deployment, end to end

This tutorial starts with an empty checkout and ends with authenticated SSH over
both loopback and the generated Tor v3 onion endpoint. It deliberately does not
enable HTTP, native `git://`, or LFS.

## 1. Inspect the release before running it

```sh
git status --short --branch
./run.sh version
git show --no-patch --decorate
```

For a release installation, verify that the checked-out tag is `v$(cat VERSION)`.
The release's SBOM/provenance artifacts are produced by CI and should be reviewed
alongside the source when supply-chain assurance matters.

## 2. Initialize private local configuration

```sh
./run.sh init
stat -c '%a %n' .env data data/soft-serve data/tor backups
```

Expected `.env` mode is `600`; state directories are private. `init` refuses to
overwrite an existing `.env`.

## 3. Add the bootstrap administrator

Create or select an Ed25519 key on the operator machine:

```sh
ssh-keygen -t ed25519 -f ~/.ssh/hiddengit-admin
cat ~/.ssh/hiddengit-admin.pub
```

Copy **only the public-key line** into `.env`:

```text
SOFT_SERVE_INITIAL_ADMIN_KEYS="ssh-ed25519 AAAA... operator@example"
```

The field is bootstrap-only. It is required while the first database is being
created; it is not a private-key store and must never contain the private key.

## 4. Review operator intent

The normal deployment fields are deliberately short:

```text
SOFT_SERVE_NAME=HiddenGit
ONION_PUBLIC_PORT=8002
LOCAL_SSH_PORT=23231
HOST_BIND_ADDRESS=127.0.0.1
SOFT_SERVE_SSH_PUBLIC_URL=
```

`LOCAL_SSH_PORT` controls only the loopback-facing host port. It does not change
Soft Serve's internal listener. `ONION_PUBLIC_PORT` controls only the virtual
onion port. Both map to internal SSH `23231`.

## 5. Validate before state creation

```sh
./run.sh config check
./run.sh config
./run.sh doctor
```

`config check` is Docker-free and fails on duplicate, unknown, stale, malformed,
or release-pin-drifted configuration. `config` additionally renders Compose.
`doctor` evaluates operational posture such as file modes, loopback publication,
container users, backup freshness, and Docker isolation.

## 6. Start and wait for the whole path

```sh
./run.sh up
```

`up` does more than `docker compose up`:

```text
schema check
    ↓
first-boot key check
    ↓
runtime ownership check/migration for empty state
    ↓
Soft Serve :23231 healthy
    ↓
Tor bootstrap = 100% + onion hostname exists
    ↓
authenticated onion SSH probe
```

If any required stage fails, the command exits non-zero rather than declaring
the service ready early.

## 7. Connect locally

```sh
ssh -i ~/.ssh/hiddengit-admin -p 23231 admin@127.0.0.1
```

If `LOCAL_SSH_PORT` was changed, use that host port instead.

## 8. Connect through Tor

```sh
./run.sh status
```

Assume it reports `example.onion` and port `8002`. With `oniux`:

```sshconfig
Host hiddengit
  HostName example.onion
  User admin
  Port 8002
  ProxyCommand oniux nc %h %p
  IdentityFile ~/.ssh/hiddengit-admin
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
```

Then:

```sh
ssh hiddengit
git clone ssh://hiddengit/OWNER/REPOSITORY.git
```

The first connection establishes an SSH host-key trust decision. Verify the host
key through an independent channel when your threat model requires it.

## 9. Create the first backup before real work accumulates

Generate an age identity, move it offline, configure only the public recipient,
then perform a stopped-state backup. Follow the
[backup and recovery tutorial](backup-and-recovery/) before treating the service
as recoverable.

## Completion checklist

- `config check` passes.
- `doctor` has no unexplained warning.
- `status` reports the expected onion port.
- local SSH authenticates with the intended key.
- onion SSH authenticates with the same Soft Serve account.
- `.env`, `data/`, and the age identity are absent from Git.
- a verified encrypted backup exists off-host.
