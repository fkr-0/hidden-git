#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${E2E_TMP_DIR:-}" ]]; then
    TMP_DIR="${E2E_TMP_DIR}"
    [[ ! -e "$TMP_DIR" ]] || {
        printf 'E2E_TMP_DIR already exists: %s\n' "$TMP_DIR" >&2
        exit 1
    }
    mkdir -p "$TMP_DIR"
else
    TMP_DIR="$(mktemp -d)"
fi
PROJECT="hidden-git-e2e-$$"
ENV_FILE="${TMP_DIR}/e2e.env"
OVERRIDE_FILE="${TMP_DIR}/e2e.override.yml"
LOG_FILE="${TMP_DIR}/compose.log"
KEEP_ARTIFACTS="${KEEP_E2E_ARTIFACTS:-0}"
E2E_CHECK_TIMEOUT_SECONDS="${E2E_CHECK_TIMEOUT_SECONDS:-300}"
E2E_SSH_ATTEMPT_TIMEOUT_SECONDS="${E2E_SSH_ATTEMPT_TIMEOUT_SECONDS:-45}"
E2E_ONION_CHECK_ATTEMPTS="${E2E_ONION_CHECK_ATTEMPTS:-2}"
E2E_START_FROM_V1="${E2E_START_FROM_V1:-0}"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$1" >&2
        exit 1
    }
}

require_cmd docker
require_cmd git
require_cmd python3
require_cmd ssh
require_cmd ssh-keygen

release_value() {
    python3 "$ROOT_DIR/scripts/configctl.py" release get "$1"
}

ALPINE_IMAGE="$(release_value ALPINE_IMAGE)"
GO_IMAGE="$(release_value GO_IMAGE)"
SOFT_SERVE_VERSION="$(release_value SOFT_SERVE_VERSION)"
SOFT_SERVE_NET_SECURITY_VERSION="$(release_value SOFT_SERVE_NET_SECURITY_VERSION)"
ONION_SSH_PORT="$(release_value ONION_SSH_PORT)"
TRIVY_IMAGE="$(release_value TRIVY_IMAGE)"
BUILDKIT_IMAGE="$(release_value BUILDKIT_IMAGE)"
DIND_ROOTLESS_IMAGE="$(release_value DIND_ROOTLESS_IMAGE)"
export ALPINE_IMAGE GO_IMAGE SOFT_SERVE_VERSION SOFT_SERVE_NET_SECURITY_VERSION ONION_SSH_PORT TRIVY_IMAGE BUILDKIT_IMAGE DIND_ROOTLESS_IMAGE

docker compose version >/dev/null 2>&1 || {
    printf 'Docker Compose v2 is required\n' >&2
    exit 1
}

compose=(
    docker compose
    -p "$PROJECT"
    --env-file "$ENV_FILE"
    -f "${ROOT_DIR}/docker-compose.yml"
    -f "${ROOT_DIR}/docker-compose.tor-check.override.yml"
    -f "$OVERRIDE_FILE"
)

container_exec() {
    local service="$1"
    shift
    local container_id attempt rc
    case "$service" in
        soft-serve) container_id="${soft_id:-}" ;;
        tor) container_id="${tor_id:-}" ;;
        *)
            printf 'unknown E2E service for docker exec: %s\n' "$service" >&2
            return 2
            ;;
    esac
    [[ -n "$container_id" ]] || {
        printf 'missing E2E container id for service: %s\n' "$service" >&2
        return 2
    }

    for attempt in 1 2 3; do
        set +e
        timeout --signal=TERM --kill-after=2s 15s docker exec "$container_id" "$@"
        rc=$?
        set -e
        if [[ $rc -eq 0 ]]; then
            return 0
        fi
        if [[ $rc -ne 124 ]]; then
            return "$rc"
        fi
        printf 'docker exec timed out (attempt %d/3): service=%s\n' \
            "$attempt" "$service" >&2
        sleep 1
    done
    return 124
}

cleanup() {
    local rc=$?
    set +e
    "${compose[@]}" --profile check logs --no-color >"$LOG_FILE" 2>&1
    "${compose[@]}" --profile check down -v --remove-orphans >/dev/null 2>&1
    if [[ $rc -ne 0 ]]; then
        printf '%s\n' '--- integration logs ---' >&2
        cat "$LOG_FILE" >&2
    fi
    if [[ "$KEEP_ARTIFACTS" == 1 ]]; then
        printf 'E2E artifacts: %s\n' "$TMP_DIR"
    else
        rm -rf "$TMP_DIR"
    fi
    exit "$rc"
}
trap cleanup EXIT

