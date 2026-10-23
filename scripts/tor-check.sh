#!/bin/sh
set -eu

: "${ONION_SSH_PORT:?ONION_SSH_PORT is required}"
: "${ONION_CHECK_PORT:=$ONION_SSH_PORT}"
: "${SOFT_SERVE_SSH_USER:=admin}"
: "${CHECK_TIMEOUT_SECONDS:=180}"
: "${SSH_ATTEMPT_TIMEOUT_SECONDS:=20}"

case "$ONION_CHECK_PORT" in
    ''|*[!0-9]*) printf 'invalid ONION_CHECK_PORT: %s\n' "$ONION_CHECK_PORT" >&2; exit 2 ;;
esac
if [ "$ONION_CHECK_PORT" -lt 1 ] || [ "$ONION_CHECK_PORT" -gt 65535 ]; then
    printf 'ONION_CHECK_PORT must be between 1 and 65535\n' >&2
    exit 2
fi
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
    authenticated_check=0
    if [ -n "${SSH_IDENTITY_FILE:-}" ]; then
        [ -r "$SSH_IDENTITY_FILE" ] || { printf 'SSH identity is not readable: %s\n' "$SSH_IDENTITY_FILE" >&2; exit 2; }
        set -- "$@" -i "$SSH_IDENTITY_FILE"
        authenticated_check=1
    fi
    set -- "$@" \
        -p "$ONION_CHECK_PORT" \
        "$SOFT_SERVE_SSH_USER@$host" help

    if last_output="$(timeout --signal=TERM "${SSH_ATTEMPT_TIMEOUT_SECONDS}s" torsocks "$@" 2>&1)"; then
        printf '%s\n' "$last_output"
        exit 0
    fi

    # Without an explicit identity this command is a reachability probe, so a
    # completed SSH handshake that reaches Soft Serve can be sufficient. When
    # a caller supplies SSH_IDENTITY_FILE (notably E2E), require the SSH command
    # itself to succeed: accepting "Permission denied" would false-pass an
    # authenticated qualification with the wrong key.
    if [ "$authenticated_check" -eq 0 ] && \
        printf '%s\n' "$last_output" | grep -Eq 'Permission denied|Connection closed|Soft Serve|Usage:|Available Commands:'; then
        printf '%s\n' "$last_output"
        exit 0
    fi

    sleep 3
done

printf 'onion SSH check timed out after %ss\n' "$CHECK_TIMEOUT_SECONDS" >&2
[ -z "$last_output" ] || printf '%s\n' "$last_output" >&2
exit 1

