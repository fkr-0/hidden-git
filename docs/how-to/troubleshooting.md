---
title: Troubleshooting
---

# Troubleshooting by failure layer

Start at the earliest failing layer. Avoid changing several values at once.

## `config check` fails

| Message class | Meaning | Action |
|---|---|---|
| duplicate key | `.env` has ambiguous semantics | remove the duplicate or migrate from an unambiguous rollback copy |
| unknown key | likely typo or unsupported historical option | correct the typo; use `config migrate` for known legacy keys |
| legacy key requires migration | file predates current schema | run `./run.sh config migrate` |
| release-managed key differs | local pins drift from checked-out release | run `./run.sh sync-pins` after reviewing source/release |
| invalid port/URL | type/range validation failed | correct the user-intent value |

Migration failure is intentionally non-mutating. For a legacy mismatch such as
`SOFT_SERVE_SSH_PORT != ONION_TARGET_PORT`, determine which old endpoint was
actually in use rather than asking the tool to guess.

## Compose rendering fails

```sh
./run.sh config
```

If schema validation passed but Compose fails, inspect `docker compose version`
and the rendered error. The default stack should contain exactly one Soft Serve
host publication: fixed internal SSH `23231` mapped to `LOCAL_SSH_PORT`.

## Soft Serve is unhealthy

```sh
docker compose ps
docker compose logs soft-serve
```

The health check probes SSH banner `127.0.0.1:23231` inside the container. Check:

- writeability/ownership of `data/soft-serve/`;
- presence of a bootstrap public key on a genuinely fresh database;
- generated `/run/hidden-git/soft-serve.config.yaml`;
- database errors or upstream migration errors.

Do not edit a persistent historical `data/soft-serve/config.yaml`; current
HiddenGit intentionally gives the generated `/run` config authority.

## Tor is unhealthy

```sh
docker compose logs tor
```

Tor health requires control-port-confirmed bootstrap plus a generated onion
hostname. The managed mapping must be:

```text
HiddenServicePort <ONION_PUBLIC_PORT> soft-serve:23231
```

If Soft Serve is unhealthy, Tor should not be considered ready first.

## Local SSH works, onion SSH fails

Check the layers in order:

1. `./run.sh status` has an onion hostname.
2. Tor reports 100% bootstrap.
3. Tor generated target is `soft-serve:23231`.
4. Client uses the current `ONION_PUBLIC_PORT`.
5. `oniux`/torsocks route is functional.
6. Client identity and Soft Serve account are correct.

## Onion SSH works, Git operation fails

This is likely a Soft Serve repository authorization/path problem rather than a
Tor problem. Test plain SSH/TUI first, then inspect repository ownership and ACLs.

## LFS does not work

That is expected in the default SSH-only profile: LFS is disabled. Do not enable
an HTTP listener or SSH LFS as an ad-hoc troubleshooting step. Review
[Extensions](../extensions/) and the current upstream security posture first.

## Recovery operations fail

Stop. Restore intentionally refuses non-empty targets. Verify the encrypted
archive independently before retrying and never merge two state trees because a
restore command refused one.
