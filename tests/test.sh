#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

pass() {
    printf 'PASS: %s\n' "$*"
}

for script in run.sh scripts/*.sh tests/*.sh; do
    bash -n "$script"
done
pass 'shell syntax'

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck run.sh scripts/*.sh tests/*.sh
    pass 'shellcheck'
else
    printf 'SKIP: shellcheck is not installed\n'
fi

if command -v yamllint >/dev/null 2>&1; then
    yamllint -d '{extends: default, rules: {line-length: {max: 120}, document-start: disable}}' \
        docker-compose.yml docker-compose.tor-check.override.yml issues.yml
    pass 'YAML lint'
else
    printf 'SKIP: yamllint is not installed\n'
fi

version="$(tr -d '[:space:]' < VERSION)"
grep -Fq "## [$version]" CHANGELOG.md || fail "CHANGELOG.md has no release section for $version"
grep -Fq "HIDDEN_GIT_VERSION=$version" env.example || fail "env.example version differs from VERSION"
pass 'version consistency'

grep -Eq '^DEBIAN_IMAGE=.*@sha256:[0-9a-f]{64}$' env.example \
    || fail 'DEBIAN_IMAGE is not pinned by digest'
grep -Eq '^GO_IMAGE=.*@sha256:[0-9a-f]{64}$' env.example \
    || fail 'GO_IMAGE is not pinned by digest'
grep -Eq '^ARG DEBIAN_IMAGE=.*@sha256:[0-9a-f]{64}$' Dockerfile.tor \
    || fail 'Tor base image is not pinned by digest'
grep -Eq '^ARG GO_IMAGE=.*@sha256:[0-9a-f]{64}$' Dockerfile.soft-serve \
    || fail 'Go builder image is not pinned by digest'
pass 'container image digest pinning'

for forbidden in '.env' '.envBackup' 'data/' 'soft-serve-data/' 'tor-data/' 'trunk/'; do
    if git ls-files | grep -Eq "^${forbidden//./\.}"; then
        fail "runtime or secret path is tracked: $forbidden"
    fi
done
pass 'tracked-secret hygiene'

grep -Fq "\${HOST_BIND_ADDRESS:-127.0.0.1}" docker-compose.yml \
    || fail 'Compose ports are not loopback-safe by default'
pass 'safe host binding default'

for protected in '.env' 'data' 'soft-serve-data' 'tor-data' 'trunk'; do
    grep -Fxq "$protected" .dockerignore \
        || fail ".dockerignore does not protect: $protected"
done
pass 'Docker build-context secret hygiene'

grep -Fq 'timeout --signal=TERM' scripts/tor-check.sh \
    || fail 'containerized SSH attempts lack a hard timeout'
grep -Fq 'timeout --signal=TERM' run.sh \
    || fail 'host-side SSH attempts lack a hard timeout'
pass 'bounded SSH attempts'

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose --env-file env.example \
        -f docker-compose.yml \
        -f docker-compose.tor-check.override.yml \
        config >/dev/null
    pass 'Docker Compose configuration'

    temp_env="$(mktemp)"
    trap 'rm -f "$temp_env"' EXIT
    sed 's/^ONION_PUBLIC_PORT=8002$/ONION_PUBLIC_PORT=8002 # parser regression/' env.example > "$temp_env"
    HIDDEN_GIT_ENV_FILE="$temp_env" ./run.sh config >/dev/null
    rm -f "$temp_env"
    trap - EXIT
    pass 'environment parser with inline comments'

    legacy_env="$(mktemp)"
    trap 'rm -f "$legacy_env"' EXIT
    grep -Ev '^(HIDDEN_GIT_VERSION|SOFT_SERVE_NAME|HOST_BIND_ADDRESS|SOFT_SERVE_(SSH|HTTP|GIT)_PUBLIC_URL|CHECK_TIMEOUT_SECONDS)=' \
        env.example > "$legacy_env"
    HIDDEN_GIT_ENV_FILE="$legacy_env" ./run.sh config >/dev/null
    rm -f "$legacy_env"
    trap - EXIT
    pass 'pre-0.0.2 environment compatibility'
else
    printf 'SKIP: Docker Compose is not available\n'
fi

./run.sh help >/dev/null
./run.sh version | grep -Fq "$version"
pass 'Docker-free help and version commands'

[[ -f .github/workflows/ci.yml ]] || fail 'CI workflow is missing'
[[ -f .github/dependabot.yml ]] || fail 'Dependabot configuration is missing'
pass 'repository automation manifests'

printf 'All static release checks passed.\n'

