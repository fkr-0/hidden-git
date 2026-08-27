#!/bin/sh
set -eu

# Internal endpoint is a HiddenGit implementation invariant. Host/onion port
# choices map to it and cannot make health probes drift from Soft Serve.
banner="$(printf '\n' | nc -w 3 127.0.0.1 23231 2>/dev/null | head -n1)"
case "$banner" in
    SSH-*) exit 0 ;;
    *) exit 1 ;;
esac
