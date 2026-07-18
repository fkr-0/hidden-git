#!/bin/sh
set -eu

hostname_file=/var/lib/tor/hidden_service/hostname
cookie_file=/run/hidden-git/control_auth_cookie

[ -s "$hostname_file" ] && [ -s "$cookie_file" ] || exit 1
cookie="$(od -An -tx1 "$cookie_file" | tr -d ' \n')"
response="$(
    # The nested shell intentionally receives the cookie as positional argument 1.
    # shellcheck disable=SC2016
    timeout 5s bash -c '
        exec 3<>/dev/tcp/127.0.0.1/9051
        printf "AUTHENTICATE %s\r\nGETINFO status/bootstrap-phase\r\nQUIT\r\n" "$1" >&3
        cat <&3
    ' _ "$cookie"
)"
printf '%s\n' "$response" | grep -q 'PROGRESS=100'
