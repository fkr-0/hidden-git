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

: "${SOFT_SERVE_DATA_PATH:=/var/lib/soft-serve}"
: "${SOFT_SERVE_NAME:=HiddenGit}"
: "${SOFT_SERVE_SSH_PORT:=23231}"
: "${SOFT_SERVE_HTTP_PORT:=23232}"
: "${SOFT_SERVE_STATS_PORT:=23233}"
: "${SOFT_SERVE_GIT_PORT:=9418}"
: "${SOFT_SERVE_SSH_PUBLIC_URL:=ssh://localhost:${SOFT_SERVE_SSH_PORT}}"
: "${SOFT_SERVE_HTTP_PUBLIC_URL:=http://localhost:${SOFT_SERVE_HTTP_PORT}}"
: "${SOFT_SERVE_GIT_PUBLIC_URL:=git://localhost:${SOFT_SERVE_GIT_PORT}}"

validate_port SOFT_SERVE_SSH_PORT "$SOFT_SERVE_SSH_PORT"
validate_port SOFT_SERVE_HTTP_PORT "$SOFT_SERVE_HTTP_PORT"
validate_port SOFT_SERVE_STATS_PORT "$SOFT_SERVE_STATS_PORT"
validate_port SOFT_SERVE_GIT_PORT "$SOFT_SERVE_GIT_PORT"

case "$SOFT_SERVE_DATA_PATH" in
    /*) ;;
    *) fail "SOFT_SERVE_DATA_PATH must be absolute" ;;
esac

umask 077
mkdir -p "$SOFT_SERVE_DATA_PATH/ssh" /run/hidden-git

if [ ! -s "$SOFT_SERVE_DATA_PATH/soft-serve.db" ] && [ -z "${SOFT_SERVE_INITIAL_ADMIN_KEYS:-}" ]; then
    fail "SOFT_SERVE_INITIAL_ADMIN_KEYS must contain at least one SSH public key on first boot"
fi

export SOFT_SERVE_DATA_PATH SOFT_SERVE_NAME
export SOFT_SERVE_SSH_PORT SOFT_SERVE_HTTP_PORT SOFT_SERVE_STATS_PORT SOFT_SERVE_GIT_PORT
export SOFT_SERVE_SSH_PUBLIC_URL SOFT_SERVE_HTTP_PUBLIC_URL SOFT_SERVE_GIT_PUBLIC_URL

config_path=/run/hidden-git/soft-serve.config.yaml
envsubst < /etc/hidden-git/soft-serve.config.yaml.template > "$config_path"
export SOFT_SERVE_CONFIG_LOCATION="$config_path"

exec /usr/local/bin/soft serve

