---
title: Development
---

# Development guide

HiddenGit is mostly shell, Compose/YAML, and small Python helpers. The design goal
is not framework sophistication; it is inspectable operations with strong
failure semantics.

## Start with invariants

Before changing code, read:

- [architecture](../project/architecture/)
- [security policy](../project/security/)
- [configuration lifecycle](../explanation/config-lifecycle/)
- [roadmap](../project/roadmap/)
- `issues.yml` in source

Do not normalize real `.env`, databases, repositories, or Tor identity as part
of development tests. Use disposable env files/volumes.

## Local loop

```sh
./tests/test.sh
HIDDEN_GIT_ENV_FILE=/path/to/fixture.env ./run.sh config check
./run.sh build
./tests/e2e.sh
```

Run the smallest relevant check first, then the aggregate gates affected by the
change. Rootless Docker, backup/restore, and ownership migration have dedicated
integration harnesses.

## Change categories

| Change | Minimum evidence |
|---|---|
| config key/schema | parser fixtures, migration/rollback/idempotency, docs |
| listener/topology | exact generated config + real socket positive/negative probes |
| state mutation | stopped-state preflight, backup/rollback, idempotency where meaningful |
| dependency update | source/dependency audit, build, SBOM/vulnerability evidence |
| release workflow | immutable action refs, event/ref verification, artifact checks |
| docs | deterministic local assembly + Jekyll/Pages build compatibility |

Continue with [testing](testing/) and [documentation](documentation/).