cp "${ROOT_DIR}/env.example" "$ENV_FILE"
ssh-keygen -q -t ed25519 -N '' -C hidden-git-e2e -f "${TMP_DIR}/admin_key"
ssh-keygen -q -t ed25519 -N '' -C hidden-git-e2e-unauthorized -f "${TMP_DIR}/unauthorized_key"
admin_key="$(cat "${TMP_DIR}/admin_key.pub")"
e2e_display_name="HiddenGit O'Reilly \"quoted\" # equals=kept \\ literal"

python3 - "$ENV_FILE" "$admin_key" "$E2E_CHECK_TIMEOUT_SECONDS" "$e2e_display_name" <<'PY'
from pathlib import Path
import json
import socket
import sys

path = Path(sys.argv[1])
admin_key = sys.argv[2]
check_timeout = sys.argv[3]
display_name = sys.argv[4]


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


local_ssh_port = free_port()
updates = {
    "SOFT_SERVE_NAME": json.dumps(display_name),
    "SOFT_SERVE_INITIAL_ADMIN_KEYS": f'"{admin_key}"',
    "LOCAL_SSH_PORT": str(local_ssh_port),
    "ONION_PUBLIC_PORT": "18002",
    "SOFT_SERVE_SSH_PUBLIC_URL": "",
    "CHECK_TIMEOUT_SECONDS": check_timeout,
}
lines = []
for line in path.read_text().splitlines():
    key = line.split("=", 1)[0] if "=" in line else None
    if key in updates:
        line = f"{key}={updates[key]}"
    lines.append(line)
path.write_text("\n".join(lines) + "\n")
path.chmod(0o600)
PY
chmod 600 "$ENV_FILE" "${TMP_DIR}/admin_key"
chmod 600 "${TMP_DIR}/unauthorized_key"

migration_backup=""
legacy_env_hash=""
case "$E2E_START_FROM_V1" in
    0) ;;
    1)
        # Exercise a real schema-v1 operator file through the exact modern runtime.
        # The stale release/recovery ownership keys are deliberately harmless test
        # values: migration must retire them without reading any real identity.
        python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = []
for line in path.read_text().splitlines():
    if line.startswith("HIDDEN_GIT_CONFIG_VERSION="):
        line = "HIDDEN_GIT_CONFIG_VERSION=1"
    lines.append(line)
lines.extend(
    [
        "HIDDEN_GIT_VERSION=0.1.3",
        "ALPINE_IMAGE=alpine:legacy-test",
        "BACKUP_IDENTITY_FILE=/legacy-test/recovery.agekey",
    ]
)
path.write_text("\n".join(lines) + "\n")
path.chmod(0o600)
PY
        legacy_env_hash="$(sha256sum "$ENV_FILE" | awk '{print $1}')"
        migration_plan="${TMP_DIR}/v1-migration-plan.json"
        python3 "$ROOT_DIR/scripts/configctl.py" --env "$ENV_FILE" migrate --apply --json > "$migration_plan"
        migration_backup="$(python3 - "$migration_plan" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["backup"] or "")
PY
)"
        [[ -n "$migration_backup" && -f "$migration_backup" ]] || {
            printf '%s\n' 'v1 E2E migration did not create a rollback copy' >&2
            exit 1
        }
        [[ "$legacy_env_hash" == "$(sha256sum "$migration_backup" | awk '{print $1}')" ]] || {
            printf '%s\n' 'v1 E2E rollback copy does not match the pre-migration bytes' >&2
            exit 1
        }
        python3 "$ROOT_DIR/scripts/configctl.py" --env "$ENV_FILE" check >/dev/null
        ;;
    *)
        printf 'E2E_START_FROM_V1 must be 0 or 1, got: %s\n' "$E2E_START_FROM_V1" >&2
        exit 2
        ;;
esac

