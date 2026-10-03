#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="hidden-git-maintenance-migration-test-$$"
TMP_DIR="$(mktemp -d /tmp/hidden-git-migration-test.XXXXXX)"

cleanup() {
    docker run --rm -v "$TMP_DIR:/work" \
        "$(sed -n 's/^ALPINE_IMAGE=//p' "$ROOT_DIR/env.example")" \
        sh -lc 'chmod -R a+rwX /work' >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/data/soft-serve/ssh" "$TMP_DIR/data/tor/hidden_service" \
    "$TMP_DIR/backups"
printf 'existing database\n' > "$TMP_DIR/data/soft-serve/soft-serve.db"
printf 'existing onion key\n' > "$TMP_DIR/data/tor/hidden_service/hs_ed25519_secret_key"

docker build -q -f "$ROOT_DIR/Dockerfile.maintenance" -t "$IMAGE" "$ROOT_DIR" >/dev/null
docker run --rm \
    -v "$TMP_DIR/data:/hidden-git/data" \
    -v "$TMP_DIR/backups:/hidden-git/backups" \
    -e "OUTPUT_UID=$(id -u)" -e "OUTPUT_GID=$(id -g)" \
    "$IMAGE" permissions >/dev/null
[[ "$(stat -c '%u:%g' "$TMP_DIR/data")" == "$(id -u):$(id -g)" ]]
[[ "$(stat -c '%u:%g' "$TMP_DIR/backups")" == "$(id -u):$(id -g)" ]]

docker run --rm \
    -v "$TMP_DIR/data:/hidden-git/data" \
    -v "$TMP_DIR/backups:/hidden-git/backups" \
    -e "OUTPUT_UID=$(id -u)" -e "OUTPUT_GID=$(id -g)" \
    "$IMAGE" migrate-users >/dev/null

owner() {
    docker run --rm --entrypoint stat \
        -v "$TMP_DIR/data:/data:ro" "$IMAGE" -c '%u:%g' "$1"
}

[[ "$(owner /data/soft-serve)" == '10001:10001' ]]
[[ "$(owner /data/soft-serve/soft-serve.db)" == '10001:10001' ]]
[[ "$(owner /data/tor)" == '10002:10002' ]]
[[ "$(owner /data/tor/hidden_service/hs_ed25519_secret_key)" == '10002:10002' ]]
[[ "$(stat -c '%u:%g' "$TMP_DIR/data")" == "$(id -u):$(id -g)" ]]

# The migration is intentionally idempotent.
docker run --rm \
    -v "$TMP_DIR/data:/hidden-git/data" \
    -v "$TMP_DIR/backups:/hidden-git/backups" \
    -e "OUTPUT_UID=$(id -u)" -e "OUTPUT_GID=$(id -g)" \
    "$IMAGE" migrate-users >/dev/null

printf 'PASS: idempotent dedicated-user ownership migration\n'
