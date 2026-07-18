#!/bin/sh
set -eu

: "${ONION_PUBLIC_PORT:?ONION_PUBLIC_PORT is required}"
: "${SOFT_SERVE_SSH_USER:=admin}"
: "${CHECK_TIMEOUT_SECONDS:=180}"
: "${SSH_ATTEMPT_TIMEOUT_SECONDS:=20}"

case "$ONION_PUBLIC_PORT" in
    ''|*[!0-9]*) printf 'invalid ONION_PUBLIC_PORT: %s\n' "$ONION_PUBLIC_PORT" >&2; exit 2 ;;
esac
case "$CHECK_TIMEOUT_SECONDS" in
    ''|*[!0-9]*) printf 'invalid CHECK_TIMEOUT_SECONDS: %s\n' "$CHECK_TIMEOUT_SECONDS" >&2; exit 2 ;;
esac
case "$SSH_ATTEMPT_TIMEOUT_SECONDS" in
    ''|*[!0-9]*) printf 'invalid SSH_ATTEMPT_TIMEOUT_SECONDS: %s\n' "$SSH_ATTEMPT_TIMEOUT_SECONDS" >&2; exit 2 ;;
esac
[ "$CHECK_TIMEOUT_SECONDS" -gt 0 ] || { printf 'CHECK_TIMEOUT_SECONDS must be positive\n' >&2; exit 2; }
[ "$SSH_ATTEMPT_TIMEOUT_SECONDS" -gt 0 ] || { printf 'SSH_ATTEMPT_TIMEOUT_SECONDS must be positive\n' >&2; exit 2; }

known_hosts="$(mktemp)"
trap 'rm -f "$known_hosts"' EXIT HUP INT TERM

deadline=$(( $(date +%s) + CHECK_TIMEOUT_SECONDS ))
last_output=''

while [ "$(date +%s)" -lt "$deadline" ]; do
    host="$(cat /var/lib/tor/hidden_service/hostname 2>/dev/null || true)"
    if [ -z "$host" ]; then
        sleep 3
        continue
    fi

    set -- ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=12 \
        -o IdentitiesOnly=yes \
        -o KbdInteractiveAuthentication=no \
        -o PasswordAuthentication=no \
        -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=$known_hosts"
    if [ -n "${SSH_IDENTITY_FILE:-}" ]; then
        [ -r "$SSH_IDENTITY_FILE" ] || { printf 'SSH identity is not readable: %s\n' "$SSH_IDENTITY_FILE" >&2; exit 2; }
        set -- "$@" -i "$SSH_IDENTITY_FILE"
    fi
    set -- "$@" \
        -p "$ONION_PUBLIC_PORT" \
        "$SOFT_SERVE_SSH_USER@$host" help

    if last_output="$(timeout --signal=TERM "${SSH_ATTEMPT_TIMEOUT_SECONDS}s" torsocks "$@" 2>&1)"; then
        printf '%s\n' "$last_output"
        exit 0
    fi

    if printf '%s\n' "$last_output" | grep -Eq 'Permission denied|Connection closed|Soft Serve|Usage:|Available Commands:'; then
        printf '%s\n' "$last_output"
        exit 0
    fi

    sleep 3
done

printf 'onion SSH check timed out after %ss\n' "$CHECK_TIMEOUT_SECONDS" >&2
[ -z "$last_output" ] || printf '%s\n' "$last_output" >&2
exit 1

