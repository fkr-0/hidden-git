---
title: HiddenGit documentation
description: Operate, understand, extend, and recover a private Git forge over Tor and SSH.
---

# Private Git without a public forge

HiddenGit packages a deliberately small Soft Serve deployment behind a Tor v3
onion service. The default product profile exposes **one authenticated protocol**:
SSH. Internal ports, persistence paths, Tor targets, HTTP, native `git://`, LFS,
and statistics exposure are implementation policy rather than a collection of
independent `.env` switches.

```text
developer                                       HiddenGit host
┌──────────────┐    Tor v3 circuit     ┌─────────────────────────────────┐
│ git / ssh    │ ────────────────────> │ tor                            │
│ public key   │                       │  onion:<ONION_PUBLIC_PORT>      │
└──────────────┘                       │          │                      │
                                       │          v                      │
local operator                         │ soft-serve:23231 (SSH)          │
┌──────────────┐                       │   │                              │
│ ssh localhost│ ─ LOCAL_SSH_PORT ───> │   ├─ SQLite + repos             │
└──────────────┘                       │   └─ SSH host/client keys        │
                                       │                                 │
                                       │ HTTP/git://: disabled            │
                                       │ stats: 127.0.0.1:23233 only      │
                                       └─────────────────────────────────┘
```

## Pick a path

| Goal | Start here |
|---|---|
| Install a fresh forge | [First deployment](tutorials/first-deployment/) |
| Upgrade an older checkout safely | [Upgrade and configuration migration](tutorials/upgrade-and-migrate/) |
| Add another human/device | [Collaborator onboarding](tutorials/collaborator-onboarding/) |
| Build a recovery plan | [Backup and recovery](tutorials/backup-and-recovery/) |
| Understand every supported setting | [Configuration reference](reference/configuration/) |
| Understand network exposure | [Networking reference](reference/networking/) |
| Debug a failed startup | [Troubleshooting](how-to/troubleshooting/) |
| Change the product or build extensions | [Development](development/) and [Extensions](extensions/) |

## Design promises

1. **No public clearnet listener by default.** Host SSH publication is loopback-only.
2. **One source of truth for internal topology.** Tor and health checks target the fixed managed SSH endpoint.
3. **Versioned configuration.** Unknown, duplicate, stale, and ambiguous keys fail before Compose can interpret them differently.
4. **Migration is explicit.** `config migrate` previews; `--apply` makes a private rollback copy and converges declarative config only.
5. **Persistent state is not normalized casually.** Databases, repositories, SSH identities, and the Tor identity have separate guarded workflows.
6. **Release docs are immutable snapshots.** `hiddengit.fkr.dev` is built from the exact tag attached to a published GitHub Release.

> HiddenGit reduces accidental exposure; it does not make the host, Docker daemon,
> operator keys, endpoint device, or backup custody trustworthy automatically.
> Read the [security model](explanation/security-model/) before relying on it for
> sensitive repositories.

## Canonical project records

The site republishes the release's canonical [architecture](project/architecture/),
[roadmap](project/roadmap/), [changelog](project/changelog/),
[security policy](project/security/), [release procedure](project/releasing/),
and [developer notes](project/dev-notes/). These copies are assembled directly
from the tagged source so the website cannot silently document a different release.