cat > "$OVERRIDE_FILE" <<YAML
services:
  soft-serve:
    volumes:
      - soft-serve-e2e-data:/var/lib/soft-serve
  tor:
    volumes:
      - tor-e2e-data:/var/lib/tor
  tor-check:
    environment:
      SSH_ATTEMPT_TIMEOUT_SECONDS: ${E2E_SSH_ATTEMPT_TIMEOUT_SECONDS}
      SSH_IDENTITY_FILE: /run/secrets/hidden-git-e2e-key
    volumes:
      - tor-e2e-data:/var/lib/tor:ro
      - ${TMP_DIR}/admin_key:/run/secrets/hidden-git-e2e-key:ro
volumes:
  soft-serve-e2e-data:
  tor-e2e-data:
YAML

# Seed a historical persistent config with deliberately conflicting ports. The
# new runtime must ignore it in favor of SOFT_SERVE_CONFIG_LOCATION under /run.
soft_volume="${PROJECT}_soft-serve-e2e-data"
tor_volume="${PROJECT}_tor-e2e-data"
docker volume create "$soft_volume" >/dev/null
alpine_image="$ALPINE_IMAGE"
docker run --rm -v "$soft_volume:/state" "$alpine_image" sh -ec '
    chown 10001:10001 /state
    cat > /state/config.yaml <<"EOF"
name: stale-config-must-not-win
ssh:
  enabled: true
  listen_addr: ":29999"
http:
  enabled: true
  listen_addr: ":29998"
stats:
  enabled: true
  listen_addr: ":29997"
git:
  enabled: true
  listen_addr: ":29996"
EOF
    chown 10001:10001 /state/config.yaml
    chmod 600 /state/config.yaml
'

"${compose[@]}" --profile check config >/dev/null
"${compose[@]}" up -d --build --wait

soft_id="$("${compose[@]}" ps -q soft-serve)"
tor_id="$("${compose[@]}" ps -q tor)"
[[ "$(container_exec soft-serve id -u)" == '10001' ]]
[[ "$(container_exec tor id -u)" == '10002' ]]
[[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$soft_id")" == 'true' ]]
[[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$tor_id")" == 'true' ]]
docker inspect --format '{{json .HostConfig.CapDrop}}' "$soft_id" | grep -q 'ALL'
docker inspect --format '{{json .HostConfig.CapDrop}}' "$tor_id" | grep -q 'ALL'

local_ssh_port="$(python3 "$ROOT_DIR/scripts/configctl.py" --env "$ENV_FILE" get LOCAL_SSH_PORT)"
managed_config="$(container_exec soft-serve cat /run/hidden-git/soft-serve.config.yaml)"
grep -Fq 'listen_addr: ":23231"' <<<"$managed_config"
escaped_e2e_name="$(printf '%s' "$e2e_display_name" | sed "s/'/''/g")"
grep -Fq "name: '${escaped_e2e_name}'" <<<"$managed_config"
grep -Fq "public_url: 'ssh://localhost:${local_ssh_port}'" <<<"$managed_config"
grep -A2 '^git:' <<<"$managed_config" | grep -Fq 'enabled: false'
grep -A2 '^http:' <<<"$managed_config" | grep -Fq 'enabled: false'
grep -A2 '^stats:' <<<"$managed_config" | grep -Fq 'enabled: false'
grep -Fq 'listen_addr: "127.0.0.1:23233"' <<<"$managed_config"
grep -A2 '^lfs:' <<<"$managed_config" | grep -Fq 'enabled: false'
if grep -q '2999' <<<"$managed_config"; then
    printf '%s\n' 'stale persistent listener values leaked into managed runtime config' >&2
    exit 1
fi

# Prove behavior, not only rendered YAML.
container_exec soft-serve sh -ec 'nc -z -w 3 127.0.0.1 23231'
container_exec soft-serve sh -ec '! nc -z -w 2 127.0.0.1 23232'
container_exec soft-serve sh -ec '! nc -z -w 2 127.0.0.1 9418'
container_exec soft-serve sh -ec '! nc -z -w 2 127.0.0.1 23233'
container_exec tor sh -ec '! nc -z -w 2 soft-serve 23232'
container_exec tor sh -ec '! nc -z -w 2 soft-serve 9418'
container_exec tor sh -ec '! nc -z -w 2 soft-serve 23233'
network_name="$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' "$soft_id")"
[[ -n "$network_name" ]]
docker run --rm --network "$network_name" "$ALPINE_IMAGE" sh -ec \
    '! nc -z -w 2 soft-serve 23232 && ! nc -z -w 2 soft-serve 9418 && ! nc -z -w 2 soft-serve 23233'

