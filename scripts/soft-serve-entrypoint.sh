#!/bin/sh
set -eu

fail() {
    printf 'hidden-git soft-serve entrypoint: %s\n' "$*" >&2
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

SOFT_SERVE_DATA_PATH=/var/lib/soft-serve
SOFT_SERVE_INTERNAL_SSH_PORT=23231
: "${SOFT_SERVE_NAME:=HiddenGit}"
: "${LOCAL_SSH_PORT:=23231}"
validate_port LOCAL_SSH_PORT "$LOCAL_SSH_PORT"

# The clone hint is intentionally a public/host-facing value. It is not used to
# choose the container listener. Explicit proxy/onion URLs remain supported.
if [ -z "${SOFT_SERVE_SSH_PUBLIC_URL:-}" ]; then
    SOFT_SERVE_SSH_PUBLIC_URL="ssh://localhost:${LOCAL_SSH_PORT}"
fi

umask 077
mkdir -p "$SOFT_SERVE_DATA_PATH/ssh" /run/hidden-git

if [ ! -s "$SOFT_SERVE_DATA_PATH/soft-serve.db" ] && [ -z "${SOFT_SERVE_INITIAL_ADMIN_KEYS:-}" ]; then
    fail "SOFT_SERVE_INITIAL_ADMIN_KEYS must contain at least one SSH public key on first boot"
fi

export SOFT_SERVE_NAME SOFT_SERVE_SSH_PUBLIC_URL

config_path=/run/hidden-git/soft-serve.config.yaml
# Only product-level presentation values are substituted. Listener addresses,
# persistence paths, service enablement, and the Tor target are managed constants.
# shellcheck disable=SC2016
envsubst '${SOFT_SERVE_NAME} ${SOFT_SERVE_SSH_PUBLIC_URL}' \
    < /etc/hidden-git/soft-serve.config.yaml.template \
    > "$config_path"
export SOFT_SERVE_CONFIG_LOCATION="$config_path"

# Keep an explicit invariant check beside the launch path. The health check and
# Tor configuration use this same managed endpoint.
grep -Fq "listen_addr: \":${SOFT_SERVE_INTERNAL_SSH_PORT}\"" "$config_path" \
    || fail "managed SSH listener is missing from generated Soft Serve config"

exec /usr/local/bin/soft serve
