#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
COMPOSE_TOR_CHECK_OVERRIDE="${ROOT_DIR}/docker-compose.tor-check.override.yml"
ENV_FILE="${HIDDEN_GIT_ENV_FILE:-${ROOT_DIR}/.env}"
VERSION_FILE="${ROOT_DIR}/VERSION"
COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")
COMPOSE_CHECK=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" -f "${COMPOSE_TOR_CHECK_OVERRIDE}")

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

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
    if [[ ! -s "${ROOT_DIR}/data/soft-serve/soft-serve.db" && -z "$admin_keys" ]]; then
        fail "SOFT_SERVE_INITIAL_ADMIN_KEYS is required before first boot"
    fi
}

ensure_runtime_directories() {
    mkdir -p "${ROOT_DIR}/data/soft-serve" "${ROOT_DIR}/data/tor"
    chmod 700 "${ROOT_DIR}/data" "${ROOT_DIR}/data/soft-serve" "${ROOT_DIR}/data/tor" 2>/dev/null || true
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
    "${COMPOSE_CHECK[@]}" --profile check build
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
    local host onion_port
    host="$(tor_hostname | tr -d '\r\n')"
    onion_port="$(read_env_value ONION_PUBLIC_PORT)"
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
    require_runtime
    validate_environment
    validate_first_boot_admin
    ensure_runtime_directories
    "${COMPOSE_CHECK[@]}" --profile check config >/dev/null
    log "Configuration is valid for HiddenGit $(project_version)"
    if has_oniux; then
        log "Optional oniux client check is available"
    else
        log "oniux is not installed; containerized torsocks checks will be used"
    fi
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
  doctor    Validate local prerequisites and configuration
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
        doctor) cmd_doctor ;;
        restart) cmd_restart ;;
        version) project_version ;;
        help|-h|--help) usage ;;
        '') usage; exit 1 ;;
        *) usage; fail "unknown command: $cmd" ;;
    esac
}

main "$@"
