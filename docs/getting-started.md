---
title: Getting started
---

# Getting started

Use this page to choose the right workflow before touching state.

## Requirements

- Docker Engine and Docker Compose v2.
- Bash and Python 3.
- An Ed25519 SSH key for the first administrator.
- Working outbound Tor connectivity from the host/container network.
- Optional `oniux`; the project includes a containerized `torsocks` fallback.

## Fresh installation

```sh
git clone https://github.com/fkr-0/hidden-git.git
cd hidden-git
./run.sh init
```

Edit only the deployment-intent fields in `.env`, most importantly
`SOFT_SERVE_INITIAL_ADMIN_KEYS`. Then:

```sh
./run.sh config check
./run.sh doctor
./run.sh up
./run.sh status
```

Continue with the [first-deployment tutorial](tutorials/first-deployment/).

## Existing installation

Do **not** copy the new `env.example` over an existing `.env`. First preview the
versioned migration:

```sh
./run.sh config migrate
```

If the preview expresses the intended topology, apply it:

```sh
./run.sh config migrate --apply
./run.sh config check
```

The apply operation touches only the selected environment file and creates a
mode-0600 rollback copy. It does not change repositories, the database, SSH
keys, or Tor identity. See [upgrade and migrate](tutorials/upgrade-and-migrate/).

## What not to configure

Older versions exposed internal ports such as `SOFT_SERVE_SSH_PORT` and
`ONION_TARGET_PORT`. They are intentionally gone. If you need a different local
port, use `LOCAL_SSH_PORT`; Tor still targets internal `23231`. If you need HTTP,
native `git://`, or external stats, treat that as an architectural extension,
not a port tweak. See [extensions](extensions/).
