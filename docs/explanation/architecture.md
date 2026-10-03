---
title: Explanation — architecture
---

# Architecture: opinionated boundaries over raw knobs

HiddenGit is not a generic Soft Serve configuration generator. It is a small
product profile with a deliberately narrow trust and network model.

## Components

```text
                       release/control plane
┌───────────────────────────────────────────────────────────────┐
│ run.sh ── config/schema.json ── Docker Compose               │
│   │                │                    │                     │
│   │                └─ configctl.py      │                     │
│   │                                     │                     │
│   ├─ maintenance (network:none)         │                     │
│   └─ tor-check (one-shot)               │                     │
└─────────────────────────────────────────┼─────────────────────┘
                                          │
                         runtime/data plane
             ┌────────────────────────────┴──────────────────┐
             │                                               │
             │  Tor 10002:10002                              │
remote Tor ──┼─> onion:<public> ──> soft-serve:23231          │
             │                          │                     │
local SSH ───┼─> 127.0.0.1:<local> ─────┘                     │
             │                          │                     │
             │                    Soft Serve 10001:10001      │
             │                    ├─ SQLite                    │
             │                    ├─ repositories              │
             │                    └─ SSH identities            │
             └────────────────────────────────────────────────┘
```

## Three kinds of configuration

### Product invariants

Internal SSH `23231`, persistence path, Tor target, service enablement, and
stats scope are owned by source/templates. Operators should not need to reason
about these values during normal deployment.

### Deployment intent

The operator chooses public/local presentation: onion virtual port, local host
port, bind address, display name, optional public SSH clone hint, bootstrap key,
and recovery settings.

### Release-managed inputs

Image digests and upstream module versions form the reviewed release set. Mixing
arbitrary pins with a tagged HiddenGit source creates an unreviewed artifact, so
schema validation treats drift as an error.

## Generated config versus persistent state

Soft Serve historically generates/persists a config file in its data area. A
runtime policy that depends on such a stale file can diverge from Compose. Modern
HiddenGit generates `/run/hidden-git/soft-serve.config.yaml` on every start and
sets `SOFT_SERVE_CONFIG_LOCATION` explicitly. `/run` is ephemeral and managed;
the database/repositories remain persistent.

The E2E suite seeds a conflicting historical `config.yaml` and proves that the
managed `/run` config and actual sockets still win.

## Why fewer settings is safer

Every duplicated setting creates a consistency relation that must be validated
forever. The old SSH path required several equalities. The current design uses
mapping instead:

```text
operator local port ─┐
                     ├── maps to ── fixed SSH :23231
operator onion port ─┘
```

No validator is needed to make two internal SSH variables equal because the
second internal variable no longer exists.

The canonical, release-level architectural invariants are maintained in the
[project architecture record](../../project/architecture/).
