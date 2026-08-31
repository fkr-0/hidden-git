#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
COMPOSE_TOR_CHECK_OVERRIDE="${ROOT_DIR}/docker-compose.tor-check.override.yml"
ENV_FILE="${HIDDEN_GIT_ENV_FILE:-${ROOT_DIR}/.env}"
VERSION_FILE="${ROOT_DIR}/VERSION"
CONFIG_SCHEMA="${ROOT_DIR}/config/schema.json"
RELEASE_FILE="${ROOT_DIR}/config/release.env"
CONFIG_CTL="${ROOT_DIR}/scripts/configctl.py"
RELEASE_KEYS=(ALPINE_IMAGE GO_IMAGE SOFT_SERVE_VERSION ONION_SSH_PORT TRIVY_IMAGE BUILDKIT_IMAGE DIND_ROOTLESS_IMAGE)
COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")
COMPOSE_CHECK=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" -f "${COMPOSE_TOR_CHECK_OVERRIDE}")
COMPOSE_MAINTENANCE=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" --profile maintenance)
AUTOBOOT_SERVICE_NAME='hidden-git-autoboot.service'
AUTOBOOT_TIMER_NAME='hidden-git-autoboot.timer'
AUTOBOOT_SERVICE_TEMPLATE="${ROOT_DIR}/systemd/${AUTOBOOT_SERVICE_NAME}.template"
AUTOBOOT_TIMER_TEMPLATE="${ROOT_DIR}/systemd/${AUTOBOOT_TIMER_NAME}"
AUTOBOOT_MANAGED_MARKER='# Managed by HiddenGit autoboot'

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

