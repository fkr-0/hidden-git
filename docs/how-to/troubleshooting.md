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
| release-owned key appears in `.env` | old schema or attempted operator override | preview/apply `config migrate`; release pins belong to tracked `config/release.env` |
| tracked release metadata invalid | checked-out `config/release.env` is malformed or unreviewed | restore/review the tracked release file; `sync-pins` only validates it |
| invalid port/URL | type/range validation failed | correct the user-intent value |

If migration reports `BLOCKED_LOSSY`, a non-default historical HTTP/Git/stats
field would be retired. Ordinary `--apply` is intentionally non-mutating.
Preserve the old behavior in a reviewed extension if required; otherwise use
the narrow `--accept-retired-auxiliary-topology` acknowledgement.

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
HiddenServicePort 2022 soft-serve:23231
HiddenServicePort <ONION_PUBLIC_PORT> soft-serve:23231  # only when distinct
```

Both declarations must live under the same `HiddenServiceDir`. If
`ONION_PUBLIC_PORT=2022`, exactly one `HiddenServicePort 2022 ...` line is valid.

If Soft Serve is unhealthy, Tor should not be considered ready first.

## Local SSH works, onion SSH fails

Check the layers in order:

1. `./run.sh status` has an onion hostname.
2. Tor reports 100% bootstrap.
3. Tor generated target is `soft-serve:23231`.
4. Client first tests mandatory port `2022`; if needed, test the configured compatibility port too.
5. `oniux`/torsocks route is functional.
6. Client identity and Soft Serve account are correct.

## Services stay stopped after boot or Docker restart

`restart: unless-stopped` does not override a prior explicit stop. Check:

```sh
./run.sh autoboot status
systemctl --user status hidden-git-autoboot.timer
```

For host-boot recovery the user manager must have login linger enabled. Repair a
healthy deployed installation with `./run.sh autoboot install`. The timer does
not build images; if required images were removed, run the normal reviewed
`./run.sh up` path first.

The timer is not the Docker engine's boot authority. Verify the Docker daemon or
rootless Docker user service is itself enabled for boot. `autoboot status` also
prints the Docker context recorded in the installed service, the currently
selected context, and whether the managed unit bytes still match this checkout.
If those contexts differ or the units are stale, qualify the intended context,
remove autoboot, and reinstall it rather than silently retargeting recovery.

If `autoboot install` reports that the running Tor topology is stale, do not
force-enable the timer. Re-qualify the deployment with the current source first.
If it reports a conflicting existing unit, review that unit explicitly;
HiddenGit intentionally refuses to overwrite or remove foreign systemd units.

If install rejects `DOCKER_HOST`, convert that session-only endpoint to a named
Docker context and select it with `docker context use <name>`. The managed
systemd unit persists `DOCKER_CONTEXT`; it intentionally does not copy arbitrary
interactive-shell environment into boot authority.

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
