#!/bin/sh
set -eu

fail() {
    printf 'hidden-git tor entrypoint: %s\n' "$*" >&2
    exit 1
}

validate_port() {
    name="$1"
    value="$2"
    case "$value" in
        ''|*[!0-9]*) fail "$name must be an integer, got: $value" ;;
    esac
    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        fail "$name must be between 1 and 65535"
    fi
}

: "${ONION_PUBLIC_PORT:?ONION_PUBLIC_PORT is required}"
: "${ONION_SSH_PORT:?ONION_SSH_PORT is required}"
validate_port ONION_PUBLIC_PORT "$ONION_PUBLIC_PORT"
validate_port ONION_SSH_PORT "$ONION_SSH_PORT"

[ "$ONION_SSH_PORT" = 2022 ] \
    || fail "ONION_SSH_PORT is release-managed and must equal 2022"

ONION_COMPAT_HIDDEN_SERVICE_PORT=''
if [ "$ONION_PUBLIC_PORT" != "$ONION_SSH_PORT" ]; then
    ONION_COMPAT_HIDDEN_SERVICE_PORT="HiddenServicePort ${ONION_PUBLIC_PORT} soft-serve:23231"
fi
export ONION_SSH_PORT ONION_COMPAT_HIDDEN_SERVICE_PORT

umask 077
mkdir -p /var/lib/tor/hidden_service /run/hidden-git
# The Tor target is intentionally fixed in the managed template. Port 2022 is
# mandatory release policy; the historical/configured public port remains a
# compatibility alias only when it is distinct.
# shellcheck disable=SC2016
envsubst '${ONION_SSH_PORT} ${ONION_COMPAT_HIDDEN_SERVICE_PORT}' \
    < /etc/tor/torrc.template \
    > /run/hidden-git/torrc

# Fail closed if a future template edit adds, removes, duplicates, or retargets
# a virtual SSH mapping.
expected_ports="HiddenServicePort ${ONION_SSH_PORT} soft-serve:23231"
if [ -n "$ONION_COMPAT_HIDDEN_SERVICE_PORT" ]; then
    expected_ports="${expected_ports}
${ONION_COMPAT_HIDDEN_SERVICE_PORT}"
fi
actual_ports="$(grep '^HiddenServicePort ' /run/hidden-git/torrc || true)"
[ "$actual_ports" = "$expected_ports" ] \
    || fail "managed Tor virtual-port topology is missing, duplicated, or inconsistent"

tor --verify-config -f /run/hidden-git/torrc
exec tor -f /run/hidden-git/torrc
