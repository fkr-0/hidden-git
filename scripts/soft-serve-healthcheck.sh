#!/usr/bin/env bash
set -euo pipefail

port="${SOFT_SERVE_SSH_PORT:?SOFT_SERVE_SSH_PORT is required}"
exec 3<>"/dev/tcp/127.0.0.1/${port}"
IFS= read -r -t 3 banner <&3
[[ "$banner" == SSH-* ]]