autoboot_docker_context() {
    [[ -z "${DOCKER_HOST:-}" ]] \
        || fail 'autoboot cannot persist an ad-hoc DOCKER_HOST; select a durable Docker context (docker context use <name>) and unset DOCKER_HOST first'
    local context
    context="$(docker context show 2>/dev/null || true)"
    [[ "$context" =~ ^[A-Za-z0-9_.-]+$ ]] \
        || fail 'autoboot requires a named persistent Docker context'
    printf '%s\n' "$context"
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
    require_release_runtime
    local image alpine_image
    alpine_image="$(release_value ALPINE_IMAGE)"
    image="$(docker build -q \
        --build-arg "ALPINE_IMAGE=${alpine_image}" \
        -f "$ROOT_DIR/Dockerfile.maintenance" "$ROOT_DIR")"
    [[ -n "$image" ]] || fail 'maintenance image was not produced'
    printf '%s\n' "$image"
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

cmd_sync_pins() {
    require_env_file
    require_cmd python3
    validate_environment
    log "Release pins are tracked in $RELEASE_FILE and already validated"
    log "sync-pins is compatibility-only in config v2; no .env bytes were changed"
}

cmd_evidence() {
    require_release_runtime
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

require_env_file() {
    [[ -f "${ENV_FILE}" ]] || fail "environment file not found at ${ENV_FILE}; run './run.sh init' first"
}

configctl_base() {
    python3 "$CONFIG_CTL" --env "$ENV_FILE" --schema "$CONFIG_SCHEMA" \
        --template "$ROOT_DIR/env.example" --release-file "$RELEASE_FILE" "$@"
}

config_value() {
    configctl_base get "$1"
}

release_value() {
    python3 "$CONFIG_CTL" --schema "$CONFIG_SCHEMA" --release-file "$RELEASE_FILE" \
        release get "$1"
}

validate_release_metadata() {
    python3 "$CONFIG_CTL" --schema "$CONFIG_SCHEMA" --release-file "$RELEASE_FILE" \
        release check >/dev/null
}

load_release_environment() {
    local key value
    for key in "${RELEASE_KEYS[@]}"; do
        value="$(release_value "$key")" || fail "tracked release metadata is invalid"
        export "$key=$value"
    done
}

require_docker() {
    require_cmd docker
    docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 is required"
}

require_release_runtime() {
    require_cmd python3
    validate_release_metadata || fail "tracked release metadata is invalid"
    load_release_environment
    require_docker
}

require_runtime() {
    require_env_file
    require_cmd python3
    validate_environment
    load_release_environment
    require_docker
}

has_oniux() {
    command -v oniux >/dev/null 2>&1
}

validate_port() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be an integer, got: $value"
    ((value >= 1 && value <= 65535)) || fail "$name must be between 1 and 65535"
}

validate_environment() {
    require_cmd python3
    if ! configctl_base check; then
        fail "configuration is not canonical; run './run.sh config migrate' for a secret-safe preview"
    fi
}

validate_first_boot_admin() {
    local admin_keys
    admin_keys="$(config_value SOFT_SERVE_INITIAL_ADMIN_KEYS)"
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
    local onion_port="$1"
    [[ -f "${COMPOSE_TOR_CHECK_OVERRIDE}" ]] \
        || fail "Tor check override not found at ${COMPOSE_TOR_CHECK_OVERRIDE}"
    "${COMPOSE_CHECK[@]}" --profile check run --rm --build \
        -e "ONION_CHECK_PORT=${onion_port}" tor-check
}

is_onion_ssh_connectable() {
    local host="$1"
    local onion_port="$2"
    local ssh_user known_hosts output rc
    ssh_user="$(config_value SOFT_SERVE_SSH_USER)"
    [[ -n "$ssh_user" ]] || ssh_user="admin"
    validate_port ONION_CHECK_PORT "$onion_port"

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
    local onion_port="$2"
    local timeout_s="${3:-180}"
    local elapsed=0

    while ((elapsed < timeout_s)); do
        if is_onion_ssh_connectable "$host" "$onion_port"; then
            return 0
        fi
        sleep 3
        elapsed=$((elapsed + 3))
    done
    return 1
}

verify_onion_ssh_connectivity() {
    local host="$1"
    local timeout_s primary_port compat_port port
    local ports=()
    timeout_s="$(config_value CHECK_TIMEOUT_SECONDS)"
    [[ -n "$timeout_s" ]] || timeout_s=180
    primary_port="$(release_value ONION_SSH_PORT)"
    compat_port="$(config_value ONION_PUBLIC_PORT)"
    validate_port ONION_SSH_PORT "$primary_port"
    validate_port ONION_PUBLIC_PORT "$compat_port"

    ports+=("$primary_port")
    [[ "$compat_port" == "$primary_port" ]] || ports+=("$compat_port")
    for port in "${ports[@]}"; do
        if has_oniux; then
            log "oniux detected; verifying onion SSH on virtual port ${port}"
            if wait_for_onion_ssh "$host" "$port" "$timeout_s"; then
                continue
            fi
            log "oniux check on port ${port} timed out; retrying through the containerized torsocks checker"
        else
            log "oniux not found; using the containerized torsocks checker for onion port ${port}"
        fi
        run_tor_ssh_check_task "$port"
    done
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
    validate_environment
    "${COMPOSE[@]}" ps
    local host onion_port onion_ssh_port ssh_port ssh_user
    host="$(tor_hostname | tr -d '\r\n')"
    onion_port="$(config_value ONION_PUBLIC_PORT)"
    onion_ssh_port="$(release_value ONION_SSH_PORT)"
    ssh_port="$(config_value LOCAL_SSH_PORT)"
    ssh_user="$(config_value SOFT_SERVE_SSH_USER)"
    [[ -n "$ssh_user" ]] || ssh_user='admin'
    if [[ -n "$host" ]]; then
        log "Hidden service hostname: ${host}"
    else
        log "Hidden service hostname not available"
    fi
    log "Onion SSH port: ${onion_ssh_port} (mandatory, same persisted identity)"
    if [[ "$onion_port" == "$onion_ssh_port" ]]; then
        log "Onion compatibility port coincides with ${onion_ssh_port}; one Tor mapping is emitted"
    else
        log "Onion compatibility SSH port: ${onion_port} (same persisted identity)"
    fi
    [[ -z "$ssh_port" ]] || log "Local SSH: ssh -p ${ssh_port} ${ssh_user}@127.0.0.1"
    if [[ -n "$host" ]]; then
        log "Onion SSH: oniux ssh -p ${onion_ssh_port} ${ssh_user}@${host}"
        [[ "$onion_port" == "$onion_ssh_port" ]] \
            || log "Compatibility SSH: oniux ssh -p ${onion_port} ${ssh_user}@${host}"
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
    local sub="${1:-render}"
    case "$sub" in
        render)
            [[ $# -le 1 ]] || fail "usage: ./run.sh config [render|check|migrate [--apply] [--accept-retired-auxiliary-topology]]"
            require_runtime
            "${COMPOSE_CHECK[@]}" --profile check config
            ;;
        check)
            [[ $# -eq 1 ]] || fail "usage: ./run.sh config check"
            require_env_file
            require_cmd python3
            configctl_base check
            ;;
        migrate)
            shift
            require_env_file
            require_cmd python3
            local args=(--env "$ENV_FILE" --schema "$CONFIG_SCHEMA" \
                --template "$ROOT_DIR/env.example" --release-file "$RELEASE_FILE" migrate)
            local arg
            for arg in "$@"; do
                case "$arg" in
                    --apply|--accept-retired-auxiliary-topology) args+=("$arg") ;;
                    *) fail "usage: ./run.sh config migrate [--apply] [--accept-retired-auxiliary-topology]" ;;
                esac
            done
            python3 "$CONFIG_CTL" "${args[@]}"
            ;;
        *) fail "usage: ./run.sh config [render|check|migrate [--apply] [--accept-retired-auxiliary-topology]]" ;;
    esac
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
    require_env_file
    require_cmd python3
    configctl_base check --ignore-mode >/dev/null \
        || fail "refusing permission repair for invalid configuration"
    chmod 600 "$ENV_FILE"
    require_runtime
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
    local recipient="${2:-$(config_value BACKUP_RECIPIENT)}"
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
    require_release_runtime
    local archive="${1:-}"
    local identity="${2:-}"
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
    local identity="${2:-}"
    local mode="${3:-preserve}"
    [[ -n "$archive" && -n "$identity" ]] || fail "usage: ./run.sh restore <archive> <identity-file> [preserve|rotate]"
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
    printf '%s\n' 'All 0.1.0 configuration-contract release blockers are closed.'
    printf '%s\n' 'HG-003 remains an optional defense-in-depth feature for a later release.'
}

