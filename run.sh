#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
COMPOSE_TOR_CHECK_OVERRIDE="${ROOT_DIR}/docker-compose.tor-check.override.yml"
ENV_FILE="${HIDDEN_GIT_ENV_FILE:-${ROOT_DIR}/.env}"
VERSION_FILE="${ROOT_DIR}/VERSION"
COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")
COMPOSE_CHECK=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" -f "${COMPOSE_TOR_CHECK_OVERRIDE}")
COMPOSE_MAINTENANCE=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" --profile maintenance)

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

runtime_is_rootless() {
    docker info --format '{{json .SecurityOptions}}' 2>/dev/null | grep -q 'rootless'
}

maintenance_output_uid() {
    if runtime_is_rootless; then
        printf '0\n'
    else
        id -u
    fi
}

maintenance_output_gid() {
    if runtime_is_rootless; then
        printf '0\n'
    else
        id -g
    fi
}

build_maintenance_image() {
    "${COMPOSE_MAINTENANCE[@]}" build maintenance >/dev/null
    local image
    image="$(docker image ls \
        --filter label=com.docker.compose.project=hidden-git \
        --filter label=com.docker.compose.service=maintenance \
        -q | head -n1)"
    [[ -n "$image" ]] || fail 'maintenance image was not produced'
    printf '%s\n' "$image"
}

set_env_value() {
    local key="$1"
    local value="$2"
    local tmp
    tmp="$(mktemp)"
    awk -v wanted="$key" -v replacement="$value" '
        BEGIN { found = 0 }
        $0 ~ "^" wanted "=" { print wanted "=" replacement; found = 1; next }
        { print }
        END { if (!found) print wanted "=" replacement }
    ' "$ENV_FILE" > "$tmp"
    cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
    chmod 600 "$ENV_FILE"
}

cmd_migrate_users() {
    require_runtime
    require_services_stopped
    ensure_runtime_directories
    local confirmation="${1:-}"
    if runtime_contains_state && [[ "$confirmation" != '--confirm-existing' ]]; then
        fail "existing data requires confirmation; first create and verify a backup, then run './run.sh migrate-users --confirm-existing'"
    fi
    OUTPUT_UID="$(id -u)" OUTPUT_GID="$(id -g)" \
        "${COMPOSE_MAINTENANCE[@]}" run --rm --build -T maintenance migrate-users
    runtime_ownership_ok \
        || fail "ownership migration did not produce the expected 10001:10001 and 10002:10002 owners"
    log "Runtime ownership migrated to the dedicated service users"
}

runtime_contains_state() {
    OUTPUT_UID="$(id -u)" OUTPUT_GID="$(id -g)" \
        "${COMPOSE_MAINTENANCE[@]}" run --rm --build -T maintenance has-state \
        >/dev/null 2>&1
}

runtime_ownership_ok() {
    OUTPUT_UID="$(maintenance_output_uid)" OUTPUT_GID="$(maintenance_output_gid)" \
        "${COMPOSE_MAINTENANCE[@]}" run --rm --build -T maintenance ownership-ok \
        >/dev/null 2>&1
}

ensure_runtime_ownership() {
    runtime_ownership_ok && return 0
    if runtime_contains_state; then
        fail "existing runtime data needs the explicit non-root migration; create an encrypted backup, then run './run.sh migrate-users --confirm-existing'"
    fi
    log "Fresh runtime directories need service ownership; applying the safe migration"
    cmd_migrate_users
}

sync_env_key_from_example() {
    local key="$1"
    local value tmp
    value="$(awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' \
        "$ROOT_DIR/env.example")"
    [[ -n "$value" ]] || fail "env.example has no value for $key"
    tmp="$(mktemp)"
    awk -v wanted="$key" -v replacement="$value" '
        BEGIN { found = 0 }
        $0 ~ "^" wanted "=" { print wanted "=" replacement; found = 1; next }
        { print }
        END { if (!found) print wanted "=" replacement }
    ' "$ENV_FILE" > "$tmp"
    cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
}

