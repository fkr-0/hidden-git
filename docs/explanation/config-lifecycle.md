---
title: Explanation — configuration lifecycle
---

# Configuration lifecycle and upgrade contract

## State machine

```text
                     ┌──────────────┐
        init ───────> │ schema v1    │ <──── migration apply
                     │ canonical    │
                     └──────┬───────┘
                            │ config check
                            v
                     ┌──────────────┐
                     │ Compose-safe │
                     └──────┬───────┘
                            │ up
                            v
                     managed runtime config

legacy / malformed
       │
       ├─ duplicate/unknown/ambiguous ──> FAIL, no write
       │
       └─ deterministic legacy ──> preview ──> explicit --apply ──> canonical
```

## Parse before Compose

`.env` is intentionally parsed by HiddenGit before Docker Compose for commands
that can start/build/render the stack. This closes a historical class of
split-brain bugs where different consumers could choose different duplicate
assignments or defaults.

The parser does not `source` or `eval` `.env`; it accepts a controlled assignment
syntax and treats content as data.

## Schema version

`HIDDEN_GIT_CONFIG_VERSION` describes the public environment contract. It is
different from `HIDDEN_GIT_VERSION`: software may make patch releases without a
schema change, while a future schema revision may require explicit migration.

## `sync-pins` is not schema migration

`sync-pins` refreshes release-managed values. It intentionally does not stamp a
new config schema over an old file, because that could claim compatibility
without removing or translating legacy keys. Upgrade sequence is:

1. preview/apply schema migration when needed;
2. validate canonical config;
3. keep release pins aligned with checked-out source;
4. perform state migrations separately if the release requires them.

## Idempotency

Canonical output order comes from `env.example`. After a successful apply:

- applying again writes nothing;
- file bytes remain identical;
- no new rollback copy appears;
- no service restart occurs as a side effect.

This makes config convergence mechanically testable rather than a claim based on
visual inspection.

## Confirmation policy

Config apply is explicit but non-interactive because it is narrowly scoped,
pre-viewable, atomic, rollback-backed, and never mutates runtime state. In
contrast, ownership migration, reconciliation, or restore can alter persistent
state/identity and therefore keep stronger gates and stopped-stack requirements.
