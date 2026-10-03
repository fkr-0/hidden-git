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
- stats is reachable on Soft Serve loopback but not from the Tor container;
- Tor maps the chosen onion virtual port to `soft-serve:23231`;
- authenticated local SSH and onion SSH both work;
- forced recreate produces the same managed config.

## Rootless Docker

The rootless harness boots the stack inside a disposable rootless Docker daemon
and verifies service users, ownership, read-only roots, capabilities, and Compose
compatibility.

## Recovery

Backup/restore tests exercise authenticated archive verification plus preserve
and rotate identity modes. Never weaken empty-target protection to make a test
fixture convenient.

## Negative tests are first-class

For every new reachable service, add a positive test from the intended scope and
negative tests from unintended scopes. A rendered Compose diff alone is not
network evidence.
