#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
COMPOSE_TOR_CHECK_OVERRIDE="${ROOT_DIR}/docker-compose.tor-check.override.yml"
ENV_FILE="${ROOT_DIR}/.env"
COMPOSE=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}")
COMPOSE_CHECK=(docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" -f "${COMPOSE_TOR_CHECK_OVERRIDE}")

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
fail() {
    log "ERROR: $*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

has_oniux() {
    command -v oniux >/dev/null 2>&1
}

read_env_value() {
    local key="$1"
    awk -F= -v k="$key" '$1==k {print substr($0, index($0,$2)); exit}' "${ENV_FILE}" | sed 's/^"//; s/"$//'
}

tor_hostname() {
    "${COMPOSE[@]}" exec -T tor sh -lc 'cat /var/lib/tor/hidden_service/hostname 2>/dev/null || true'
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
    [[ -f "${COMPOSE_TOR_CHECK_OVERRIDE}" ]] || fail "tor check override file not found at ${COMPOSE_TOR_CHECK_OVERRIDE}"
    "${COMPOSE_CHECK[@]}" run --rm tor-check
}

is_onion_ssh_connectable() {
    local host="$1"
    local onion_port ssh_user
    onion_port="$(read_env_value ONION_PUBLIC_PORT)"
    ssh_user="$(read_env_value SOFT_SERVE_SSH_USER)"
    [[ -n "$ssh_user" ]] || ssh_user="admin"
    [[ -n "$onion_port" ]] || fail "ONION_PUBLIC_PORT not found in .env"

    local output rc
    set +e
    output="$(oniux -p 0 ssh -o ConnectTimeout=12 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -p "${onion_port}" "${ssh_user}@${host}" help 2>&1)"
    rc=$?
    set -e

    if [[ $rc -eq 0 ]]; then
        return 0
    fi
    if printf '%s' "$output" | rg -q "Permission denied|Host key verification failed|administratively prohibited|Connection closed"; then
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
    if has_oniux; then
        log "oniux detected; verifying SSH connectivity over onion with oniux"
        if wait_for_onion_ssh "$host" 345; then
            return 0
        fi
        log "oniux connectivity check timed out; falling back to torified SSH connectivity check container task"
        run_tor_ssh_check_task
        return 0
    fi

    log "oniux not found; falling back to torified SSH connectivity check container task"
    run_tor_ssh_check_task
}

cmd_up() {
    log "Starting services"
    "${COMPOSE[@]}" up -d --build
    log "Services started, waiting for onion hostname"
    local host
    host="$(wait_for_hostname 180 | tr -d '\r\n')" || fail "timed out waiting for hidden service hostname"
    log "Hidden service hostname: ${host}"
    verify_onion_ssh_connectivity "$host"
    log "Onion SSH connectivity check passed"
}

cmd_down() {
    log "Stopping services"
    "${COMPOSE[@]}" down
}

cmd_build() {
    log "Building images"
    "${COMPOSE[@]}" build
}

cmd_logs() {
    "${COMPOSE[@]}" logs -f
}

cmd_ps() {
    "${COMPOSE[@]}" ps
}

cmd_status() {
    cmd_ps
    local host onion_port
    host="$(tor_hostname | tr -d '\r\n')"
    onion_port="$(read_env_value ONION_PUBLIC_PORT)"
    if [[ -n "$host" ]]; then
        log "Hidden service hostname: ${host}"
    else
        log "Hidden service hostname not available yet"
    fi
    if [[ -n "$onion_port" ]]; then
        log "Onion public SSH port: ${onion_port}"
    else
        log "Onion public SSH port not set in .env"
    fi
}

cmd_test() {
    local host
    host="$(wait_for_hostname 120 | tr -d '\r\n')" || fail "timed out waiting for hidden service hostname"
    log "Hidden service hostname: ${host}"

    verify_onion_ssh_connectivity "$host"
    log "All checks passed"
}

cmd_restart() {
    cmd_down
    cmd_up
}

usage() {
    cat <<USAGE
Usage: $0 <command>

Commands:
  up       Build and start services in background
  down     Stop and remove services
  build    Build images
  logs     Follow compose logs
  ps       Show service status
  status   Show service status + onion hostname + onion public SSH port
  test     Verify onion hostname and SSH access over hidden service via tor-check container
  restart  Restart stack
USAGE
}

main() {
    require_cmd docker
    [[ -f "${ENV_FILE}" ]] || fail ".env not found at ${ENV_FILE}"

    local cmd="${1:-}"
    case "$cmd" in
    up) cmd_up ;;
    down) cmd_down ;;
    build) cmd_build ;;
    logs) cmd_logs ;;
    ps) cmd_ps ;;
    status) cmd_status ;;
    test) cmd_test ;;
    restart) cmd_restart ;;
    *)
        usage
        exit 1
        ;;
    esac
}

main "$@"
