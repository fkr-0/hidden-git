#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
DAEMON_NAME="hidden-git-rootless-dind-$$"
OUTER_DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker.sock}"

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
DIND_IMAGE="$DIND_ROOTLESS_IMAGE"

cleanup() {
    DOCKER_HOST="$OUTER_DOCKER_HOST" docker rm -f "$DAEMON_NAME" >/dev/null 2>&1 || true
    # Rootless containerd overlay snapshots can contain entries that the host
    # runner cannot unlink directly even after the nested daemon exits. Remove
    # this disposable test tree through the outer privileged daemon instead of
    # letting EXIT cleanup turn a successful compatibility test into a failure.
    DOCKER_HOST="$OUTER_DOCKER_HOST" docker run --rm --privileged \
        -v "$TMP_DIR:/work" "$ALPINE_IMAGE" \
        sh -ec 'find /work -mindepth 1 -delete' >/dev/null 2>&1 || true
    rmdir "$TMP_DIR" >/dev/null 2>&1 || true
    return 0
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
chmod 777 \
    "$TMP_DIR/data" \
    "$TMP_DIR/data/soft-serve" \
    "$TMP_DIR/data/tor" \
    "$TMP_DIR/backups"
chmod 700 "$TMP_DIR/rootless-docker"

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
# UIDs differ across environments. Transfer the nested daemon's private state and
# deployment bind directories to that UID, but keep the deployment directories
# temporarily world-writable so the host runner can execute the pre-migration
# mkdir/chmod checks. migrate-users then establishes the actual service owners.
dind_uid="$(DOCKER_HOST="$OUTER_DOCKER_HOST" docker run --rm --entrypoint id "$DIND_IMAGE" -u)"
[[ "$dind_uid" =~ ^[0-9]+$ ]]
DOCKER_HOST="$OUTER_DOCKER_HOST" docker run --rm \
    -v "$TMP_DIR:/work" \
    "$ALPINE_IMAGE" sh -ec '
        uid="$1"
        chown "$uid:$uid" /work/rootless-docker /work/data /work/data/soft-serve /work/data/tor /work/backups
        chmod 700 /work/rootless-docker
        chmod 777 /work/data /work/data/soft-serve /work/data/tor /work/backups
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

# The nested daemon is intentionally disposable and starts with an empty image
# store. Import the already-reviewed base images from the outer daemon so this
# compatibility test exercises rootless builds/runtime instead of spending its
# qualification window re-downloading hundreds of MB from public registries.
for base_image in "$ALPINE_IMAGE" "$GO_IMAGE"; do
    if ! DOCKER_HOST="$OUTER_DOCKER_HOST" docker image inspect "$base_image" >/dev/null 2>&1; then
        DOCKER_HOST="$OUTER_DOCKER_HOST" docker pull "$base_image" >/dev/null
    fi
    DOCKER_HOST="$OUTER_DOCKER_HOST" docker save "$base_image" \
        | DOCKER_HOST="$ROOTLESS_DOCKER_HOST" NO_PROXY=127.0.0.1 docker load >/dev/null
done

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
tor_uid=''
for _ in $(seq 1 60); do
    tor_id="$("${compose[@]}" ps -q tor 2>/dev/null || true)"
    if [[ -n "$tor_id" ]] && tor_uid="$("${compose[@]}" exec -T tor id -u 2>/dev/null)"; then
        break
    fi
    sleep 1
done
if [[ "$tor_uid" != '10002' ]]; then
    printf '%s\n' 'rootless Tor failed to become exec-ready as UID 10002; diagnostics follow' >&2
    "${compose[@]}" ps >&2 || true
    "${compose[@]}" logs --no-color --tail=120 tor >&2 || true
    exit 1
fi
tor_id="$("${compose[@]}" ps -q tor)"
if [[ "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$tor_id")" != 'true' ]]; then
    printf '%s\n' 'rootless Tor container lost its read-only root filesystem policy' >&2
    exit 1
fi
if ! docker inspect --format '{{json .HostConfig.CapDrop}}' "$tor_id" | grep -q ALL; then
    printf '%s\n' 'rootless Tor container lost the ALL capability drop policy' >&2
    exit 1
fi
torrc="$("${compose[@]}" exec -T tor cat /run/hidden-git/torrc)"
if ! grep -Fq 'HiddenServicePort 2022 soft-serve:23231' <<<"$torrc"; then
    printf '%s\n' 'rootless generated torrc is missing mandatory virtual SSH port 2022' >&2
    exit 1
fi
configured_onion_port="$(python3 "$TMP_DIR/scripts/configctl.py" --env "$TMP_DIR/.env" get ONION_PUBLIC_PORT)"
if [[ "$configured_onion_port" != 2022 ]]; then
    if ! grep -Fq "HiddenServicePort ${configured_onion_port} soft-serve:23231" <<<"$torrc"; then
        printf '%s\n' 'rootless generated torrc is missing the configured compatibility mapping' >&2
        exit 1
    fi
fi

# Restart the disposable rootless Docker daemon itself. Compose's
# `restart: unless-stopped` policy must recover both services without a manual
# `compose up`, and the persisted Tor state must keep the exact hostname bytes.
onion_hostname_hash=''
for _ in $(seq 1 90); do
    if "${compose[@]}" exec -T tor sh -ec 'test -s /var/lib/tor/hidden_service/hostname'; then
        onion_hostname_hash="$("${compose[@]}" exec -T tor sha256sum /var/lib/tor/hidden_service/hostname | awk '{print $1}')"
        break
    fi
    sleep 1
done
if [[ ! "$onion_hostname_hash" =~ ^[0-9a-f]{64}$ ]]; then
    printf '%s\n' 'rootless Tor did not persist an onion hostname before daemon-restart qualification' >&2
    "${compose[@]}" ps >&2 || true
    "${compose[@]}" logs --no-color --tail=120 tor >&2 || true
    exit 1
fi

DOCKER_HOST="$OUTER_DOCKER_HOST" docker restart "$DAEMON_NAME" >/dev/null

# The outer Docker daemon may allocate a new ephemeral host port when the DIND
# container is restarted. Re-resolve the disposable endpoint before judging the
# inner daemon's recovery; probing the stale pre-restart publication would turn
# a successful Docker restart into a false HiddenGit failure.
daemon_port="$(DOCKER_HOST="$OUTER_DOCKER_HOST" docker port "$DAEMON_NAME" 2375/tcp | awk -F: 'NR==1{print $NF}')"
[[ "$daemon_port" =~ ^[0-9]+$ ]]
ROOTLESS_DOCKER_HOST="tcp://127.0.0.1:${daemon_port}"
export DOCKER_HOST="$ROOTLESS_DOCKER_HOST"

daemon_ready=0
for _ in $(seq 1 90); do
    if DOCKER_HOST="$ROOTLESS_DOCKER_HOST" NO_PROXY=127.0.0.1 docker info >/dev/null 2>&1; then
        daemon_ready=1
        break
    fi
    sleep 1
done
if [[ "$daemon_ready" != 1 ]]; then
    printf '%s\n' 'rootless Docker daemon did not become ready after outer-container restart; diagnostics follow' >&2
    DOCKER_HOST="$OUTER_DOCKER_HOST" docker inspect "$DAEMON_NAME" >&2 || true
    DOCKER_HOST="$OUTER_DOCKER_HOST" docker logs "$DAEMON_NAME" >&2 || true
    exit 1
fi

services_recovered=0
for _ in $(seq 1 60); do
    running_services="$("${compose[@]}" ps --status running --services 2>/dev/null || true)"
    if grep -Fxq soft-serve <<<"$running_services" && grep -Fxq tor <<<"$running_services"; then
        services_recovered=1
        break
    fi
    sleep 1
done
if [[ "$services_recovered" != 1 ]]; then
    printf '%s\n' 'Compose restart policy did not recover both services after rootless daemon restart' >&2
    "${compose[@]}" ps >&2 || true
    "${compose[@]}" logs --no-color --tail=120 soft-serve tor >&2 || true
    exit 1
fi
recovered_hostname_hash="$("${compose[@]}" exec -T tor sha256sum /var/lib/tor/hidden_service/hostname | awk '{print $1}')"
if [[ "$onion_hostname_hash" != "$recovered_hostname_hash" ]]; then
    printf '%s\n' 'rootless daemon restart changed the persisted onion hostname bytes' >&2
    exit 1
fi

"${compose[@]}" down -v
printf 'PASS: rootless Docker deployment and daemon-restart recovery preserve the onion identity\n'
