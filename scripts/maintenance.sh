#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT="${HIDDEN_GIT_DATA_ROOT:-/hidden-git/data}"
BACKUP_ROOT="${HIDDEN_GIT_BACKUP_ROOT:-/hidden-git/backups}"
OUTPUT_UID="${OUTPUT_UID:-0}"
OUTPUT_GID="${OUTPUT_GID:-0}"
SOFT_SERVE_UID=10001
SOFT_SERVE_GID=10001
TOR_UID=10002
TOR_GID=10002

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

cmd_ownership_ok() {
    [[ "$(stat -c '%u:%g' "$DATA_ROOT/soft-serve")" == "$SOFT_SERVE_UID:$SOFT_SERVE_GID" ]]
    [[ "$(stat -c '%u:%g' "$DATA_ROOT/tor")" == "$TOR_UID:$TOR_GID" ]]
}

cmd_has_state() {
    find "$DATA_ROOT/soft-serve" "$DATA_ROOT/tor" \
        -mindepth 1 \( -type f -o -type l \) -print -quit 2>/dev/null \
        | grep -q .
}

cmd_migrate_users() {
    cmd_permissions
    chown -R "$SOFT_SERVE_UID:$SOFT_SERVE_GID" "$DATA_ROOT/soft-serve"
    chown -R "$TOR_UID:$TOR_GID" "$DATA_ROOT/tor"
    chmod 700 "$DATA_ROOT/soft-serve" "$DATA_ROOT/tor"
    printf 'Soft Serve ownership: %s:%s\n' "$SOFT_SERVE_UID" "$SOFT_SERVE_GID"
    printf 'Tor ownership: %s:%s\n' "$TOR_UID" "$TOR_GID"
}

chown_output() {
    chown "$OUTPUT_UID:$OUTPUT_GID" "$@" 2>/dev/null || true
}

cmd_permissions() {
    mkdir -p "$DATA_ROOT/soft-serve" "$DATA_ROOT/tor" "$BACKUP_ROOT"
    chmod 700 "$DATA_ROOT" "$DATA_ROOT/soft-serve" "$DATA_ROOT/tor" "$BACKUP_ROOT"
}

cmd_keygen() {
    local identity="${1:-/hidden-git/backups/backup-identity.agekey}"
    local recipient="${identity}.recipient"
    [[ ! -e "$identity" && ! -e "$recipient" ]] \
        || die 'refusing to overwrite existing backup identity'
    mkdir -p "$(dirname "$identity")"
    age-keygen -o "$identity"
    age-keygen -y "$identity" > "$recipient"
    chmod 600 "$identity"
    chmod 644 "$recipient"
    chown_output "$identity" "$recipient"
    printf 'Identity: %s\nRecipient: %s\n' "$identity" "$(cat "$recipient")"
}

cmd_backup() {
    local recipient="${BACKUP_RECIPIENT:-}"
    local label="${BACKUP_LABEL:-current}"
    [[ -n "$recipient" ]] || die 'BACKUP_RECIPIENT is required'
    [[ "$label" =~ ^[a-z0-9][a-z0-9._-]*$ ]] \
        || die 'BACKUP_LABEL must contain only lowercase letters, digits, dots, underscores, or hyphens'
    [[ -d "$DATA_ROOT/soft-serve" && -d "$DATA_ROOT/tor" ]] \
        || die 'runtime data directories do not exist'

    local timestamp archive tmp metadata_dir parent data_name
    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT"
    archive="$BACKUP_ROOT/hidden-git-${label}-backup-${timestamp}.tar.age"
    tmp="${archive}.tmp"
    metadata_dir="$(mktemp -d)"
    parent="$(dirname "$DATA_ROOT")"
    data_name="$(basename "$DATA_ROOT")"
    trap 'rm -rf "$metadata_dir" "$tmp"' EXIT

    (
        cd "$parent"
        find "$data_name/soft-serve" "$data_name/tor" -type f -print0 \
            | sort -z \
            | xargs -0 -r sha256sum
    ) > "$metadata_dir/MANIFEST.sha256"
    {
        printf 'format=hidden-git-backup-v1\n'
        printf 'created_at=%s\n' "$timestamp"
        printf 'source_label=%s\n' "$label"
        printf 'identity_policy=preserved-in-archive\n'
    } > "$metadata_dir/METADATA"

    tar -C "$parent" -cf - "$data_name/soft-serve" "$data_name/tor" \
        -C "$metadata_dir" MANIFEST.sha256 METADATA \
        | age -r "$recipient" -o "$tmp"
    mv "$tmp" "$archive"
    (
        cd "$BACKUP_ROOT"
        sha256sum "$(basename "$archive")" > "$(basename "$archive").sha256"
    )
    chmod 600 "$archive"
    chmod 644 "${archive}.sha256"
    chown_output "$archive" "${archive}.sha256"
    trap - EXIT
    rm -rf "$metadata_dir"
    printf '%s\n' "$archive"
}