cmd_legacy_state() {
    require_release_runtime
    local image
    image="$(release_value ALPINE_IMAGE)"

    docker run --rm --network none \
        -v "$ROOT_DIR:/repo:ro" \
        -v "$ROOT_DIR/scripts/legacy-state.sh:/usr/local/bin/hidden-git-legacy-state:ro" \
        "$image" /usr/local/bin/hidden-git-legacy-state /repo
}

state_inventory_json() (
    local require_legacy="${1:-0}"
    local image tmp output_uid output_gid
    image="$(release_value ALPINE_IMAGE)"
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

require_default_services_stopped_without_config() {
    local running
    running="$(docker ps -q \
        --filter label=com.docker.compose.project=hidden-git \
        --filter label=com.docker.compose.service=soft-serve \
        --filter status=running)"
    running+="$(docker ps -q \
        --filter label=com.docker.compose.project=hidden-git \
        --filter label=com.docker.compose.service=tor \
        --filter status=running)"
    [[ -z "$running" ]] \
        || fail "this operation requires the default HiddenGit services to be stopped"
}

cmd_state_inventory() {
    require_release_runtime
    require_default_services_stopped_without_config
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
    image="$(release_value ALPINE_IMAGE)"
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
    # Validate before down so malformed current config can never stop a working
    # deployment and then fail before it can be started again.
    require_runtime
    cmd_down
    cmd_up
}

autoboot_unit_dir() {
    if [[ -n "${HIDDEN_GIT_SYSTEMD_USER_DIR:-}" ]]; then
        printf '%s\n' "$HIDDEN_GIT_SYSTEMD_USER_DIR"
    else
        printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    fi
}

autoboot_installed_service() {
    printf '%s/%s\n' "$(autoboot_unit_dir)" "$AUTOBOOT_SERVICE_NAME"
}

autoboot_installed_timer() {
    printf '%s/%s\n' "$(autoboot_unit_dir)" "$AUTOBOOT_TIMER_NAME"
}

autoboot_installed_docker_context() {
    local service_path context count
    service_path="$(autoboot_installed_service)"
    [[ -f "$service_path" ]] || return 1
    context="$(sed -n 's/^Environment=DOCKER_CONTEXT=//p' "$service_path")"
    count="$(printf '%s\n' "$context" | sed '/^$/d' | wc -l | tr -d ' ')"
    [[ "$count" == 1 && "$context" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    printf '%s\n' "$context"
}

autoboot_require_canonical_env() {
    [[ "$(realpath -m "$ENV_FILE")" == "$(realpath -m "$ROOT_DIR/.env")" ]] \
        || fail 'autoboot requires the canonical repository .env; HIDDEN_GIT_ENV_FILE overrides are not boot-stable'
}

autoboot_services_running() {
    local running
    running="$("${COMPOSE[@]}" ps --status running --services 2>/dev/null || true)"
    grep -Fxq 'soft-serve' <<<"$running" && grep -Fxq 'tor' <<<"$running"
}

autoboot_services_ready() {
    local service soft_id tor_id status_id status health
    autoboot_services_running || return 1
    for service in soft-serve tor; do
        case "$service" in
            soft-serve) soft_id="$("${COMPOSE[@]}" ps -q soft-serve 2>/dev/null || true)"; status_id="$soft_id" ;;
            tor) tor_id="$("${COMPOSE[@]}" ps -q tor 2>/dev/null || true)"; status_id="$tor_id" ;;
        esac
        [[ -n "$status_id" ]] || return 1
        status="$(docker inspect --format '{{.State.Status}}' "$status_id" 2>/dev/null || true)"
        health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$status_id" 2>/dev/null || true)"
        [[ "$status" == running && "$health" == healthy ]] || return 1
    done
}

autoboot_runtime_topology_ok() {
    local primary compat expected_count actual_count
    primary="$(release_value ONION_SSH_PORT)"
    compat="$(config_value ONION_PUBLIC_PORT)"
    expected_count=1
    [[ "$compat" == "$primary" ]] || expected_count=2

    actual_count="$("${COMPOSE[@]}" exec -T tor sh -ec \
        "grep -c '^HiddenServicePort ' /run/hidden-git/torrc" 2>/dev/null || true)"
    [[ "$actual_count" == "$expected_count" ]] || return 1
    "${COMPOSE[@]}" exec -T tor grep -Fxq \
        "HiddenServicePort ${primary} soft-serve:23231" /run/hidden-git/torrc \
        >/dev/null 2>&1 || return 1
    if [[ "$compat" != "$primary" ]]; then
        "${COMPOSE[@]}" exec -T tor grep -Fxq \
            "HiddenServicePort ${compat} soft-serve:23231" /run/hidden-git/torrc \
            >/dev/null 2>&1 || return 1
    fi
}

autoboot_preflight_install() {
    require_runtime
    autoboot_require_canonical_env
    validate_environment
    "${COMPOSE_CHECK[@]}" --profile check config >/dev/null
    autoboot_services_ready \
        || fail "autoboot installation requires an already-running healthy stack; run './run.sh up' first"
    autoboot_runtime_topology_ok \
        || fail "running Tor does not match the current same-identity SSH topology; run './run.sh up' and re-qualify before enabling autoboot"
    [[ -n "$(tor_hostname | tr -d '\r\n')" ]] \
        || fail 'autoboot installation requires an established persisted onion hostname'
    require_cmd systemctl
    require_cmd loginctl
    autoboot_docker_context >/dev/null
    local linger
    linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
    [[ "$linger" == yes ]] \
        || fail "systemd user autoboot requires login linger; enable it explicitly with 'loginctl enable-linger $(id -un)'"
    [[ -f "$AUTOBOOT_SERVICE_TEMPLATE" && -f "$AUTOBOOT_TIMER_TEMPLATE" ]] \
        || fail 'autoboot systemd templates are missing from this checkout'
}

render_autoboot_service_for_context() {
    local docker_context="$1"
    python3 - "$AUTOBOOT_SERVICE_TEMPLATE" "$ROOT_DIR" "$docker_context" <<'PY'
from pathlib import Path
import re
import sys

template = Path(sys.argv[1]).read_text(encoding="utf-8")
root = sys.argv[2]
docker_context = sys.argv[3]
if not re.fullmatch(r"/[A-Za-z0-9_./-]+", root):
    raise SystemExit(
        "repository path contains characters unsupported by the managed systemd unit; "
        "use an absolute checkout path containing only letters, digits, _, -, ., and /"
    )
if not re.fullmatch(r"[A-Za-z0-9_.-]+", docker_context):
    raise SystemExit("Docker context name contains unsupported characters")
print(
    template.replace("@ROOT_DIR@", root).replace("@DOCKER_CONTEXT@", docker_context),
    end="",
)
PY
}

render_autoboot_service() {
    local docker_context
    docker_context="$(autoboot_docker_context)"
    render_autoboot_service_for_context "$docker_context"
}

autoboot_units_current() {
    local installed_context service_path timer_path
    installed_context="$(autoboot_installed_docker_context 2>/dev/null || true)"
    service_path="$(autoboot_installed_service)"
    timer_path="$(autoboot_installed_timer)"
    [[ -n "$installed_context" && -f "$service_path" && -f "$timer_path" ]] || return 1
    cmp -s "$AUTOBOOT_TIMER_TEMPLATE" "$timer_path" || return 1
    cmp -s <(render_autoboot_service_for_context "$installed_context") "$service_path"
}

cmd_autoboot_install() {
    [[ $# -eq 0 ]] || fail 'usage: ./run.sh autoboot install'
    autoboot_preflight_install

    local unit_dir service_path timer_path tmp_service
    unit_dir="$(autoboot_unit_dir)"
    service_path="$(autoboot_installed_service)"
    timer_path="$(autoboot_installed_timer)"
    tmp_service="$(mktemp)"
    if ! render_autoboot_service >"$tmp_service"; then
        rm -f "$tmp_service"
        fail 'failed to render the managed autoboot service unit'
    fi

    if [[ -e "$service_path" && ! -f "$service_path" ]]; then
        rm -f "$tmp_service"
        fail "autoboot service path exists but is not a regular file: $service_path"
    fi
    if [[ -e "$timer_path" && ! -f "$timer_path" ]]; then
        rm -f "$tmp_service"
        fail "autoboot timer path exists but is not a regular file: $timer_path"
    fi
    if [[ -f "$service_path" ]] && ! cmp -s "$tmp_service" "$service_path"; then
        rm -f "$tmp_service"
        fail "existing $AUTOBOOT_SERVICE_NAME differs from the managed unit; review/remove it explicitly before install"
    fi
    if [[ -f "$timer_path" ]] && ! cmp -s "$AUTOBOOT_TIMER_TEMPLATE" "$timer_path"; then
        rm -f "$tmp_service"
        fail "existing $AUTOBOOT_TIMER_NAME differs from the managed unit; review/remove it explicitly before install"
    fi

    [[ -d "$unit_dir" ]] || install -d -m 700 "$unit_dir"
    if [[ ! -f "$service_path" ]]; then
        install -m 600 "$tmp_service" "$service_path"
    fi
    if [[ ! -f "$timer_path" ]]; then
        install -m 600 "$AUTOBOOT_TIMER_TEMPLATE" "$timer_path"
    fi
    rm -f "$tmp_service"
    systemctl --user daemon-reload
    systemctl --user enable --now "$AUTOBOOT_TIMER_NAME"
    log "Installed user autoboot timer: $AUTOBOOT_TIMER_NAME"
    log "The timer reconciles stopped/missing services without rebuilding images; disable/remove it before intentional downtime"
}

cmd_autoboot_status() {
    [[ $# -eq 0 ]] || fail 'usage: ./run.sh autoboot status'
    require_cmd systemctl
    local enabled active installed_context current_context units_current
    enabled="$(systemctl --user is-enabled "$AUTOBOOT_TIMER_NAME" 2>/dev/null || true)"
    active="$(systemctl --user is-active "$AUTOBOOT_TIMER_NAME" 2>/dev/null || true)"
    installed_context="$(autoboot_installed_docker_context 2>/dev/null || true)"
    current_context=''
    if command -v docker >/dev/null 2>&1; then
        current_context="$(docker context show 2>/dev/null || true)"
    fi
    if autoboot_units_current; then
        units_current=yes
    else
        units_current=no
    fi
    printf 'Autoboot timer enabled: %s\n' "${enabled:-not-installed}"
    printf 'Autoboot timer active:  %s\n' "${active:-inactive}"
    printf 'Managed units current:  %s\n' "$units_current"
    printf 'Recorded Docker context: %s\n' "${installed_context:-not-installed}"
    printf 'Current Docker context:  %s\n' "${current_context:-unavailable}"
    if [[ -n "$installed_context" && -n "$current_context" && "$installed_context" != "$current_context" ]]; then
        printf 'Docker context match:    no (remove/reinstall autoboot after qualifying the intended context)\n'
    elif [[ -n "$installed_context" && -n "$current_context" ]]; then
        printf 'Docker context match:    yes\n'
    fi
    printf 'Service unit: %s\n' "$(autoboot_installed_service)"
    printf 'Timer unit:   %s\n' "$(autoboot_installed_timer)"
}

cmd_autoboot_remove() {
    [[ $# -eq 0 ]] || fail 'usage: ./run.sh autoboot remove'
    require_cmd systemctl
    local service_path timer_path
    service_path="$(autoboot_installed_service)"
    timer_path="$(autoboot_installed_timer)"
    if [[ -f "$service_path" ]] && ! grep -Fxq "$AUTOBOOT_MANAGED_MARKER" "$service_path"; then
        fail "refusing to remove unmanaged unit: $service_path"
    fi
    if [[ -f "$timer_path" ]] && ! grep -Fxq "$AUTOBOOT_MANAGED_MARKER" "$timer_path"; then
        fail "refusing to remove unmanaged unit: $timer_path"
    fi
    systemctl --user disable --now "$AUTOBOOT_TIMER_NAME" >/dev/null 2>&1 || true
    rm -f "$service_path" "$timer_path"
    systemctl --user daemon-reload
    systemctl --user reset-failed "$AUTOBOOT_SERVICE_NAME" "$AUTOBOOT_TIMER_NAME" >/dev/null 2>&1 || true
    log 'Removed HiddenGit autoboot units; running containers were not stopped'
}

cmd_autoboot_reconcile() {
    [[ $# -eq 0 ]] || fail 'usage: ./run.sh autoboot reconcile'
    require_runtime
    autoboot_require_canonical_env
    validate_environment
    "${COMPOSE_CHECK[@]}" --profile check config >/dev/null
    if autoboot_services_ready; then
        log 'Autoboot reconciliation: Soft Serve and Tor are already healthy; no mutation needed'
        return 0
    fi

    log 'Autoboot reconciliation: recovering stopped, missing, or unhealthy services from existing local images'
    "${COMPOSE[@]}" up -d --no-build --wait
    autoboot_services_ready \
        || fail 'autoboot reconciliation completed without both default services healthy'
    log 'Autoboot reconciliation: stack recovered and healthy'
}

cmd_autoboot() {
    local sub="${1:-status}"
    shift || true
    case "$sub" in
        install) cmd_autoboot_install "$@" ;;
        status) cmd_autoboot_status "$@" ;;
        remove) cmd_autoboot_remove "$@" ;;
        reconcile) cmd_autoboot_reconcile "$@" ;;
        *) fail 'usage: ./run.sh autoboot <install|status|remove|reconcile>' ;;
    esac
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
  config [render]
            Validate schema and render the fully interpolated Compose configuration
  config check
            Validate the versioned .env schema without Docker or mutation
  config migrate [--apply] [--accept-retired-auxiliary-topology]
            Preview/apply schema-v2 migration; non-default retired HTTP/Git/stats topology requires the narrow acknowledgement flag
  doctor    Validate configuration and show actionable best-practice findings
  doctor --strict
            Fail when any best-practice warning remains
  fix-permissions
            Restrict .env, runtime data, and backup directory permissions
  sync-pins Compatibility check for tracked config/release.env; never writes .env
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
  autoboot <install|status|remove|reconcile>
            Manage the systemd user timer that repairs stopped/missing services after boot or Docker recovery
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
        config) shift; cmd_config "$@" ;;
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
        autoboot) shift; cmd_autoboot "$@" ;;
        restart) cmd_restart ;;
        version) project_version ;;
        help|-h|--help) usage ;;
        '') usage; exit 1 ;;
        *) usage; fail "unknown command: $cmd" ;;
    esac
}

main "$@"
