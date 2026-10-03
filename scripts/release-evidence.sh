#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${HIDDEN_GIT_ENV_FILE:-${ROOT_DIR}/.env}"
OUTPUT_DIR="${1:-${ROOT_DIR}/release-evidence/$(date -u '+%Y%m%dT%H%M%SZ')}"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
TARGETS="${EVIDENCE_TARGETS:-soft-serve tor tor-check maintenance}"
export VULNERABILITY_POLICY_STRICT="${VULNERABILITY_POLICY_STRICT:-1}"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

read_env_value() {
    local key="$1"
    awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); sub(/[[:space:]]+#.*$/, ""); print; exit}' \
        "$ENV_FILE"
}

require_cmd docker
require_cmd python3
require_cmd sha256sum
docker buildx version >/dev/null 2>&1 || die 'Docker Buildx is required'
[[ -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"

ALPINE_IMAGE="$(read_env_value ALPINE_IMAGE)"
GO_IMAGE="$(read_env_value GO_IMAGE)"
SOFT_SERVE_VERSION="$(read_env_value SOFT_SERVE_VERSION)"
SOFT_SERVE_WISH_VERSION="$(read_env_value SOFT_SERVE_WISH_VERSION)"
SOFT_SERVE_GO_GIT_VERSION="$(read_env_value SOFT_SERVE_GO_GIT_VERSION)"
SOFT_SERVE_GO_JOSE_VERSION="$(read_env_value SOFT_SERVE_GO_JOSE_VERSION)"
SOFT_SERVE_X_CRYPTO_VERSION="$(read_env_value SOFT_SERVE_X_CRYPTO_VERSION)"
SOFT_SERVE_X_NET_VERSION="$(read_env_value SOFT_SERVE_X_NET_VERSION)"
TRIVY_IMAGE="$(read_env_value TRIVY_IMAGE)"
BUILDKIT_IMAGE="$(read_env_value BUILDKIT_IMAGE)"
for value in "$ALPINE_IMAGE" "$GO_IMAGE" "$TRIVY_IMAGE" "$BUILDKIT_IMAGE"; do
    [[ "$value" =~ @sha256:[0-9a-f]{64}$ ]] \
        || die "release evidence requires digest-pinned images; run './run.sh sync-pins'"
done

mkdir -p "$OUTPUT_DIR/.trivy-cache"
OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"
builder="hidden-git-evidence-$$"

cleanup() {
    docker buildx rm "$builder" >/dev/null 2>&1 || true
    rm -rf "$OUTPUT_DIR/.trivy-cache"
}
trap cleanup EXIT

docker buildx create --name "$builder" --driver docker-container \
    --driver-opt "image=${BUILDKIT_IMAGE}" >/dev/null
docker buildx inspect "$builder" --bootstrap >/dev/null

scan_archive() {
    local target="$1"
    local archive="$2"
    local uid_gid layout
    uid_gid="$(id -u):$(id -g)"
    layout="$OUTPUT_DIR/${target}.oci"
    rm -rf "$layout"
    mkdir -p "$layout"
    tar -C "$layout" -xf "$archive"

    docker run --rm --user "$uid_gid" \
        -e HOME=/tmp \
        -v "$OUTPUT_DIR:/evidence" \
        "$TRIVY_IMAGE" image --quiet --input "/evidence/${target}.oci" \
        --cache-dir /evidence/.trivy-cache \
        --skip-db-update --skip-java-db-update \
        --skip-dirs /usr/share/java --skip-dirs /usr/share/maven-repo \
        --format cyclonedx --output "/evidence/${target}.sbom.cdx.json"

    docker run --rm --user "$uid_gid" \
        -e HOME=/tmp \
        -v "$OUTPUT_DIR:/evidence" \
        "$TRIVY_IMAGE" image --quiet --input "/evidence/${target}.oci" \
        --cache-dir /evidence/.trivy-cache \
        --skip-java-db-update \
        --skip-dirs /usr/share/java --skip-dirs /usr/share/maven-repo \
        --scanners vuln --exit-code 0 \
        --format json --output "/evidence/${target}.vulnerabilities.json"

    docker run --rm --user "$uid_gid" \
        -e HOME=/tmp \
        -v "$OUTPUT_DIR:/evidence" \
        "$TRIVY_IMAGE" image --quiet --input "/evidence/${target}.oci" \
        --cache-dir /evidence/.trivy-cache \
        --skip-java-db-update \
        --skip-dirs /usr/share/java --skip-dirs /usr/share/maven-repo \
        --scanners vuln --exit-code 0 \
        --format table --output "/evidence/${target}.vulnerabilities.txt"

    python3 "$ROOT_DIR/scripts/vulnerability-policy.py" \
        "$OUTPUT_DIR/${target}.vulnerabilities.json" \
        "$OUTPUT_DIR/${target}.vulnerability-policy.json"
    rm -rf "$layout"
}

for target in $TARGETS; do
    dockerfile=""
    build_args=(--build-arg "ALPINE_IMAGE=$ALPINE_IMAGE")
    case "$target" in
        soft-serve)
            dockerfile='Dockerfile.soft-serve'
            build_args+=(--build-arg "GO_IMAGE=$GO_IMAGE")
            build_args+=(--build-arg "SOFT_SERVE_VERSION=$SOFT_SERVE_VERSION")
            build_args+=(--build-arg "SOFT_SERVE_WISH_VERSION=$SOFT_SERVE_WISH_VERSION")
            build_args+=(--build-arg "SOFT_SERVE_GO_GIT_VERSION=$SOFT_SERVE_GO_GIT_VERSION")
            build_args+=(--build-arg "SOFT_SERVE_GO_JOSE_VERSION=$SOFT_SERVE_GO_JOSE_VERSION")
            build_args+=(--build-arg "SOFT_SERVE_X_CRYPTO_VERSION=$SOFT_SERVE_X_CRYPTO_VERSION")
            build_args+=(--build-arg "SOFT_SERVE_X_NET_VERSION=$SOFT_SERVE_X_NET_VERSION")
            ;;
        tor) dockerfile='Dockerfile.tor' ;;
        tor-check) dockerfile='Dockerfile.tor-check' ;;
        maintenance) dockerfile='Dockerfile.maintenance' ;;
        *) die "unknown evidence target: $target" ;;
    esac

    archive="$OUTPUT_DIR/${target}.oci.tar"
    printf 'Building evidence for %s\n' "$target"
    docker buildx build --builder "$builder" \
        --file "$ROOT_DIR/$dockerfile" \
        "${build_args[@]}" \
        --tag "hidden-git/${target}:${VERSION}" \
        --provenance=mode=max,version=v1 \
        --output "type=oci,dest=${archive}" \
        --metadata-file "$OUTPUT_DIR/${target}.build-metadata.json" \
        "$ROOT_DIR"

    python3 "$ROOT_DIR/scripts/extract-oci-provenance.py" \
        "$archive" "$OUTPUT_DIR/${target}.provenance.json"
    scan_archive "$target" "$archive"
    if [[ "${KEEP_EVIDENCE_IMAGES:-0}" != 1 ]]; then
        rm -f "$archive"
    fi
done

{
    printf '# HiddenGit release evidence\n\n'
    printf -- "- Version: \`%s\`\n" "$VERSION"
    printf -- "- Git commit: \`%s\`\n" "$(git -C "$ROOT_DIR" rev-parse HEAD)"
    printf -- "- Generated: \`%s\`\n" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf -- "- Scanner: \`%s\`\n" "$TRIVY_IMAGE"
    printf -- "- BuildKit: \`%s\`\n" "$BUILDKIT_IMAGE"
    printf -- "- Targets: \`%s\`\n" "$TARGETS"
    printf '\n## Files\n\n```text\n'
    (cd "$OUTPUT_DIR" && sha256sum ./*.json ./*.txt 2>/dev/null | sort)
    printf '```\n'
} > "$OUTPUT_DIR/SUMMARY.md"

printf 'Release evidence written to %s\n' "$OUTPUT_DIR"
