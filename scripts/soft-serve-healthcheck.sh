#!/bin/sh
set -eu

port="${SOFT_SERVE_SSH_PORT:?SOFT_SERVE_SSH_PORT is required}"
banner="$(printf '\n' | nc -w 3 127.0.0.1 "$port" 2>/dev/null | head -n1)"
case "$banner" in
    SSH-*) exit 0 ;;
    *) exit 1 ;;
esac
