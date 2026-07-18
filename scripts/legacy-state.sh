#!/bin/sh
set -eu

ROOT="${1:-/repo}"

describe() {
    label="$1"
    path="$2"
    full="$ROOT/$path"
    if [ ! -d "$full" ]; then
        printf '%-24s missing\n' "$label"
        return
    fi

    files="$(find "$full" -type f 2>/dev/null | wc -l)"
    bytes="$(du -sb "$full" 2>/dev/null | awk '{print $1}')"
    newest="$(find "$full" -type f -printf '%T@\n' 2>/dev/null | sort -nr | head -1)"
    if [ -n "$newest" ]; then
        newest="$(date -u -d "@${newest%.*}" '+%Y-%m-%dT%H:%M:%SZ')"
    else
        newest='none'
    fi
    printf '%-24s files=%s bytes=%s newest=%s\n' \
        "$label" "$files" "${bytes:-?}" "$newest"
}

compare() {
    label="$1"
    current="$ROOT/$2"
    legacy="$ROOT/$3"
    if [ ! -f "$current" ] || [ ! -f "$legacy" ]; then
        printf '%-24s unavailable\n' "$label"
    elif cmp -s "$current" "$legacy"; then
        printf '%-24s same\n' "$label"
    else
        printf '%-24s different\n' "$label"
    fi
}

describe current-soft-serve data/soft-serve
describe current-tor data/tor
describe legacy-soft-serve soft-serve-data
describe legacy-tor tor-data

compare database \
    data/soft-serve/soft-serve.db \
    soft-serve-data/soft-serve.db
compare ssh-host-identity \
    data/soft-serve/ssh/soft_serve_host_ed25519 \
    soft-serve-data/ssh/soft_serve_host_ed25519
compare onion-identity \
    data/tor/hidden_service/hs_ed25519_secret_key \
    tor-data/hidden_service/hs_ed25519_secret_key

printf '%s\n' 'No secret values were printed. Treat every "different" result as a separate deployment.'
