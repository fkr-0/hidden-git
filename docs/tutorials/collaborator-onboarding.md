---
title: Tutorial — collaborator onboarding
---

# Onboard a collaborator or second device

HiddenGit has two distinct access layers:

1. Tor provides private routing to the onion service.
2. Soft Serve authenticates SSH keys and authorizes repositories.

An onion hostname is **not** a repository credential.

## 1. Create a dedicated key on the client

```sh
ssh-keygen -t ed25519 -f ~/.ssh/hiddengit-workstation
```

Transfer only the `.pub` value to an existing Soft Serve administrator through
an authenticated channel.

## 2. Add the user/key in Soft Serve

Use Soft Serve's administrative interface/commands from an authenticated admin
session. Do not reuse `SOFT_SERVE_INITIAL_ADMIN_KEYS` as an ongoing enrollment
mechanism: that field exists to bootstrap an empty database.

Assign the minimum repository permission needed. Private repositories should not
depend on obscurity of the onion address.

## 3. Configure the Tor-aware SSH client

```sshconfig
Host hiddengit-work
  HostName example.onion
  User collaborator-name
  Port 8002
  ProxyCommand oniux nc %h %p
  IdentityFile ~/.ssh/hiddengit-workstation
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
```

Connect once and verify the server host-key fingerprint through the channel used
by your organization.

## 4. Test least privilege

Test both a permitted and a non-permitted repository. A successful SSH login is
not evidence that repository ACLs are correct.

## 5. Revoke a lost device

Remove only the affected key if the account has independent keys per device.
Rotate account/repository access only when the threat model requires it.

Tor v3 client authorization lifecycle is a separate planned defense-in-depth
feature. Until it is implemented and tested, Soft Serve SSH authorization remains
the mandatory access boundary.
