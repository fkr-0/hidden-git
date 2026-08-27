#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d /tmp/hidden-git-rootless-test.XXXXXX)"
DAEMON_NAME="hidden-git-rootless-dind-$$"
OUTER_DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"

read_example() {
    sed -n "s/^$1=//p" "$ROOT_DIR/env.example" | head -n1
}

DIND_IMAGE="$(read_example DIND_ROOTLESS_IMAGE)"
ALPINE_IMAGE="$(read_example ALPINE_IMAGE)"

cleanup() {
    DOCKER_HOST="$OUTER_DOCKER_HOST" docker rm -f "$DAEMON_NAME" >/dev/null 2>&1 || true
    DOCKER_HOST="$OUTER_DOCKER_HOST" docker run --rm -v "$TMP_DIR:/work" "$ALPINE_IMAGE" \
        sh -lc 'chmod -R a+rwX /work' >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

tar \
    --exclude=.git \
    --exclude=.env \
    --exclude='.env.*' \
    --exclude=.envBackup \
    --exclude=data \
    --exclude=backups \
    --exclude=retired-state \
    --exclude=release-evidence \
    --exclude=soft-serve-data \
    --exclude=tor-data \
    -C "$ROOT_DIR" -cf - . | tar -C "$TMP_DIR" -xf -
cp "$ROOT_DIR/env.example" "$TMP_DIR/.env"
mkdir -p \
    "$TMP_DIR/data/soft-serve" \
    "$TMP_DIR/data/tor" \
    "$TMP_DIR/backups" \
    "$TMP_DIR/rootless-docker"
chmod 755 "$TMP_DIR"
chmod 700 \
    "$TMP_DIR/data" \
    "$TMP_DIR/data/soft-serve" \
    "$TMP_DIR/data/tor" \
    "$TMP_DIR/backups" \
    "$TMP_DIR/rootless-docker"

ssh-keygen -q -t ed25519 -N '' -f "$TMP_DIR/admin_key"
admin_key="$(cat "$TMP_DIR/admin_key.pub")"
python3 - "$TMP_DIR/.env" "$admin_key" <<'PY'
from pathlib import Path
import socket
import sys


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


path = Path(sys.argv[1])
admin_key = sys.argv[2]
ports = [free_port() for _ in range(2)]
updates = {
    "SOFT_SERVE_INITIAL_ADMIN_KEYS": admin_key,
    "LOCAL_SSH_PORT": str(ports[0]),
    "ONION_PUBLIC_PORT": str(ports[1]),
    "SOFT_SERVE_SSH_PUBLIC_URL": "",
}
lines = []
seen = set()
for line in path.read_text().splitlines():
    key = line.split("=", 1)[0]
    if key in updates:
        lines.append(f"{key}={updates[key]}")
        seen.add(key)
    else:
        lines.append(line)
for key, value in updates.items():
    if key not in seen:
        lines.append(f"{key}={value}")
path.write_text("\n".join(lines) + "\n")
path.chmod(0o600)
PY

# The pinned dind-rootless image runs its daemon as a non-root user. Runner host
# UIDs differ across environments, so normalize only the disposable paths that
# the nested daemon itself must write.
dind_uid="$(DOCKER_HOST="$OUTER_DOCKER_HOST" docker run --rm --entrypoint id "$DIND_IMAGE" -u)"
[[ "$dind_uid" =~ ^[0-9]+$ ]]
DOCKER_HOST="$OUTER_DOCKER_HOST" docker run --rm \
    -v "$TMP_DIR:/work" \
    "$ALPINE_IMAGE" sh -ec '
        uid="$1"
        chown "$uid:$uid" /work/rootless-docker /work/data /work/data/soft-serve /work/data/tor /work/backups
        chmod 700 /work/rootless-docker /work/data /work/data/soft-serve /work/data/tor /work/backups
    ' sh "$dind_uid"

DOCKER_HOST="$OUTER_DOCKER_HOST" docker run -d --privileged \
    --name "$DAEMON_NAME" \
    -e DOCKER_TLS_CERTDIR= \
    -p 127.0.0.1::2375 \
    -v "$TMP_DIR:$TMP_DIR" \
    -v "$TMP_DIR/rootless-docker:/home/rootless/.local/share/docker" \
    "$DIND_IMAGE" --host=tcp://0.0.0.0:2375 --tls=false >/dev/null

daemon_port="$(DOCKER_HOST="$OUTER_DOCKER_HOST" docker port "$DAEMON_NAME" 2375/tcp | awk -F: 'NR==1{print $NF}')"
[[ "$daemon_port" =~ ^[0-9]+$ ]]
ROOTLESS_DOCKER_HOST="tcp://127.0.0.1:${daemon_port}"

daemon_ready=0
for _ in $(seq 1 90); do
    if DOCKER_HOST="$ROOTLESS_DOCKER_HOST" NO_PROXY=127.0.0.1 docker info >/dev/null 2>&1; then
        daemon_ready=1
        break
    fi
    if [[ "$(DOCKER_HOST="$OUTER_DOCKER_HOST" docker inspect --format '{{.State.Running}}' "$DAEMON_NAME" 2>/dev/null || true)" != true ]]; then
        break
    fi
    sleep 1
done
if [[ "$daemon_ready" != 1 ]]; then
    printf '%s\n' 'rootless Docker daemon failed to become ready; diagnostics follow' >&2
    DOCKER_HOST="$OUTER_DOCKER_HOST" docker inspect "$DAEMON_NAME" >&2 || true
    DOCKER_HOST="$OUTER_DOCKER_HOST" docker logs "$DAEMON_NAME" >&2 || true
    exit 1
fi

DOCKER_HOST="$ROOTLESS_DOCKER_HOST" NO_PROXY=127.0.0.1 \
    docker info --format '{{json .SecurityOptions}}' | grep -q rootless

export DOCKER_HOST="$ROOTLESS_DOCKER_HOST"
export NO_PROXY=127.0.0.1
export HIDDEN_GIT_ENV_FILE="$TMP_DIR/.env"

"$TMP_DIR/run.sh" migrate-users

compose=(docker compose --env-file "$TMP_DIR/.env" -f "$TMP_DIR/docker-compose.yml")
"${compose[@]}" up -d --build --wait soft-serve
[[ "$("${compose[@]}" exec -T soft-serve id -u)" == '10001' ]]
"${compose[@]}" --profile maintenance run --rm -T maintenance ownership-ok

soft_id="$("${compose[@]}" ps -q soft-serve)"
[[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$soft_id")" == 'true' ]]
docker inspect --format '{{json .HostConfig.CapDrop}}' "$soft_id" | grep -q ALL

"${compose[@]}" up -d --build tor
for _ in $(seq 1 30); do
    tor_id="$("${compose[@]}" ps -q tor)"
    if [[ -n "$tor_id" && "$(docker inspect --format '{{.State.Running}}' "$tor_id")" == true ]]; then
        break
    fi
    sleep 1
done
[[ "$("${compose[@]}" exec -T tor id -u)" == '10002' ]]
tor_id="$("${compose[@]}" ps -q tor)"
[[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$tor_id")" == 'true' ]]
docker inspect --format '{{json .HostConfig.CapDrop}}' "$tor_id" | grep -q ALL

"${compose[@]}" down -v
printf 'PASS: Docker Compose deployment works against a rootless Docker daemon\n'
