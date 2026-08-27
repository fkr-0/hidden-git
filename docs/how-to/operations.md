---
title: How-to — routine operations
---

# Routine operations

## Check health without changing state

```sh
./run.sh config check
./run.sh doctor
./run.sh ps
./run.sh status
```

`config check` validates only the selected `.env`. `doctor` adds runtime and
security-posture checks. `status` may read the generated onion hostname; treat
that hostname as deployment metadata rather than a password.

## Start

```sh
./run.sh up
```

This validates schema and bootstrap requirements, checks/migrates only safe empty
state ownership, starts dependencies in health order, and performs a bounded
onion SSH check.

## Stop

```sh
./run.sh down
```

Compose containers and the project network are removed; bind-mounted persistent
state remains.

## Restart after a config change

```sh
./run.sh config check
./run.sh restart
```

Do not use restart as a way to discover whether an ambiguous migration is safe.
`config migrate` must converge first.

## Follow logs

```sh
./run.sh logs
```

Before sharing output, remove onion hostnames, account names, repository names,
or other deployment-specific metadata your threat model treats as sensitive.

## Change the local SSH port

Edit only:

```text
LOCAL_SSH_PORT=40222
```

Then validate and restart. Soft Serve and Tor remain on managed internal `23231`.

## Change the onion virtual port

Edit only:

```text
ONION_PUBLIC_PORT=8022
```

Then restart and update client SSH config. The Tor target remains `soft-serve:23231`.

## Adopt reviewed release pins

```sh
./run.sh sync-pins
```

This creates a private rollback copy and updates release-managed values from the
checked-out `env.example`. It preserves deployment intent such as local/onion
ports, name, public SSH URL, and recovery settings. If the schema itself changed,
run `config migrate` as a separate explicit step.

## Repair modes

```sh
./run.sh fix-permissions
```

This repairs supported local modes. Ownership migration of existing application
state is a separate stopped-stack operation requiring a backup and explicit
confirmation.
