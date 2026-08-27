---
title: Extensions and advanced topologies
---

# Extend HiddenGit without expanding the base config API

The public `.env` intentionally does not expose every upstream Soft Serve field.
An advanced topology belongs in a small, version-controlled Compose/config
override with its own threat model and tests.

## Extension checklist

Before enabling a new listener/protocol, answer:

1. Which client or service requires it?
2. Must it be reachable from the host, the Compose network, or Tor?
3. What authenticates and authorizes requests?
4. Is transport confidential/integrity-protected at that boundary?
5. What upstream security advisories apply to this path?
6. What state/backup behavior changes?
7. How does E2E prove inaccessible scopes stay inaccessible?
8. What upgrade/migration contract preserves the extension?

## Example: local metrics collector

Do not publish stats to the host just to let a collector scrape it. Prefer a
purpose-built collector in the Compose network or the same container namespace,
then bind the stats endpoint only to the minimum interface needed. Add an E2E
negative probe from an unrelated container.

## Example: HTTP or LFS

Treat HTTP/LFS as one feature slice, not `enabled: true` in isolation. Define:

- HTTP routing path (local, reverse proxy, onion mapping, or none);
- TLS termination if relevant;
- authentication/authorization semantics;
- public URL and CORS behavior;
- LFS storage/permissions;
- exact upstream Soft Serve version/advisory posture;
- migration from an SSH-only deployment;
- negative tests for unauthorized reads/writes/path traversal.

If the feature cannot satisfy those questions, keep it disabled.

## Example: wider local/LAN SSH

`HOST_BIND_ADDRESS` is already an explicit advanced override. Binding to a LAN
interface exposes the SSH service outside loopback, so pair it with host firewall
policy and document why Tor-only remote access is no longer sufficient.

## Example: alternate internal ports

Changing internal `23231` is deliberately unsupported by `.env`. If platform
constraints truly require it, fork/override the managed topology in one place and
change Soft Serve, Tor, healthcheck, and tests together. Do not reintroduce
independent `SOFT_SERVE_SSH_PORT` and `ONION_TARGET_PORT` settings.

## Proposed extensions

The roadmap currently prioritizes:

- Tor v3 client authorization lifecycle;
- recurring off-host recovery drills and freshness objectives;
- continued operator-control-plane decomposition;
- stable compatibility/support policy toward 1.0.

Each extension should ship with tutorial, reference, architecture rationale,
security impact, migration behavior, and regression evidence in the same release.
