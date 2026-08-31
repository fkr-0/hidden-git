---
title: Development — testing
---

# Testing strategy

HiddenGit tests properties at the lowest useful layer and then verifies the full
network path.

## Static suite

`./tests/test.sh` covers shell/YAML syntax, release metadata, immutable pins,
secret/build-context hygiene, config schema migration, duplicate/unknown-key
rejection, migration idempotency, Compose rendering, workflow policy, and helper
fixtures.

## E2E

`./tests/e2e.sh` uses disposable credentials, random host SSH publication, named
volumes, and a real Tor bootstrap. It must prove:

- generated `/run` Soft Serve config wins over a seeded conflicting persistent
  `config.yaml`;
- internal SSH is exactly `23231`;
- host publishes only that internal port to the chosen local port;
- HTTP/native Git are closed;
- stats is closed even inside the Soft Serve container and from sibling/Tor containers;
- Tor maps mandatory `2022` and a distinct compatibility virtual port to
  `soft-serve:23231` under one hidden-service identity;
- authenticated local SSH and authenticated onion SSH work on both virtual ports;
- an explicit unauthorized SSH identity is rejected by the onion checker rather
  than being mistaken for authenticated success after a completed SSH handshake;
- forced recreate preserves the exact onion hostname bytes and managed config;
- setting the compatibility port to `2022` converges to exactly one Tor mapping.

`./tests/autoboot.sh` uses fake Docker/systemd/loginctl boundaries to prove
fail-closed install, deterministic/idempotent unit rendering, healthy no-op,
recovery after explicit stop/down, retry after Docker-daemon outage, and
idempotent status/remove without touching the live deployment. It also verifies
the activation-based five-minute retry timer and makes recorded/current Docker
context drift visible without automatically changing boot authority.

## Rootless Docker

The rootless harness boots the stack inside a disposable rootless Docker daemon
and verifies service users, ownership, read-only roots, capabilities, and Compose
compatibility. To keep the disposable test bounded, reviewed pinned base images
already present on the outer test host are exported into the empty nested daemon
before rootless builds begin. The harness then restarts the nested Docker daemon
itself and requires Compose restart policy to recover both services while the
Tor hostname bytes remain identical.

## Recovery

Backup/restore tests exercise authenticated archive verification plus preserve
and rotate identity modes. Never weaken empty-target protection to make a test
fixture convenient.

## Negative tests are first-class

For every new reachable service, add a positive test from the intended scope and
negative tests from unintended scopes. A rendered Compose diff alone is not
network evidence.
