#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="hidden-git-maintenance-test-$$"
TMP_DIR="$(mktemp -d /tmp/hidden-git-backup-test.XXXXXX)"

cleanup() {
    docker run --rm -v "$TMP_DIR:/work" \
        "$(sed -n 's/^ALPINE_IMAGE=//p' "$ROOT_DIR/env.example")" \
        sh -lc 'chmod -R a+rwX /work' >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
    docker image rm "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/data/soft-serve/repos" "$TMP_DIR/data/tor/hidden_service" \
    "$TMP_DIR/backups" "$TMP_DIR/keys"
printf 'database fixture\n' > "$TMP_DIR/data/soft-serve/soft-serve.db"
printf 'repository fixture\n' > "$TMP_DIR/data/soft-serve/repos/demo.git"
printf 'onion identity fixture\n' > "$TMP_DIR/data/tor/hidden_service/hs_ed25519_secret_key"

docker build -q -f "$ROOT_DIR/Dockerfile.maintenance" -t "$IMAGE" "$ROOT_DIR" >/dev/null

docker run --rm -v "$TMP_DIR/keys:/keys" \
    -e "OUTPUT_UID=$(id -u)" -e "OUTPUT_GID=$(id -g)" \
    "$IMAGE" keygen /keys/backup.agekey >/dev/null
recipient="$(cat "$TMP_DIR/keys/backup.agekey.recipient")"

docker run --rm \
    -v "$TMP_DIR/data:/hidden-git/data" \
    -v "$TMP_DIR/backups:/hidden-git/backups" \
    -e "BACKUP_RECIPIENT=$recipient" \
    -e "OUTPUT_UID=$(id -u)" -e "OUTPUT_GID=$(id -g)" \
    "$IMAGE" backup >/dev/null
archive="$(find "$TMP_DIR/backups" -name '*.tar.age' -print -quit)"
[[ -f "$archive" && -f "${archive}.sha256" ]]

rm -rf "$TMP_DIR/data"
mkdir -p "$TMP_DIR/data/soft-serve" "$TMP_DIR/data/tor"
docker run --rm \
    -v "$TMP_DIR/data:/hidden-git/data" \
    -v "$archive:/run/backup.tar.age:ro" \
    -v "${archive}.sha256:/run/backup.tar.age.sha256:ro" \
    -v "$TMP_DIR/keys/backup.agekey:/run/secrets/age-identity:ro" \
    -e RESTORE_ARCHIVE=/run/backup.tar.age \
    -e RESTORE_IDENTITY_FILE=/run/secrets/age-identity \
    -e RESTORE_MODE=preserve \
    "$IMAGE" restore >/dev/null
grep -Fxq 'repository fixture' "$TMP_DIR/data/soft-serve/repos/demo.git"
grep -Fxq 'onion identity fixture' "$TMP_DIR/data/tor/hidden_service/hs_ed25519_secret_key"

rm -rf "$TMP_DIR/data"
mkdir -p "$TMP_DIR/data/soft-serve" "$TMP_DIR/data/tor"
docker run --rm \
    -v "$TMP_DIR/data:/hidden-git/data" \
    -v "$archive:/run/backup.tar.age:ro" \
    -v "${archive}.sha256:/run/backup.tar.age.sha256:ro" \
    -v "$TMP_DIR/keys/backup.agekey:/run/secrets/age-identity:ro" \
    -e RESTORE_ARCHIVE=/run/backup.tar.age \
    -e RESTORE_IDENTITY_FILE=/run/secrets/age-identity \
    -e RESTORE_MODE=rotate \
    "$IMAGE" restore >/dev/null
grep -Fxq 'repository fixture' "$TMP_DIR/data/soft-serve/repos/demo.git"
[[ ! -e "$TMP_DIR/data/tor/hidden_service/hs_ed25519_secret_key" ]]

printf 'PASS: encrypted backup, verified restore, and onion identity rotation\n'