cmd_sync_pins() {
    [[ -f "$ENV_FILE" ]] || fail "environment file not found at $ENV_FILE"
    local backup key
    backup="${ENV_FILE}.pre-sync-$(date -u '+%Y%m%dT%H%M%SZ')"
    cp -p "$ENV_FILE" "$backup"
    for key in HIDDEN_GIT_VERSION ALPINE_IMAGE GO_IMAGE SOFT_SERVE_VERSION \
        SOFT_SERVE_WISH_VERSION SOFT_SERVE_GO_GIT_VERSION \
        SOFT_SERVE_GO_JOSE_VERSION SOFT_SERVE_X_CRYPTO_VERSION \
        SOFT_SERVE_X_NET_VERSION TRIVY_IMAGE BUILDKIT_IMAGE DIND_ROOTLESS_IMAGE; do
        sync_env_key_from_example "$key"
    done
    sed -i '/^DEBIAN_IMAGE=/d' "$ENV_FILE"
    chmod 600 "$ENV_FILE" "$backup"
    log "Updated reviewed release references in $ENV_FILE"
    log "Previous environment saved at $backup"
}

cmd_evidence() {
    require_runtime
    validate_environment
    "$ROOT_DIR/scripts/release-evidence.sh" "${1:-}"
}

# shellcheck source=scripts/operator-ui.sh
source "${ROOT_DIR}/scripts/operator-ui.sh"

validate_positive_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be a positive integer, got: $value"
    ((value >= 1)) || fail "$name must be greater than zero"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