torrc="$(container_exec tor cat /run/hidden-git/torrc)"
grep -Fq 'HiddenServicePort 2022 soft-serve:23231' <<<"$torrc"
grep -Fq 'HiddenServicePort 18002 soft-serve:23231' <<<"$torrc"
[[ "$(grep -c '^HiddenServicePort ' <<<"$torrc")" == 2 ]]

published="$(docker port "$soft_id")"
[[ "$(wc -l <<<"$published" | tr -d ' ')" == '1' ]]
grep -Eq "^23231/tcp -> 127\.0\.0\.1:${local_ssh_port}$" <<<"$published"
[[ -z "$(docker port "$tor_id")" ]] || {
    printf '%s\n' 'Tor unexpectedly publishes a host port; onion 2022 must remain virtual-only' >&2
    exit 1
}
if grep -Eq '(^|:)2022($|[^0-9])' <<<"$published"; then
    printf '%s\n' 'mandatory onion virtual port 2022 leaked into host publication' >&2
    exit 1
fi

onion_host="$(container_exec tor cat /var/lib/tor/hidden_service/hostname | tr -d '\r\n')"
[[ "$onion_host" == *.onion ]] || {
    printf 'invalid onion hostname: %s\n' "$onion_host" >&2
    exit 1
}
onion_hostname_hash="$(container_exec tor sha256sum /var/lib/tor/hidden_service/hostname | awk '{print $1}')"

local_output="$(ssh \
    -F /dev/null \
    -i "${TMP_DIR}/admin_key" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o ControlMaster=no \
    -o ControlPath=none \
    -o ControlPersist=no \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p "$local_ssh_port" \
    admin@127.0.0.1 help 2>&1)"
printf '%s\n' "$local_output" | grep -Eq 'Soft Serve|Usage:|Available Commands:' || {
    printf 'authenticated local SSH command returned unexpected output:\n%s\n' "$local_output" >&2
    exit 1
}

ssh_soft() {
    local identity="$1"
    shift
    ssh \
        -F /dev/null \
        -i "$identity" \
        -o BatchMode=yes \
        -o IdentitiesOnly=yes \
        -o ControlMaster=no \
        -o ControlPath=none \
        -o ControlPersist=no \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -p "$local_ssh_port" \
        admin@127.0.0.1 "$@"
}

# Exercise the native SSH Git transport end to end, not only SSH command RPCs.
# This repository lives only in the disposable named volume and later doubles as
# the stale-state persistence sentinel across force-recreate.
git_roundtrip_dir="${TMP_DIR}/git-roundtrip"
git_roundtrip_remote="ssh://admin@127.0.0.1:${local_ssh_port}/verifier-roundtrip.git"
git_ssh_command="ssh -F /dev/null -i ${TMP_DIR}/admin_key -o BatchMode=yes -o IdentitiesOnly=yes -o ControlMaster=no -o ControlPath=none -o ControlPersist=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${local_ssh_port}"
ssh_soft "${TMP_DIR}/admin_key" repo create verifier-roundtrip >/dev/null
GIT_SSH_COMMAND="$git_ssh_command" git clone --quiet "$git_roundtrip_remote" "$git_roundtrip_dir"
(
    cd "$git_roundtrip_dir"
    git config user.name 'HiddenGit E2E'
    git config user.email 'hidden-git-e2e@example.invalid'
    git checkout --quiet -b main
    printf 'hidden-git native SSH roundtrip\n' > roundtrip.txt
    git add roundtrip.txt
    git commit --quiet -m 'exercise native SSH Git transport'
    GIT_SSH_COMMAND="$git_ssh_command" git push --quiet origin main
    GIT_SSH_COMMAND="$git_ssh_command" git fetch --quiet origin main
)
roundtrip_head="$(git -C "$git_roundtrip_dir" rev-parse HEAD)"
[[ "$roundtrip_head" == "$(git -C "$git_roundtrip_dir" rev-parse FETCH_HEAD)" ]] || {
    printf '%s\n' 'native SSH Git fetch did not return the pushed commit' >&2
    exit 1
}