verify_checksum_sidecar() {
    local archive="$1"
    [[ -f "$archive" ]] || die "backup archive not found: $archive"
    if [[ -f "${archive}.sha256" ]]; then
        local expected actual
        expected="$(awk 'NR==1{print $1}' "${archive}.sha256")"
        actual="$(sha256sum "$archive" | awk '{print $1}')"
        [[ -n "$expected" && "$actual" == "$expected" ]] \
            || die 'backup checksum sidecar verification failed'
    fi
}

verify_archive() {
    local archive="$1"
    local identity="$2"
    [[ -f "$identity" ]] || die "age identity not found: $identity"
    verify_checksum_sidecar "$archive"

    local stage
    stage="$(mktemp -d)"
    trap 'rm -rf "${stage:-}"' EXIT
    age --decrypt -i "$identity" "$archive" | tar -C "$stage" -xf -
    (cd "$stage" && sha256sum -c MANIFEST.sha256)
    grep -Fxq 'format=hidden-git-backup-v1' "$stage/METADATA" \
        || die 'unsupported backup format'
    printf 'Verified backup: %s\n' "$archive"
    rm -rf "$stage"
    trap - EXIT
}

cmd_verify() {
    local archive="${VERIFY_ARCHIVE:-}"
    local identity="${VERIFY_IDENTITY_FILE:-/run/secrets/age-identity}"
    verify_archive "$archive" "$identity"
}

directory_is_empty() {
    local path="$1"
    [[ ! -d "$path" ]] || [[ -z "$(find "$path" -mindepth 1 -print -quit)" ]]
}

cmd_restore() {
    local archive="${RESTORE_ARCHIVE:-}"
    local identity="${RESTORE_IDENTITY_FILE:-/run/secrets/age-identity}"
    local mode="${RESTORE_MODE:-preserve}"
    [[ -f "$archive" ]] || die "backup archive not found: $archive"
    [[ -f "$identity" ]] || die "age identity not found: $identity"
    [[ "$mode" == preserve || "$mode" == rotate ]] \
        || die 'RESTORE_MODE must be preserve or rotate'
    directory_is_empty "$DATA_ROOT/soft-serve" \
        || die 'restore target data/soft-serve is not empty'
    directory_is_empty "$DATA_ROOT/tor" \
        || die 'restore target data/tor is not empty'
    verify_checksum_sidecar "$archive"

    local stage
    stage="$(mktemp -d)"
    trap 'rm -rf "${stage:-}"' EXIT
    age --decrypt -i "$identity" "$archive" | tar -C "$stage" -xf -
    (cd "$stage" && sha256sum -c MANIFEST.sha256)
    grep -Fxq 'format=hidden-git-backup-v1' "$stage/METADATA" \
        || die 'unsupported backup format'

    if [[ "$mode" == rotate ]]; then
        rm -rf "$stage/data/tor/hidden_service"
    fi

    mkdir -p "$DATA_ROOT/soft-serve" "$DATA_ROOT/tor"
    cp -a "$stage/data/soft-serve/." "$DATA_ROOT/soft-serve/"
    cp -a "$stage/data/tor/." "$DATA_ROOT/tor/"
    chmod 700 "$DATA_ROOT" "$DATA_ROOT/soft-serve" "$DATA_ROOT/tor"
    rm -rf "$stage"
    trap - EXIT
    printf 'Restore complete (onion identity mode: %s)\n' "$mode"
}

case "${1:-}" in
    permissions) cmd_permissions ;;
    migrate-users) cmd_migrate_users ;;
    ownership-ok) cmd_ownership_ok ;;
    has-state) cmd_has_state ;;
    keygen) shift; cmd_keygen "$@" ;;
    backup) cmd_backup ;;
    verify) cmd_verify ;;
    restore) cmd_restore ;;
    *) die 'usage: maintenance.sh {permissions|migrate-users|ownership-ok|has-state|keygen|backup|verify|restore}' ;;
esac
