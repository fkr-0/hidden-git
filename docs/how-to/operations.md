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
onion SSH check on mandatory port `2022` and, when distinct, the configured
compatibility port.

## Enable host/autoboot recovery

After `./run.sh up` is healthy, enable a lingering systemd user manager and
install the reconciliation timer:

```sh
loginctl enable-linger "$USER"
./run.sh autoboot install
./run.sh autoboot status
```

`install` fails before writing units unless configuration is valid, both
services are already running, an onion hostname exists, and login linger is
enabled. It also verifies that the currently running Tor instance already has
the source checkout's mandatory `2022` mapping (plus the compatibility mapping
when distinct), so autoboot cannot pin an older running topology in place.
The installer records the active named Docker context in the systemd service;
an ad-hoc `DOCKER_HOST` is rejected because a boot-time user service would not
inherit it. For rootless/custom Docker, first select the durable context with
`docker context use <name>`.
HiddenGit does not enable or start the Docker daemon itself: the selected Docker
engine/context must have its own boot authority (for example the system Docker
service, or a lingering rootless Docker user service). `autoboot status` shows
both the context recorded in the managed unit and the current operator context;
a mismatch is a review/reinstall condition, not an automatic retarget.
Existing unit files with the same names are never overwritten unless their bytes
already match HiddenGit's managed units. The timer checks after boot and every
five minutes from the previous reconciliation activation. It leaves a healthy
stack untouched and repairs stopped/missing services with existing local images
(`--no-build --wait`). A Docker-daemon outage therefore fails closed and is
retried on the next activation.

Before planned downtime, remove the timer first:

```sh
./run.sh autoboot remove
./run.sh down
```

Removing autoboot never stops containers itself.

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

Then restart and update any client that still uses the compatibility port. Port
`2022` remains available on the same onion hostname regardless. If the configured
value is `2022`, only one Tor mapping is emitted. The target remains
`soft-serve:23231`.

## Check reviewed release pins

```sh
./run.sh sync-pins
```

This validates tracked `config/release.env` and the current operator config. It
does not change `.env` or create a rollback copy. Release pins are source-owned;
use normal source review/update workflow to change them. If the operator schema
changed, run `config migrate` as a separate explicit step.

## Repair modes

```sh
./run.sh fix-permissions
```

This repairs supported local modes. Ownership migration of existing application
state is a separate stopped-stack operation requiring a backup and explicit
confirmation.