# Upstream first boot persists SOFT_SERVE_INITIAL_ADMIN_KEYS on its built-in
# admin user. Confirm that durable DB authority, then create a real non-admin
# user whose key will later be placed in the stale bootstrap field.
admin_info="$(ssh_soft "${TMP_DIR}/admin_key" user info admin 2>/dev/null)"
grep -Fq 'Admin: true' <<<"$admin_info"
ssh-keygen -q -t ed25519 -N '' -C hidden-git-e2e-lowpriv -f "${TMP_DIR}/lowpriv_key"
chmod 600 "${TMP_DIR}/lowpriv_key"
read -r low_key_type low_key_blob _ < "${TMP_DIR}/lowpriv_key.pub"
ssh_soft "${TMP_DIR}/admin_key" user create lowpriv >/dev/null
ssh_soft "${TMP_DIR}/admin_key" user add-pubkey lowpriv "$low_key_type" "$low_key_blob" >/dev/null
low_info="$(ssh_soft "${TMP_DIR}/admin_key" user info lowpriv 2>/dev/null)"
grep -Fq 'Admin: false' <<<"$low_info"
# Establish the authorization baseline before touching the bootstrap field. This
# distinguishes an upstream/global-command regression from stale bootstrap-key
# authority introduced only by the established-deployment recreation below.
if pre_recreate_low_output="$(ssh_soft "${TMP_DIR}/lowpriv_key" user list 2>&1)"; then
    printf '%s\n' 'low-privilege baseline unexpectedly reached user list before bootstrap-key change' >&2
    exit 1
fi
grep -Fqi 'unauthorized' <<<"$pre_recreate_low_output" || {
    printf '%s\n' 'low-privilege baseline failed for a reason other than authorization' >&2
    exit 1
}

# Change the established deployment's bootstrap key to the low-privilege key
# and deliberately diverge clone metadata from every routing port. The runtime
# must suppress the stale bootstrap key while preserving the metadata exactly.
low_public_key="${low_key_type} ${low_key_blob}"
explicit_public_url='ssh://metadata.example.invalid:2200'
python3 - "$ENV_FILE" "$low_public_key" "$explicit_public_url" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
updates = {
    "SOFT_SERVE_INITIAL_ADMIN_KEYS": sys.argv[2],
    "SOFT_SERVE_SSH_PUBLIC_URL": sys.argv[3],
}
lines = []
for line in path.read_text().splitlines():
    key = line.split("=", 1)[0] if "=" in line else None
    if key in updates:
        line = f"{key}={updates[key]}"
    lines.append(line)
path.write_text("\n".join(lines) + "\n")
path.chmod(0o600)
PY
python3 "$ROOT_DIR/scripts/configctl.py" --env "$ENV_FILE" check >/dev/null
"${compose[@]}" up -d --force-recreate --wait soft-serve
soft_id="$("${compose[@]}" ps -q soft-serve)"

# Docker retains the declared container environment on tini, so inspect the
# actual Soft Serve process rather than `docker exec env` or PID 1. The
# entrypoint must remove the bootstrap variable before exec'ing Soft Serve once
# a database exists.
# shellcheck disable=SC2016 # Expansions are intentionally evaluated by the inner container shell.
container_exec soft-serve sh -ec \
    'soft_pid="$(pidof soft)"; test -n "$soft_pid"; ! tr "\\000" "\\n" < "/proc/$soft_pid/environ" | grep -q "^SOFT_SERVE_INITIAL_ADMIN_KEYS="'
managed_config="$(container_exec soft-serve cat /run/hidden-git/soft-serve.config.yaml)"
grep -Fq "public_url: '${explicit_public_url}'" <<<"$managed_config"
if grep -Fq "localhost:${local_ssh_port}" <<<"$managed_config"; then
    printf '%s\n' 'explicit clone URL was incorrectly coupled back to the local routing port' >&2
    exit 1
fi
published_after_metadata_change="$(docker port "$soft_id")"
grep -Eq "^23231/tcp -> 127\\.0\\.0\\.1:${local_ssh_port}$" <<<"$published_after_metadata_change"
container_exec soft-serve sh -ec 'nc -z -w 3 127.0.0.1 23231'
GIT_SSH_COMMAND="$git_ssh_command" git ls-remote "$git_roundtrip_remote" refs/heads/main \
    | grep -Fq "$roundtrip_head" || {
        printf '%s\n' 'native SSH Git repository did not survive established-state recreation' >&2
        exit 1
    }

