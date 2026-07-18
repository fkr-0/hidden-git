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
    TMP_DIR="$(mktemp -d /tmp/hidden-git-e2e.XXXXXX)"
fi
PROJECT="hidden-git-e2e-$$"
ENV_FILE="${TMP_DIR}/e2e.env"
OVERRIDE_FILE="${TMP_DIR}/e2e.override.yml"
LOG_FILE="${TMP_DIR}/compose.log"
KEEP_ARTIFACTS="${KEEP_E2E_ARTIFACTS:-0}"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'missing required command: %s\n' "$1" >&2
        exit 1
    }
}

require_cmd docker
require_cmd python
require_cmd ssh
require_cmd ssh-keygen
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
admin_key="$(cat "${TMP_DIR}/admin_key.pub")"

python - "$ENV_FILE" "$admin_key" <<'PY'
from pathlib import Path
import socket
import sys

path = Path(sys.argv[1])
admin_key = sys.argv[2]

def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])

ssh_port, http_port, stats_port, git_port = [free_port() for _ in range(4)]
updates = {
    "SOFT_SERVE_INITIAL_ADMIN_KEYS": f'"{admin_key}"',
    "SOFT_SERVE_SSH_PORT": str(ssh_port),
    "SOFT_SERVE_HTTP_PORT": str(http_port),
    "SOFT_SERVE_STATS_PORT": str(stats_port),
    "SOFT_SERVE_GIT_PORT": str(git_port),
    "ONION_TARGET_PORT": str(ssh_port),
    "ONION_PUBLIC_PORT": "18002",
    "SOFT_SERVE_SSH_PUBLIC_URL": f"ssh://localhost:{ssh_port}",
    "SOFT_SERVE_HTTP_PUBLIC_URL": f"http://localhost:{http_port}",
    "SOFT_SERVE_GIT_PUBLIC_URL": f"git://localhost:{git_port}",
    "CHECK_TIMEOUT_SECONDS": "240",
}

lines = []
for line in path.read_text().splitlines():
    key = line.split("=", 1)[0] if "=" in line else None
    if key in updates:
        line = f"{key}={updates[key]}"
    lines.append(line)
path.write_text("\n".join(lines) + "\n")
PY
chmod 600 "$ENV_FILE" "${TMP_DIR}/admin_key"

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
      SSH_ATTEMPT_TIMEOUT_SECONDS: 20
      SSH_IDENTITY_FILE: /run/secrets/hidden-git-e2e-key
    volumes:
      - tor-e2e-data:/var/lib/tor:ro
      - ${TMP_DIR}/admin_key:/run/secrets/hidden-git-e2e-key:ro
volumes:
  soft-serve-e2e-data:
  tor-e2e-data:
YAML

"${compose[@]}" --profile check config >/dev/null
"${compose[@]}" up -d --build --wait

"${compose[@]}" exec -T soft-serve sh -ec \
    'test -s /run/hidden-git/soft-serve.config.yaml && grep -q "listen_addr" /run/hidden-git/soft-serve.config.yaml'

onion_host="$("${compose[@]}" exec -T tor cat /var/lib/tor/hidden_service/hostname | tr -d '\r\n')"
[[ "$onion_host" == *.onion ]] || {
    printf 'invalid onion hostname: %s\n' "$onion_host" >&2
    exit 1
}

ssh_port="$(awk -F= '$1=="SOFT_SERVE_SSH_PORT" {print $2}' "$ENV_FILE")"
local_output="$(ssh \
    -i "${TMP_DIR}/admin_key" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p "$ssh_port" \
    admin@127.0.0.1 help 2>&1)"
printf '%s\n' "$local_output" | grep -Eq 'Soft Serve|Usage:|Available Commands:' || {
    printf 'authenticated local SSH command returned unexpected output:\n%s\n' "$local_output" >&2
    exit 1
}

"${compose[@]}" --profile check run --rm --build tor-check >/dev/null

printf 'E2E PASS: fresh deployment, authenticated local SSH, and authenticated onion SSH (%s)\n' "$onion_host"

