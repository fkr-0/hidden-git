#!/usr/bin/env bash

# Sourced by run.sh after its core helpers are defined.

AUDIT_WARNINGS=0
AUDIT_FAILURES=0

ui_status() {
    local level="$1"
    local title="$2"
    local detail="${3:-}"
    local remedy="${4:-}"

    case "$level" in
        PASS) printf '[PASS] %-28s %s\n' "$title" "$detail" ;;
        INFO) printf '[INFO] %-28s %s\n' "$title" "$detail" ;;
        WARN)
            AUDIT_WARNINGS=$((AUDIT_WARNINGS + 1))
            printf '[WARN] %-28s %s\n' "$title" "$detail"
            [[ -z "$remedy" ]] || printf '       Fix: %s\n' "$remedy"
            ;;
        FAIL)
            AUDIT_FAILURES=$((AUDIT_FAILURES + 1))
            printf '[FAIL] %-28s %s\n' "$title" "$detail"
            [[ -z "$remedy" ]] || printf '       Fix: %s\n' "$remedy"
            ;;
        *) printf '[%s] %s %s\n' "$level" "$title" "$detail" ;;
    esac
}

audit_legacy_layout() {
    local paths=()
    [[ ! -d "$ROOT_DIR/soft-serve-data" ]] || paths+=(soft-serve-data/)
    [[ ! -d "$ROOT_DIR/tor-data" ]] || paths+=(tor-data/)
    if ((${#paths[@]} > 0)); then
        ui_status WARN 'legacy runtime layout' \
            "coexists with data/: ${paths[*]} (HG-009)" \
            "run './run.sh legacy-state'; back up both deployments before deleting or merging anything"
    else
        ui_status PASS 'legacy runtime layout' 'no legacy deployment directories detected'
    fi
}

audit_runtime_ownership() {
    local soft_owner tor_owner
    soft_owner="$(stat -c '%u:%g' "$ROOT_DIR/data/soft-serve" 2>/dev/null || true)"
    tor_owner="$(stat -c '%u:%g' "$ROOT_DIR/data/tor" 2>/dev/null || true)"
    if [[ "$soft_owner" == '10001:10001' && "$tor_owner" == '10002:10002' ]]; then
        ui_status PASS 'service data ownership' 'Soft Serve 10001:10001; Tor 10002:10002'
    else
        ui_status WARN 'service data ownership' \
            "Soft Serve ${soft_owner:-missing}; Tor ${tor_owner:-missing}" \
            "back up existing state, then run './run.sh migrate-users --confirm-existing'"
    fi
}

mode_is_private() {
    local path="$1"
    local mode
    mode="$(stat -c '%a' "$path" 2>/dev/null || true)"
    [[ -n "$mode" && "${mode: -2}" == "00" ]]
}

audit_environment_permissions() {
    if mode_is_private "$ENV_FILE"; then
        ui_status PASS '.env permissions' "mode $(stat -c '%a' "$ENV_FILE")"
    else
        ui_status WARN '.env permissions' \
            "${ENV_FILE} is readable by group or others" \
            "run './run.sh fix-permissions'"
    fi

    local path insecure=0
    for path in "$ROOT_DIR/data" "$ROOT_DIR/data/soft-serve" "$ROOT_DIR/data/tor"; do
        [[ -e "$path" ]] || continue
        if ! mode_is_private "$path"; then
            insecure=1
            ui_status WARN 'runtime permissions' \
                "$path has mode $(stat -c '%a' "$path" 2>/dev/null || printf '?')" \
                "run './run.sh fix-permissions'"
        fi
    done
    ((insecure == 1)) || ui_status PASS 'runtime permissions' 'runtime directories are private'
}

audit_host_binding() {
    local bind
    bind="$(read_env_value HOST_BIND_ADDRESS)"
    [[ -n "$bind" ]] || bind='127.0.0.1'
    case "$bind" in
        127.0.0.1|localhost|::1|'[::1]')
            ui_status PASS 'host port binding' "$bind is loopback-only"
            ;;
        *)
            ui_status WARN 'host port binding' \
                "$bind exposes Soft Serve ports beyond this host" \
                "set HOST_BIND_ADDRESS=127.0.0.1 unless LAN access is intentional and firewalled"
            ;;
    esac
}

audit_image_pinning() {
    local key value failures=0
    for key in ALPINE_IMAGE GO_IMAGE TRIVY_IMAGE BUILDKIT_IMAGE DIND_ROOTLESS_IMAGE; do
        value="$(read_env_value "$key")"
        if [[ "$value" =~ @sha256:[0-9a-f]{64}$ ]]; then
            continue
        fi
        failures=1
        ui_status WARN 'image digest pinning' \
            "$key is not pinned to an OCI digest" \
            "run './run.sh sync-pins' to adopt reviewed release references"
    done
    ((failures == 1)) || ui_status PASS 'image digest pinning' 'release base images are immutable'
}

audit_admin_key() {
    local keys
    keys="$(read_env_value SOFT_SERVE_INITIAL_ADMIN_KEYS)"
    if ! runtime_contains_state && [[ -z "$keys" ]]; then
        ui_status FAIL 'initial administrator' \
            'fresh deployment has no administrator public key' \
            'set SOFT_SERVE_INITIAL_ADMIN_KEYS to a complete SSH public key'
        return
    fi
    if [[ -z "$keys" ]]; then
        ui_status INFO 'initial administrator' 'database already exists; bootstrap key is no longer required'
    elif [[ "$keys" == ssh-ed25519\ * || "$keys" == sk-ssh-ed25519@openssh.com\ * ]]; then
        ui_status PASS 'administrator key type' 'modern Ed25519 key configured'
    elif [[ "$keys" == ssh-rsa\ * ]]; then
        ui_status WARN 'administrator key type' \
            'legacy RSA administrator key configured' \
            'prefer an Ed25519 or hardware-backed Ed25519 key for new deployments'
    else
        ui_status WARN 'administrator key format' \
            'the configured bootstrap key type was not recognized' \
            'verify the full public key with ssh-keygen -lf <public-key-file>'
    fi
}

audit_docker_isolation() {
    local security_options
    security_options="$(docker info --format '{{json .SecurityOptions}}' 2>/dev/null || true)"
    if grep -q 'rootless' <<<"$security_options"; then
        ui_status PASS 'Docker daemon isolation' 'rootless mode detected'
    else
        ui_status WARN 'Docker daemon isolation' \
            'this host currently uses a rootful daemon; rootless compatibility is tested' \
            'use a rootless Docker context when host-level daemon isolation is required'
    fi

    local ids id configured_user name root_count=0
    ids="$("${COMPOSE[@]}" ps -q 2>/dev/null || true)"
    for id in $ids; do
        configured_user="$(docker inspect --format '{{.Config.User}}' "$id" 2>/dev/null || true)"
        name="$(docker inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##' || true)"
        if [[ -z "$configured_user" || "$configured_user" == 0 || "$configured_user" == root ]]; then
            root_count=$((root_count + 1))
            ui_status WARN 'container process user' \
                "${name:-$id} has no dedicated runtime user" \
                'recreate the stack from the current release images and verify with doctor'
        fi
    done
    if [[ -n "$ids" && $root_count -eq 0 ]]; then
        ui_status PASS 'container process users' 'running services use explicit users'
    elif [[ -z "$ids" ]]; then
        ui_status INFO 'container process users' 'services are not running'
    fi
}

audit_backup_state() {
    local latest age_days now latest_epoch
    latest="$(find "$ROOT_DIR/backups" -maxdepth 1 -type f -name 'hidden-git-*-backup-*.tar.age' \
        -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{sub(/^[^ ]+ /, ""); print}')"
    if [[ -z "$latest" ]]; then
        ui_status WARN 'encrypted backup' \
            'no encrypted backup was found' \
            "run './run.sh backup-keygen', configure BACKUP_RECIPIENT, then run './run.sh backup'"
        return
    fi

    latest_epoch="$(stat -c '%Y' "$latest")"
    now="$(date +%s)"
    age_days=$(((now - latest_epoch) / 86400))
    if ((age_days > 30)); then
        ui_status WARN 'encrypted backup' \
            "latest backup is ${age_days} days old: $(basename "$latest")" \
            'create and restore-test a fresh encrypted backup'
    else
        ui_status PASS 'encrypted backup' "latest backup is ${age_days} days old"
    fi
}

audit_repository_practices() {
    local mutable
    mutable="$(grep -RhoE 'uses:[[:space:]]+[^[:space:]]+@(v[0-9]+|main|master|latest)' \
        "$ROOT_DIR/.github/workflows" 2>/dev/null || true)"
    if [[ -n "$mutable" ]]; then
        ui_status WARN 'GitHub Action pinning' \
            'one or more actions use mutable tags' \
            'pin every action to a reviewed full commit SHA'
    else
        ui_status PASS 'GitHub Action pinning' 'workflow actions use immutable commit SHAs'
    fi
}

run_best_practice_audit() {
    AUDIT_WARNINGS=0
    AUDIT_FAILURES=0
    printf '\nHiddenGit best-practice audit\n'
    printf '%s\n' '─────────────────────────────'
    audit_environment_permissions
    audit_runtime_ownership
    audit_host_binding
    audit_image_pinning
    audit_admin_key
    audit_legacy_layout
    audit_docker_isolation
    audit_backup_state
    audit_repository_practices
    printf '%s\n' '─────────────────────────────'
    printf 'Summary: %d warning(s), %d failure(s)\n' "$AUDIT_WARNINGS" "$AUDIT_FAILURES"
}