# The original key is now authorized through its persisted admin DB user.
ssh_soft "${TMP_DIR}/admin_key" user list 2>/dev/null | grep -Fq lowpriv
post_recreate_low_info="$(ssh_soft "${TMP_DIR}/admin_key" user info lowpriv 2>/dev/null)"
grep -Fq 'Admin: false' <<<"$post_recreate_low_info"
# The low-privilege key is a persisted user but must not regain global admin
# authority merely because it was inserted into the stale bootstrap field.
ssh_soft "${TMP_DIR}/lowpriv_key" help >/dev/null 2>&1
assert_unauthorized() {
    local output
    if output="$(ssh_soft "${TMP_DIR}/lowpriv_key" "$@" 2>&1)"; then
        printf 'low-privilege command unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
    grep -Fqi 'unauthorized' <<<"$output" || {
        printf 'low-privilege command failed for an unexpected reason: %s\n' "$*" >&2
        exit 1
    }
}
# Check a user-global operation first to distinguish a broad server-admin leak
# from any command-specific settings gate regression.
assert_unauthorized user list
assert_unauthorized settings allow-keyless false
assert_unauthorized user set-admin lowpriv true

case "$E2E_ONION_CHECK_ATTEMPTS" in
    ''|*[!0-9]*)
        printf 'invalid E2E_ONION_CHECK_ATTEMPTS: %s\n' "$E2E_ONION_CHECK_ATTEMPTS" >&2
        exit 2
        ;;
esac
(( E2E_ONION_CHECK_ATTEMPTS > 0 )) || {
    printf 'E2E_ONION_CHECK_ATTEMPTS must be positive\n' >&2
    exit 2
}

# A hosted runner can occasionally reach a healthy local Tor process while its
# public circuit remains stalled below 100% bootstrap. Keep real onion SSH as a
# mandatory assertion, but allow one bounded fresh-Tor retry rather than turning
# transient public-network bootstrap into a false product regression.
"${compose[@]}" --profile check build tor-check >/dev/null

# An explicit identity turns tor-check into an authenticated probe. A wrong key
# must fail instead of being accepted merely because the SSH handshake reached
# Soft Serve and returned "Permission denied".
if "${compose[@]}" --profile check run --rm \
    -e CHECK_TIMEOUT_SECONDS=4 \
    -e SSH_ATTEMPT_TIMEOUT_SECONDS=3 \
    -e SSH_IDENTITY_FILE=/run/secrets/hidden-git-e2e-unauthorized-key \
    -v "${TMP_DIR}/unauthorized_key:/run/secrets/hidden-git-e2e-unauthorized-key:ro" \
    tor-check >/dev/null 2>&1; then
    printf '%s\n' 'tor-check accepted an unauthorized explicit SSH identity' >&2
    exit 1
fi

onion_check_ok=0
for ((attempt = 1; attempt <= E2E_ONION_CHECK_ATTEMPTS; attempt++)); do
    if "${compose[@]}" --profile check run --rm tor-check \
        && "${compose[@]}" --profile check run --rm -e ONION_CHECK_PORT=18002 tor-check; then
        onion_check_ok=1
        break
    fi

    "${compose[@]}" logs --no-color tor >"${TMP_DIR}/tor-attempt-${attempt}.log" 2>&1 || true
    if (( attempt < E2E_ONION_CHECK_ATTEMPTS )); then
        printf 'onion SSH attempt %d/%d failed; recreating Tor for one bounded retry\n' \
            "$attempt" "$E2E_ONION_CHECK_ATTEMPTS" >&2
        "${compose[@]}" up -d --force-recreate --wait tor
    fi
done
(( onion_check_ok == 1 )) || {
    printf 'authenticated onion SSH failed after %d bounded attempt(s)\n' \
        "$E2E_ONION_CHECK_ATTEMPTS" >&2
    exit 1
}

# A real explicit stop/start recovery through existing local images must preserve
# the persisted hidden-service identity. This mirrors autoboot reconciliation's
# Compose recovery primitive without touching the owner's live deployment.
"${compose[@]}" stop tor soft-serve >/dev/null
"${compose[@]}" up -d --no-build --wait soft-serve tor
soft_id="$("${compose[@]}" ps -q soft-serve)"
tor_id="$("${compose[@]}" ps -q tor)"
[[ "$onion_hostname_hash" == "$(container_exec tor sha256sum /var/lib/tor/hidden_service/hostname | awk '{print $1}')" ]] \
    || { printf '%s\n' 'onion hostname bytes changed across explicit stop/start recovery' >&2; exit 1; }