project_version() {
    tr -d '[:space:]' < "${VERSION_FILE}"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

require_runtime() {
    require_cmd docker
    docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required"
    [[ -f "${ENV_FILE}" ]] || fail "environment file not found at ${ENV_FILE}; run './run.sh init' first"
}

has_oniux() {
    command -v oniux >/dev/null 2>&1
}

read_env_value() {
    local key="$1"
    awk -v wanted="$key" '
        {
            line = $0
            sub(/\r$/, "", line)
            sub(/^[[:space:]]*/, "", line)
            if (line ~ "^" wanted "[[:space:]]*=") {
                sub(/^[^=]*=[[:space:]]*/, "", line)
                if (line ~ /^"/) {
                    sub(/^"/, "", line)
                    sub(/"[[:space:]]*(#.*)?$/, "", line)
                } else if (line ~ /^\047/) {
                    sub(/^\047/, "", line)
                    sub(/\047[[:space:]]*(#.*)?$/, "", line)
                } else {
                    sub(/[[:space:]]+#.*$/, "", line)
                    sub(/[[:space:]]*$/, "", line)
                }
                print line
                exit
            }
        }
    ' "${ENV_FILE}"
}

validate_port() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be an integer, got: $value"
    ((value >= 1 && value <= 65535)) || fail "$name must be between 1 and 65535"
}

validate_environment() {
    local name value
    for name in \
        SOFT_SERVE_SSH_PORT \
        SOFT_SERVE_HTTP_PORT \
        SOFT_SERVE_STATS_PORT \
        SOFT_SERVE_GIT_PORT \
        ONION_TARGET_PORT \
        ONION_PUBLIC_PORT; do
        value="$(read_env_value "$name")"
        [[ -n "$value" ]] || fail "$name is missing from .env"
        validate_port "$name" "$value"
    done

    value="$(read_env_value CHECK_TIMEOUT_SECONDS)"
    if [[ -n "$value" ]]; then
        validate_positive_integer CHECK_TIMEOUT_SECONDS "$value"
    fi

    local ssh_port onion_target data_path
    ssh_port="$(read_env_value SOFT_SERVE_SSH_PORT)"
    onion_target="$(read_env_value ONION_TARGET_PORT)"
    [[ "$ssh_port" == "$onion_target" ]] \
        || fail "ONION_TARGET_PORT must match SOFT_SERVE_SSH_PORT"

    data_path="$(read_env_value SOFT_SERVE_DATA_PATH)"
    [[ "$data_path" == /* ]] || fail "SOFT_SERVE_DATA_PATH must be absolute"

}

validate_first_boot_admin() {
    local admin_keys
    admin_keys="$(read_env_value SOFT_SERVE_INITIAL_ADMIN_KEYS)"
    if ! runtime_contains_state && [[ -z "$admin_keys" ]]; then
        fail "SOFT_SERVE_INITIAL_ADMIN_KEYS is required before first boot"
    fi
}

ensure_runtime_directories() {
    mkdir -p "${ROOT_DIR}/data/soft-serve" "${ROOT_DIR}/data/tor" "${ROOT_DIR}/backups"
    chmod 700 "${ROOT_DIR}/data" "${ROOT_DIR}/data/soft-serve" \
        "${ROOT_DIR}/data/tor" "${ROOT_DIR}/backups" 2>/dev/null || true
}

require_services_stopped() {
    local running
    running="$("${COMPOSE[@]}" ps -q --status running 2>/dev/null || true)"
    [[ -z "$running" ]] \
        || fail "this operation requires a stopped stack; run './run.sh down' first"
}

tor_hostname() {
    "${COMPOSE[@]}" exec -T tor sh -lc \
        'cat /var/lib/tor/hidden_service/hostname 2>/dev/null || true' \
        2>/dev/null || true
}

wait_for_hostname() {
    local timeout_s="${1:-90}"
    local elapsed=0

    while ((elapsed < timeout_s)); do
        local host
        host="$(tor_hostname | tr -d '\r\n')"
        if [[ -n "$host" ]]; then
            printf '%s\n' "$host"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}

run_tor_ssh_check_task() {
    [[ -f "${COMPOSE_TOR_CHECK_OVERRIDE}" ]] \
        || fail "Tor check override not found at ${COMPOSE_TOR_CHECK_OVERRIDE}"
    "${COMPOSE_CHECK[@]}" --profile check run --rm --build tor-check
}

is_onion_ssh_connectable() {
    local host="$1"
    local onion_port ssh_user known_hosts output rc
    onion_port="$(read_env_value ONION_PUBLIC_PORT)"
    ssh_user="$(read_env_value SOFT_SERVE_SSH_USER)"
    [[ -n "$ssh_user" ]] || ssh_user="admin"
    validate_port ONION_PUBLIC_PORT "$onion_port"

    known_hosts="$(mktemp)"
    set +e
    output="$(timeout --signal=TERM 20s oniux ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=12 \
        -o IdentitiesOnly=yes \
        -o KbdInteractiveAuthentication=no \
        -o PasswordAuthentication=no \
        -o StrictHostKeyChecking=accept-new \
        -o "UserKnownHostsFile=${known_hosts}" \
        -p "${onion_port}" \
        "${ssh_user}@${host}" help 2>&1)"
    rc=$?
    set -e
    rm -f "$known_hosts"

    if [[ $rc -eq 0 ]]; then
        return 0
    fi
    if printf '%s\n' "$output" | grep -Eq \
        'Permission denied|Connection closed|Soft Serve|Usage:|Available Commands:'; then
        return 0
    fi
    return 1
}

wait_for_onion_ssh() {
    local host="$1"
    local timeout_s="${2:-180}"
    local elapsed=0

    while ((elapsed < timeout_s)); do
        if is_onion_ssh_connectable "$host"; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    return 1
}

verify_onion_ssh_connectivity() {
    local host="$1"
    local timeout_s
    timeout_s="$(read_env_value CHECK_TIMEOUT_SECONDS)"
    [[ -n "$timeout_s" ]] || timeout_s=180

    if has_oniux; then
        log "oniux detected; verifying SSH connectivity through the onion service"
        if wait_for_onion_ssh "$host" "$timeout_s"; then
            return 0
        fi
        log "oniux check timed out; retrying through the containerized torsocks checker"
    else
        log "oniux not found; using the containerized torsocks checker"
    fi

    run_tor_ssh_check_task
}

cmd_init() {
    if [[ -e "${ENV_FILE}" ]]; then
        fail "environment file already exists at ${ENV_FILE}; refusing to overwrite it"
    fi
    install -m 600 "${ROOT_DIR}/env.example" "${ENV_FILE}"
    ensure_runtime_directories
    log "Created ${ENV_FILE} and private runtime directories"
    log "Set SOFT_SERVE_INITIAL_ADMIN_KEYS in ${ENV_FILE} before running './run.sh up'"
}

cmd_up() {
    require_runtime
    validate_environment
    validate_first_boot_admin
    ensure_runtime_directories
    cmd_doctor
    ensure_runtime_ownership
    log "Starting services"
    "${COMPOSE[@]}" up -d --build --wait
    log "Services are healthy; waiting for onion hostname"
    local host
    host="$(wait_for_hostname 180 | tr -d '\r\n')" \
        || fail "timed out waiting for hidden service hostname"
    log "Hidden service hostname: ${host}"
    verify_onion_ssh_connectivity "$host"
    log "Onion SSH connectivity check passed"
}

cmd_down() {
    require_runtime
    log "Stopping services"
    "${COMPOSE[@]}" down
}

cmd_build() {
    require_runtime
    validate_environment
    log "Building release images"
    "${COMPOSE_CHECK[@]}" --profile check --profile maintenance build
}

cmd_logs() {
    require_runtime
    "${COMPOSE[@]}" logs -f
}

cmd_ps() {
    require_runtime
    "${COMPOSE[@]}" ps
}

cmd_status() {
    require_runtime
    "${COMPOSE[@]}" ps
    local host onion_port ssh_port ssh_user
    host="$(tor_hostname | tr -d '\r\n')"
    onion_port="$(read_env_value ONION_PUBLIC_PORT)"
    ssh_port="$(read_env_value SOFT_SERVE_SSH_PORT)"
    ssh_user="$(read_env_value SOFT_SERVE_SSH_USER)"
    [[ -n "$ssh_user" ]] || ssh_user='admin'
    if [[ -n "$host" ]]; then
        log "Hidden service hostname: ${host}"
    else
        log "Hidden service hostname not available"
    fi
    if [[ -n "$onion_port" ]]; then
        log "Onion public SSH port: ${onion_port}"
    else
        log "Onion public SSH port is not configured"
    fi
    [[ -z "$ssh_port" ]] || log "Local SSH: ssh -p ${ssh_port} ${ssh_user}@127.0.0.1"
    if [[ -n "$host" && -n "$onion_port" ]]; then
        log "Onion SSH: oniux ssh -p ${onion_port} ${ssh_user}@${host}"
    fi
}

cmd_test() {
    require_runtime
    validate_environment
    local host
    host="$(wait_for_hostname 120 | tr -d '\r\n')" \
        || fail "timed out waiting for hidden service hostname"
    log "Hidden service hostname: ${host}"
    verify_onion_ssh_connectivity "$host"
    log "All live checks passed"
}

cmd_config() {
    require_runtime
    validate_environment
    "${COMPOSE_CHECK[@]}" --profile check config
}

cmd_doctor() {
    local strict=0
    if [[ "${1:-}" == '--strict' ]]; then
        strict=1
    elif [[ -n "${1:-}" ]]; then
        fail "doctor accepts only --strict"
    fi
    require_runtime
    validate_environment
    ensure_runtime_directories
    "${COMPOSE_CHECK[@]}" --profile check config >/dev/null
    log "Compose configuration is valid for HiddenGit $(project_version)"
    if has_oniux; then
        log "Optional oniux client check is available"
    else
        log "oniux is not installed; containerized torsocks checks will be used"
    fi
    run_best_practice_audit
    ((AUDIT_FAILURES == 0)) || return 1
    if ((strict == 1 && AUDIT_WARNINGS > 0)); then
        log "ERROR: strict doctor mode rejects best-practice warnings" >&2
        return 2
    fi
}

cmd_fix_permissions() {
    require_runtime
    chmod 600 "$ENV_FILE"
    OUTPUT_UID="$(maintenance_output_uid)" OUTPUT_GID="$(maintenance_output_gid)" \
        "${COMPOSE_MAINTENANCE[@]}" run --rm --build -T maintenance permissions
    log "Applied private permissions to .env, runtime data, and backups"
}

cmd_backup_keygen() {
    require_runtime
    ensure_runtime_directories
    local target="${1:-${ROOT_DIR}/backups/backup-identity.agekey}"
    target="$(realpath -m "$target")"
    mkdir -p "$(dirname "$target")"
    OUTPUT_UID="$(maintenance_output_uid)" OUTPUT_GID="$(maintenance_output_gid)" \
        "${COMPOSE_MAINTENANCE[@]}" run --rm --build -T \
        -v "$(dirname "$target"):/keys" \
        maintenance keygen "/keys/$(basename "$target")"
    log "Keep the identity file offline; configure only its public recipient in .env"
}

backup_state_layout() {
    local label="$1"
    local soft_serve_dir="$2"
    local tor_dir="$3"
    local recipient="$4"
    [[ -d "$soft_serve_dir" ]] || fail "Soft Serve state directory not found: $soft_serve_dir"
    [[ -d "$tor_dir" ]] || fail "Tor state directory not found: $tor_dir"

    local image output archive_name
    image="$(build_maintenance_image)"
    output="$(docker run --rm --network none \
        -v "$soft_serve_dir:/hidden-git/data/soft-serve:ro" \
        -v "$tor_dir:/hidden-git/data/tor:ro" \
        -v "$ROOT_DIR/backups:/hidden-git/backups" \
        -e "BACKUP_RECIPIENT=${recipient}" \
        -e "BACKUP_LABEL=${label}" \
        -e "OUTPUT_UID=$(maintenance_output_uid)" \
        -e "OUTPUT_GID=$(maintenance_output_gid)" \
        "$image" backup)"
    archive_name="$(basename "$(tail -n1 <<<"$output")")"
    [[ -f "$ROOT_DIR/backups/$archive_name" ]] \
        || fail "backup command did not produce the expected archive"
    printf '%s\n' "$ROOT_DIR/backups/$archive_name"
}

cmd_backup_state() {
    require_runtime
    validate_environment
    require_services_stopped
    ensure_runtime_directories
    local layout="${1:-current}"
    local recipient="${2:-$(read_env_value BACKUP_RECIPIENT)}"
    [[ -n "$recipient" ]] \
        || fail "backup recipient missing; pass one or set BACKUP_RECIPIENT in .env"
    case "$layout" in
        current)
            backup_state_layout current "$ROOT_DIR/data/soft-serve" "$ROOT_DIR/data/tor" "$recipient"
            ;;
        legacy)
            backup_state_layout legacy "$ROOT_DIR/soft-serve-data" "$ROOT_DIR/tor-data" "$recipient"
            ;;
        *) fail "backup-state layout must be current or legacy" ;;
    esac
}

cmd_backup() {
    cmd_backup_state current "${1:-}"
}

cmd_verify_backup() {
    require_runtime
    local archive="${1:-}"
    local identity="${2:-$(read_env_value BACKUP_IDENTITY_FILE)}"
    [[ -n "$archive" && -n "$identity" ]] \
        || fail "usage: ./run.sh verify-backup <archive> <identity-file>"
    archive="$(realpath "$archive")"
    identity="$(realpath "$identity")"
    [[ -f "$archive" && -f "${archive}.sha256" ]] \
        || fail "backup archive or checksum sidecar is missing"
    [[ -f "$identity" ]] || fail "backup identity not found: $identity"

    local image
    image="$(build_maintenance_image)"
    docker run --rm --network none \
        -v "$archive:/run/backup.tar.age:ro" \
        -v "${archive}.sha256:/run/backup.tar.age.sha256:ro" \
        -v "$identity:/run/secrets/age-identity:ro" \
        -e VERIFY_ARCHIVE=/run/backup.tar.age \
        -e VERIFY_IDENTITY_FILE=/run/secrets/age-identity \
        "$image" verify
}

cmd_restore() {
    require_runtime
    validate_environment
    require_services_stopped
    ensure_runtime_directories
    local archive="${1:-}"
    local identity="${2:-$(read_env_value BACKUP_IDENTITY_FILE)}"
    local mode="${3:-preserve}"
    [[ -n "$archive" ]] || fail "usage: ./run.sh restore <archive> <identity-file> [preserve|rotate]"
    [[ -n "$identity" ]] || fail "restore identity missing; pass its file path or set BACKUP_IDENTITY_FILE"
    archive="$(realpath "$archive")"
    identity="$(realpath "$identity")"
    [[ -f "$archive" ]] || fail "backup archive not found: $archive"
    [[ -f "$identity" ]] || fail "backup identity not found: $identity"
    [[ -f "${archive}.sha256" ]] || fail "backup checksum sidecar not found: ${archive}.sha256"
    [[ "$mode" == preserve || "$mode" == rotate ]] \
        || fail "restore mode must be preserve or rotate"
    OUTPUT_UID="$(maintenance_output_uid)" OUTPUT_GID="$(maintenance_output_gid)" \
        "${COMPOSE_MAINTENANCE[@]}" run --rm --build -T \
        -v "$archive:/run/backup.tar.age:ro" \
        -v "${archive}.sha256:/run/backup.tar.age.sha256:ro" \
        -v "$identity:/run/secrets/age-identity:ro" \
        -e RESTORE_ARCHIVE=/run/backup.tar.age \
        -e RESTORE_IDENTITY_FILE=/run/secrets/age-identity \
        -e "RESTORE_MODE=${mode}" maintenance restore
    log "Run './run.sh doctor --strict' before starting the restored deployment"
}

cmd_issues() {
    printf 'HiddenGit issue status\n'
    printf '%s\n' '────────────────────────────────────────────────────────────────────'
    awk '
        function emit() {
            if (id != "") printf "%-8s %-12s %-8s %s\n", id, status, priority, title
        }
        /^  - id:/ { emit(); id=$3; title=""; status=""; priority=""; next }
        /^    title:/ { sub(/^    title: /, ""); title=$0; next }
        /^    status:/ { status=$2; next }
        /^    priority:/ { priority=$2; next }
        END { emit() }
    ' "$ROOT_DIR/issues.yml"
    printf '%s\n' '────────────────────────────────────────────────────────────────────'
    printf '%s\n' 'All 0.0.3 release blockers are closed.'
    printf '%s\n' 'HG-003 remains an optional defense-in-depth feature for a later release.'
}

cmd_legacy_state() {
    require_runtime
    local image
    image="$(read_env_value ALPINE_IMAGE)"
    [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] \
        || fail "ALPINE_IMAGE must be digest-pinned; run './run.sh sync-pins'"

    docker run --rm --network none \
        -v "$ROOT_DIR:/repo:ro" \
        -v "$ROOT_DIR/scripts/legacy-state.sh:/usr/local/bin/hidden-git-legacy-state:ro" \
        "$image" /usr/local/bin/hidden-git-legacy-state /repo
}

state_inventory_json() (
    local require_legacy="${1:-0}"
    local image tmp output_uid output_gid
    image="$(read_env_value ALPINE_IMAGE)"
    [[ "$image" =~ @sha256:[0-9a-f]{64}$ ]] \
        || fail "ALPINE_IMAGE must be digest-pinned; run './run.sh sync-pins'"
    tmp="$(mktemp -d)"
    output_uid="$(maintenance_output_uid)"
    output_gid="$(maintenance_output_gid)"
    trap 'rm -rf "${tmp:-}"' EXIT

    docker run --rm --network none \
        -v "$ROOT_DIR:/repo:ro" \
        -v "$tmp:/out" \
        -e "OUTPUT_UID=$output_uid" \
        -e "OUTPUT_GID=$output_gid" \
        "$image" sh -ec '
            for suffix in "" -wal -shm; do
                source="/repo/data/soft-serve/soft-serve.db${suffix}"
                [ ! -f "$source" ] || cp "$source" "/out/current.db${suffix}"
            done
            if [ -f /repo/soft-serve-data/soft-serve.db ]; then
                for suffix in "" -wal -shm; do
                    source="/repo/soft-serve-data/soft-serve.db${suffix}"
                    [ ! -f "$source" ] || cp "$source" "/out/legacy.db${suffix}"
                done
            fi
            chown "$OUTPUT_UID:$OUTPUT_GID" /out/*.db* 2>/dev/null || true
            chmod 600 /out/*.db*
        '

    if [[ "$require_legacy" == 1 && ! -f "$tmp/legacy.db" ]]; then
        fail 'legacy Soft Serve database is not present'
    fi
    local args=("current=$tmp/current.db")
    [[ ! -f "$tmp/legacy.db" ]] || args+=("legacy=$tmp/legacy.db")
    python3 "$ROOT_DIR/scripts/state-inventory.py" "${args[@]}"
)

cmd_state_inventory() {
    require_runtime
    require_services_stopped
    state_inventory_json 0
}

cmd_reconcile_state() {
    require_runtime
    validate_environment
    require_services_stopped
    [[ "${1:-}" == '--confirm-current-authoritative' ]] \
        || fail "usage: ./run.sh reconcile-state --confirm-current-authoritative [identity-file]"
    [[ -d "$ROOT_DIR/soft-serve-data" && -d "$ROOT_DIR/tor-data" ]] \
        || fail 'legacy soft-serve-data/ and tor-data/ directories are both required'

    local identity inventory current_repos legacy_repos recipient
    identity="${2:-$ROOT_DIR/backups/reconciliation-identity.agekey}"
    identity="$(realpath -m "$identity")"
    inventory="$(state_inventory_json 1)"
    read -r current_repos legacy_repos < <(
        python3 -c '
import json, sys
d=json.load(sys.stdin)["deployments"]
print(d["current"]["repository_count"], d["legacy"]["repository_count"])
' <<<"$inventory"
    )
    if ((legacy_repos > 0)); then
        fail "legacy deployment contains ${legacy_repos} repositories; export and import them before archiving"
    fi
    log "State inventory: current repositories=${current_repos}, legacy repositories=${legacy_repos}"
    log 'No unique legacy repositories require migration'

    if [[ ! -f "$identity" ]]; then
        cmd_backup_keygen "$identity"
    fi
    [[ -f "${identity}.recipient" ]] \
        || fail "backup recipient file is missing: ${identity}.recipient"
    recipient="$(tr -d '\r\n' < "${identity}.recipient")"
    [[ "$recipient" == age1* ]] || fail 'generated backup recipient is invalid'
    set_env_value BACKUP_RECIPIENT "$recipient"
    set_env_value BACKUP_IDENTITY_FILE "$identity"

    local current_archive legacy_archive
    current_archive="$(cmd_backup_state current "$recipient")"
    legacy_archive="$(cmd_backup_state legacy "$recipient")"
    cmd_verify_backup "$current_archive" "$identity" >/dev/null
    cmd_verify_backup "$legacy_archive" "$identity" >/dev/null
    log "Verified current backup: $current_archive"
    log "Verified legacy backup: $legacy_archive"

    local timestamp archive_name archive_dir image output_uid output_gid report
    timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
    archive_name="legacy-${timestamp}"
    archive_dir="$ROOT_DIR/retired-state/$archive_name"
    image="$(read_env_value ALPINE_IMAGE)"
    output_uid="$(maintenance_output_uid)"
    output_gid="$(maintenance_output_gid)"
    docker run --rm --network none \
        -v "$ROOT_DIR:/repo" \
        -e "ARCHIVE_NAME=$archive_name" \
        -e "OUTPUT_UID=$output_uid" \
        -e "OUTPUT_GID=$output_gid" \
        "$image" sh -ec '
            umask 077
            test -d /repo/soft-serve-data
            test -d /repo/tor-data
            mkdir -p "/repo/retired-state/$ARCHIVE_NAME"
            mv /repo/soft-serve-data "/repo/retired-state/$ARCHIVE_NAME/"
            mv /repo/tor-data "/repo/retired-state/$ARCHIVE_NAME/"
            chown "$OUTPUT_UID:$OUTPUT_GID" /repo/retired-state "/repo/retired-state/$ARCHIVE_NAME" 2>/dev/null || true
            chmod 700 /repo/retired-state "/repo/retired-state/$ARCHIVE_NAME"
        '

    report="$archive_dir/RECONCILIATION.json"
    INVENTORY_JSON="$inventory" \
        python3 - "$report" "$current_archive" "$legacy_archive" "$timestamp" <<'PY'
import json
import os
import pathlib
import sys

inventory = json.loads(os.environ["INVENTORY_JSON"])
report = {
    "schema_version": 1,
    "reconciled_at": sys.argv[4],
    "authoritative_layout": "data/",
    "retired_layout": "soft-serve-data/ + tor-data/",
    "decision": "current layout is configured, newer, and legacy contains no repositories",
    "repository_migration": "not required",
    "backups": {
        "current": pathlib.Path(sys.argv[2]).name,
        "legacy": pathlib.Path(sys.argv[3]).name,
    },
    "inventory": inventory,
}
path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
path.chmod(0o600)
PY

    cmd_migrate_users --confirm-existing >/dev/null
    log "Archived retired deployment at $archive_dir"
    log 'Current data/ is authoritative and migrated to dedicated service ownership'
}

cmd_restart() {
    cmd_down
    cmd_up
}

usage() {
    cat <<USAGE
HiddenGit $(project_version)

Usage: $0 <command>

Commands:
  init      Create a private .env and runtime directories
  up        Build, start, wait for health, and verify onion SSH access
  down      Stop and remove services
  build     Build all release images
  logs      Follow Compose logs
  ps        Show service status
  status    Show service status, onion hostname, and public SSH port
  test      Verify live onion SSH access
  config    Render the fully interpolated Compose configuration
  doctor    Validate configuration and show actionable best-practice findings
  doctor --strict
            Fail when any best-practice warning remains
  fix-permissions
            Restrict .env, runtime data, and backup directory permissions
  sync-pins Update reviewed version and digest references without changing local ports
  migrate-users [--confirm-existing]
            Assign stable service UIDs; confirmation and a backup are required for existing data
  backup-keygen [identity-file]
            Generate an age backup identity and public recipient
  backup [recipient]
            Create an encrypted, integrity-checked offline backup
  backup-state <current|legacy> [recipient]
            Back up an explicitly selected deployment layout
  verify-backup <archive> <identity-file>
            Decrypt and verify a backup without restoring it
  restore <archive> <identity-file> [preserve|rotate]
            Restore only into empty data directories; optionally rotate onion identity
  evidence [output-directory]
            Generate SLSA provenance, SBOMs, and vulnerability reports
  issues    Show issue status and the recommended implementation order
  legacy-state
            Compare current and legacy runtime layouts without printing secrets
  state-inventory
            Report repository and user metadata from deployment databases
  reconcile-state --confirm-current-authoritative [identity-file]
            Back up both layouts, archive the empty legacy deployment, and migrate current ownership
  restart   Stop and start the stack
  version   Print the project version
  help      Show this help
USAGE
}

main() {
    local cmd="${1:-}"
    case "$cmd" in
        init) cmd_init ;;
        up) cmd_up ;;
        down) cmd_down ;;
        build) cmd_build ;;
        logs) cmd_logs ;;
        ps) cmd_ps ;;
        status) cmd_status ;;
        test) cmd_test ;;
        config) cmd_config ;;
        doctor) shift; cmd_doctor "$@" ;;
        fix-permissions) cmd_fix_permissions ;;
        sync-pins) cmd_sync_pins ;;
        migrate-users) shift; cmd_migrate_users "$@" ;;
        backup-keygen) shift; cmd_backup_keygen "$@" ;;
        backup) shift; cmd_backup "$@" ;;
        backup-state) shift; cmd_backup_state "$@" ;;
        verify-backup) shift; cmd_verify_backup "$@" ;;
        restore) shift; cmd_restore "$@" ;;
        evidence) shift; cmd_evidence "$@" ;;
        issues) cmd_issues ;;
        legacy-state) cmd_legacy_state ;;
        state-inventory) cmd_state_inventory ;;
        reconcile-state) shift; cmd_reconcile_state "$@" ;;
        restart) cmd_restart ;;
        version) project_version ;;
        help|-h|--help) usage ;;
        '') usage; exit 1 ;;
        *) usage; fail "unknown command: $cmd" ;;
    esac
}

main "$@"
