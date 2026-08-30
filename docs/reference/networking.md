---
title: Networking reference
---

# Networking reference

## Default sockets

| Perspective | Endpoint | Reachability | Purpose |
|---|---|---|---|
| host | `HOST_BIND_ADDRESS:LOCAL_SSH_PORT` | loopback by default | local operator SSH |
| Compose network | `soft-serve:23231` | Tor + project services | authenticated SSH/Git transport |
| Soft Serve container | `127.0.0.1:23233` | disabled listener config | inert stats address, not active |
| Soft Serve container | `127.0.0.1:23232` | disabled listener config | reserved HTTP topology, not active |
| Soft Serve container | `127.0.0.1:9418` | disabled listener config | native Git daemon, not active |
| Tor virtual service | `<onion>:ONION_PUBLIC_PORT` | Tor clients | maps to `soft-serve:23231` |

## Data flow

```text
Remote client
  git/ssh
     │
     ▼
Tor client/proxy
     │ encrypted Tor circuit
     ▼
HiddenGit tor container
  HiddenServicePort <public> soft-serve:23231
     │ private Compose bridge
     ▼
Soft Serve SSH :23231
     │
     ├── SSH public-key authentication
     ├── repository authorization
     └── Git smart protocol over SSH
```

## Why local and onion ports are separate

`LOCAL_SSH_PORT` answers “which loopback port should Docker publish?”
`ONION_PUBLIC_PORT` answers “which virtual port should Tor advertise?” Neither
answers “where should Soft Serve listen?”; that last fact is an implementation
constant. Separating these domains removes an invariant rather than synchronizing
two values forever.

## Why stats is disabled

Statistics are not part of the current HiddenGit product contract and no consumer
requires them, so Soft Serve stats are disabled entirely. The template retains
`127.0.0.1:23233` only as deterministic inert upstream configuration. A future
observability design must explicitly re-enable the service, define its minimum
reachability, and add positive/negative E2E probes.

## Why native `git://` is disabled

The Git daemon protocol adds another remotely reachable path and is not the
authenticated SSH-over-Tor workflow HiddenGit exists to provide. If it becomes a
real requirement, enable it only as a documented extension with authorization,
network-scope, and regression analysis.

## Why HTTP/LFS are disabled

The default onion service exposes SSH only. Enabling Soft Serve HTTP without a
corresponding routing/authentication/product design creates an unused attack
surface. LFS historically depends on HTTP or SSH-LFS behavior and has had
security-sensitive upstream changes; HiddenGit therefore leaves it disabled by
default rather than implying unsupported LFS semantics.
