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
    [ "$value" -ge 1 ] && [ "$value" -le 65535 ] || fail "$name must be between 1 and 65535"
}

: "${ONION_PUBLIC_PORT:?ONION_PUBLIC_PORT is required}"
: "${ONION_TARGET_PORT:?ONION_TARGET_PORT is required}"
validate_port ONION_PUBLIC_PORT "$ONION_PUBLIC_PORT"
validate_port ONION_TARGET_PORT "$ONION_TARGET_PORT"

umask 077
mkdir -p /var/lib/tor/hidden_service /run/hidden-git
# The literal variable allow-list is intentionally passed to envsubst.
# shellcheck disable=SC2016
envsubst '${ONION_PUBLIC_PORT} ${ONION_TARGET_PORT}' \
    < /etc/tor/torrc.template \
    > /run/hidden-git/torrc

tor --verify-config -f /run/hidden-git/torrc
exec tor -f /run/hidden-git/torrc