# Recreate both services and verify managed configuration remains authoritative.
first_config_hash="$(printf '%s' "$managed_config" | sha256sum | awk '{print $1}')"
"${compose[@]}" up -d --force-recreate --wait soft-serve tor
soft_id="$("${compose[@]}" ps -q soft-serve)"
tor_id="$("${compose[@]}" ps -q tor)"
second_config="$(container_exec soft-serve cat /run/hidden-git/soft-serve.config.yaml)"
[[ "$first_config_hash" == "$(printf '%s' "$second_config" | sha256sum | awk '{print $1}')" ]]
container_exec soft-serve test -s /var/lib/soft-serve/config.yaml
[[ "$onion_hostname_hash" == "$(container_exec tor sha256sum /var/lib/tor/hidden_service/hostname | awk '{print $1}')" ]] \
    || { printf '%s\n' 'onion hostname bytes changed across service recreation' >&2; exit 1; }

# A configured compatibility port of 2022 must collapse to one Tor declaration,
# never a duplicate virtual-port mapping. Recreating Tor must still preserve the
# exact same persisted onion hostname bytes.
python3 - "$ENV_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = []
for line in path.read_text().splitlines():
    if line.startswith("ONION_PUBLIC_PORT="):
        line = "ONION_PUBLIC_PORT=2022"
    lines.append(line)
path.write_text("\n".join(lines) + "\n")
path.chmod(0o600)
PY
"${compose[@]}" up -d --force-recreate --wait tor
tor_id="$("${compose[@]}" ps -q tor)"
deduped_torrc="$(container_exec tor cat /run/hidden-git/torrc)"
[[ "$(grep -c '^HiddenServicePort ' <<<"$deduped_torrc")" == 1 ]]
grep -Fxq 'HiddenServicePort 2022 soft-serve:23231' <<<"$deduped_torrc"
[[ "$onion_hostname_hash" == "$(container_exec tor sha256sum /var/lib/tor/hidden_service/hostname | awk '{print $1}')" ]] \
    || { printf '%s\n' 'onion hostname bytes changed during duplicate-port convergence' >&2; exit 1; }

if [[ "$E2E_START_FROM_V1" == 1 ]]; then
    # Finish the upgrade contract while both persisted volumes are quiescent:
    # current v2 config validates after real runtime use, then restoring only the
    # pre-migration config bytes must neither alter nor require rewriting DB/repos
    # or the Tor identity volume.
    python3 "$ROOT_DIR/scripts/configctl.py" --env "$ENV_FILE" check >/dev/null
    "${compose[@]}" stop tor soft-serve >/dev/null

    volume_tree_hash() {
        docker run --rm -v "$1:/state:ro" "$ALPINE_IMAGE" sh -ec \
            'find /state -type f -exec sha256sum {} \; | sort | sha256sum'
    }

    soft_state_before="$(volume_tree_hash "$soft_volume")"
    tor_state_before="$(volume_tree_hash "$tor_volume")"
    cp "$migration_backup" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    [[ "$legacy_env_hash" == "$(sha256sum "$ENV_FILE" | awk '{print $1}')" ]] || {
        printf '%s\n' 'v1 E2E rollback did not restore the exact original config bytes' >&2
        exit 1
    }
    rollback_state="$(python3 "$ROOT_DIR/scripts/configctl.py" --env "$ENV_FILE" migrate --json \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')"
    [[ "$rollback_state" == MIGRATABLE ]] || {
        printf 'rolled-back v1 config has unexpected migration state: %s\n' "$rollback_state" >&2
        exit 1
    }
    [[ "$soft_state_before" == "$(volume_tree_hash "$soft_volume")" ]] || {
        printf '%s\n' 'Soft Serve persisted state changed while restoring config rollback bytes' >&2
        exit 1
    }
    [[ "$tor_state_before" == "$(volume_tree_hash "$tor_volume")" ]] || {
        printf '%s\n' 'Tor persisted identity state changed while restoring config rollback bytes' >&2
        exit 1
    }
    printf '%s\n' 'E2E UPGRADE ROLLBACK PASS: v1 -> v2 runtime -> stop -> exact config rollback with state preserved'
fi

printf 'E2E PASS: fixed internal SSH, local SSH, same-identity onion SSH on 2022 + compatibility port, and duplicate-port convergence\n'
