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
        docker-compose.yml docker-compose.tor-check.override.yml issues.yml \
        .github/workflows/ci.yml .github/workflows/pages.yml .github/dependabot.yml
    pass 'YAML lint'
else
    printf 'SKIP: yamllint is not installed\n'
fi

version="$(tr -d '[:space:]' < VERSION)"
semver_re='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-((0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)(\.(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*))*))?(\+([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$'
[[ "$version" =~ $semver_re ]] || fail "VERSION is not valid SemVer: $version"
grep -Fq '## [Unreleased]' CHANGELOG.md || fail 'CHANGELOG.md has no Unreleased section'
[[ "$(grep -Fc "## [$version] -" CHANGELOG.md)" == '1' ]] \
    || fail "CHANGELOG.md must contain exactly one dated release section for $version"
grep -Fxq "HIDDEN_GIT_VERSION=$version" env.example \
    || fail "env.example version differs from VERSION"
grep -Fxq "#+SUBTITLE: Release $version" README.org \
    || fail "README release subtitle differs from VERSION"
if [[ "${GITHUB_REF_TYPE:-}" == 'tag' ]]; then
    [[ "${GITHUB_REF_NAME:-}" == "v$version" ]] \
        || fail "release tag ${GITHUB_REF_NAME:-<missing>} does not match v$version"
fi
for release_doc in ARCHITECTURE.md ROADMAP.md RELEASING.md; do
    [[ -s "$release_doc" ]] || fail "release documentation is missing: $release_doc"
done
pass 'SemVer and release metadata consistency'

grep -Fq 'MIT License' LICENSE || fail 'canonical MIT license text is missing'
grep -Fq 'MIT License' README.org || fail 'README does not reference the license'
pass 'license metadata'

grep -Eq '^ALPINE_IMAGE=.*@sha256:[0-9a-f]{64}$' env.example \
    || fail 'ALPINE_IMAGE is not pinned by digest'
grep -Eq '^GO_IMAGE=.*@sha256:[0-9a-f]{64}$' env.example \
    || fail 'GO_IMAGE is not pinned by digest'
grep -Eq '^TRIVY_IMAGE=.*@sha256:[0-9a-f]{64}$' env.example \
    || fail 'TRIVY_IMAGE is not pinned by digest'
grep -Eq '^BUILDKIT_IMAGE=.*@sha256:[0-9a-f]{64}$' env.example \
    || fail 'BUILDKIT_IMAGE is not pinned by digest'
grep -Eq '^DIND_ROOTLESS_IMAGE=.*@sha256:[0-9a-f]{64}$' env.example \
    || fail 'DIND_ROOTLESS_IMAGE is not pinned by digest'
for key in SOFT_SERVE_WISH_VERSION SOFT_SERVE_GO_GIT_VERSION \
    SOFT_SERVE_GO_JOSE_VERSION SOFT_SERVE_X_CRYPTO_VERSION SOFT_SERVE_X_NET_VERSION; do
    grep -Eq "^${key}=v[0-9]" env.example \
        || fail "$key is not explicitly versioned"
done
pass 'Soft Serve security override versioning'
grep -Eq '^ARG ALPINE_IMAGE=.*@sha256:[0-9a-f]{64}$' Dockerfile.tor \
    || fail 'Tor base image is not pinned by digest'
grep -Eq '^ARG GO_IMAGE=.*@sha256:[0-9a-f]{64}$' Dockerfile.soft-serve \
    || fail 'Go builder image is not pinned by digest'
for dockerfile in Dockerfile.soft-serve Dockerfile.tor Dockerfile.tor-check Dockerfile.maintenance; do
    grep -Fq 'apk upgrade --no-cache' "$dockerfile" \
        || fail "$dockerfile does not apply current Alpine security package upgrades"
done
pass 'container image digest pinning and base-package security upgrades'

for forbidden in '.env' '.envBackup' 'data/' 'soft-serve-data/' 'tor-data/' 'trunk/'; do
    if git ls-files | grep -Eq "^${forbidden//./\.}"; then
        fail "runtime or secret path is tracked: $forbidden"
    fi
done
pass 'tracked-secret hygiene'

grep -Fq 'LOCAL_SSH_PORT:-23231}:23231' docker-compose.yml \
    || fail 'Compose local SSH publication is not decoupled from the fixed internal port'
grep -Fq 'HOST_BIND_ADDRESS:-127.0.0.1' docker-compose.yml \
    || fail 'Compose local SSH publication is not loopback-safe by default'
if grep -Eq 'SOFT_SERVE_(SSH|HTTP|STATS|GIT)_PORT|ONION_TARGET_PORT|SOFT_SERVE_DATA_PATH|[[:space:]]CI:' docker-compose.yml; then
    fail 'Compose still exposes retired internal topology variables'
fi
[[ "$(grep -c '^      - .*:' docker-compose.yml)" -ge 1 ]] || fail 'Compose has no port publication'
grep -Fq 'listen_addr: "127.0.0.1:23233"' soft-serve.config.yaml.template \
    || fail 'Soft Serve stats are not loopback-only'
grep -A2 '^git:' soft-serve.config.yaml.template | grep -Fq 'enabled: false' \
    || fail 'native git daemon is not disabled by default'
grep -A2 '^http:' soft-serve.config.yaml.template | grep -Fq 'enabled: false' \
    || fail 'HTTP server is not disabled by default'
grep -A2 '^lfs:' soft-serve.config.yaml.template | grep -Fq 'enabled: false' \
    || fail 'LFS is not disabled in the SSH-only default profile'
pass 'minimal fixed internal network topology'

for protected in '.env' 'data' 'soft-serve-data' 'tor-data' 'trunk'; do
    grep -Fxq "$protected" .dockerignore \
        || fail ".dockerignore does not protect: $protected"
done
pass 'Docker build-context secret hygiene'

grep -Fxq 'backups/' .gitignore || fail 'encrypted backups are not ignored by Git'
grep -Fxq 'backups' .dockerignore || fail 'encrypted backups enter the Docker build context'
grep -Fxq 'release-evidence' .dockerignore || fail 'release evidence enters the Docker build context'
pass 'backup secret hygiene'

grep -Fq 'timeout --signal=TERM' scripts/tor-check.sh \
    || fail 'containerized SSH attempts lack a hard timeout'
grep -Fq 'timeout --signal=TERM' run.sh \
    || fail 'host-side SSH attempts lack a hard timeout'
pass 'bounded SSH attempts'

config_fixture="$(mktemp -d)"
trap 'rm -rf "$config_fixture"' EXIT
cp env.example "$config_fixture/current.env"
chmod 600 "$config_fixture/current.env"
HIDDEN_GIT_ENV_FILE="$config_fixture/current.env" ./run.sh config check >/dev/null
first_hash="$(sha256sum "$config_fixture/current.env" | awk '{print $1}')"
HIDDEN_GIT_ENV_FILE="$config_fixture/current.env" ./run.sh config migrate --apply \
    | grep -Fq 'No changes applied; no rollback copy created'
[[ "$first_hash" == "$(sha256sum "$config_fixture/current.env" | awk '{print $1}')" ]] \
    || fail 'canonical migration changed a current config'
pass 'current configuration schema and no-op migration'

cat > "$config_fixture/legacy.env" <<'EOF'
HIDDEN_GIT_VERSION=0.0.3
ALPINE_IMAGE=alpine:old
GO_IMAGE=golang:old
SOFT_SERVE_VERSION=v0.11.6
SOFT_SERVE_WISH_VERSION=v2.0.1
SOFT_SERVE_GO_GIT_VERSION=v5.19.0
SOFT_SERVE_GO_JOSE_VERSION=v3.0.5
SOFT_SERVE_X_CRYPTO_VERSION=v0.52.0
SOFT_SERVE_X_NET_VERSION=v0.55.0
TRIVY_IMAGE=trivy:old
BUILDKIT_IMAGE=buildkit:old
DIND_ROOTLESS_IMAGE=dind:old
SOFT_SERVE_SSH_PORT=40123
SOFT_SERVE_HTTP_PORT=23232
SOFT_SERVE_STATS_PORT=23233
SOFT_SERVE_GIT_PORT=9418
ONION_TARGET_PORT=40123
ONION_PUBLIC_PORT=8002 # inline-comment regression
SOFT_SERVE_DATA_PATH=/var/lib/soft-serve
SOFT_SERVE_NAME="Legacy # forge"
SOFT_SERVE_INITIAL_ADMIN_KEYS="ssh-ed25519 DO-NOT-PRINT operator@example"
CI=1
HOST_BIND_ADDRESS=127.0.0.1
SOFT_SERVE_SSH_PUBLIC_URL=ssh://localhost:40123
SOFT_SERVE_HTTP_PUBLIC_URL=http://localhost:23232
SOFT_SERVE_GIT_PUBLIC_URL=git://localhost:9418
SOFT_SERVE_SSH_USER=admin
CHECK_TIMEOUT_SECONDS=180
BACKUP_RECIPIENT=
BACKUP_IDENTITY_FILE=/secret/recovery/key
EOF
chmod 600 "$config_fixture/legacy.env"
preview="$(HIDDEN_GIT_ENV_FILE="$config_fixture/legacy.env" ./run.sh config migrate)"
grep -Fq 'add LOCAL_SSH_PORT' <<<"$preview"
if grep -Eq 'DO-NOT-PRINT|/secret/recovery/key' <<<"$preview"; then
    fail 'config migration preview leaked secret-bearing values'
fi
HIDDEN_GIT_ENV_FILE="$config_fixture/legacy.env" ./run.sh config migrate --apply >/dev/null
grep -Fxq 'LOCAL_SSH_PORT=40123' "$config_fixture/legacy.env" \
    || fail 'legacy custom SSH port was not preserved as the local host port'
if grep -Eq '^(SOFT_SERVE_(SSH|HTTP|STATS|GIT)_PORT|ONION_TARGET_PORT|SOFT_SERVE_DATA_PATH|CI)=' \
    "$config_fixture/legacy.env"; then
    fail 'legacy internal topology keys survived canonical migration'
fi
[[ "$(stat -c '%a' "$config_fixture/legacy.env")" == '600' ]]
legacy_hash="$(sha256sum "$config_fixture/legacy.env" | awk '{print $1}')"
backup_count="$(find "$config_fixture" -maxdepth 1 -name 'legacy.env.pre-config-*' | wc -l)"
HIDDEN_GIT_ENV_FILE="$config_fixture/legacy.env" ./run.sh config migrate --apply \
    | grep -Fq 'No changes applied; no rollback copy created'
[[ "$legacy_hash" == "$(sha256sum "$config_fixture/legacy.env" | awk '{print $1}')" ]]
[[ "$backup_count" == "$(find "$config_fixture" -maxdepth 1 -name 'legacy.env.pre-config-*' | wc -l)" ]]
pass 'legacy configuration convergence and second-apply idempotency'

cp env.example "$config_fixture/duplicate.env"
printf 'LOCAL_SSH_PORT=49999\n' >> "$config_fixture/duplicate.env"
chmod 600 "$config_fixture/duplicate.env"
if HIDDEN_GIT_ENV_FILE="$config_fixture/duplicate.env" ./run.sh config check >/dev/null 2>&1; then
    fail 'duplicate config key was accepted'
fi
cp env.example "$config_fixture/unknown.env"
printf 'LOCAL_SSH_P0RT=49999\n' >> "$config_fixture/unknown.env"
chmod 600 "$config_fixture/unknown.env"
if HIDDEN_GIT_ENV_FILE="$config_fixture/unknown.env" ./run.sh config check >/dev/null 2>&1; then
    fail 'unknown config key was accepted'
fi
sed -e 's/^LOCAL_SSH_PORT=.*/SOFT_SERVE_SSH_PORT=40123/' \
    -e '/^ONION_PUBLIC_PORT=/a ONION_TARGET_PORT=40124' \
    env.example > "$config_fixture/conflict.env"
chmod 600 "$config_fixture/conflict.env"
if HIDDEN_GIT_ENV_FILE="$config_fixture/conflict.env" ./run.sh config migrate >/dev/null 2>&1; then
    fail 'mismatched legacy SSH/Tor target was migrated instead of failing closed'
fi
pass 'duplicate, unknown, and ambiguous legacy config rejection'

sync_env="$config_fixture/sync.env"
cp env.example "$sync_env"
sed -i \
    -e 's#^ALPINE_IMAGE=.*#ALPINE_IMAGE=alpine:3.23#' \
    -e 's#^GO_IMAGE=.*#GO_IMAGE=golang:1.26.7-bookworm#' \
    -e '/^TRIVY_IMAGE=/d' \
    -e '/^BUILDKIT_IMAGE=/d' \
    -e 's/^LOCAL_SSH_PORT=.*/LOCAL_SSH_PORT=40123/' \
    "$sync_env"
chmod 644 "$sync_env"
HIDDEN_GIT_ENV_FILE="$sync_env" ./run.sh sync-pins >/dev/null
grep -Fxq 'LOCAL_SSH_PORT=40123' "$sync_env" \
    || fail 'sync-pins changed a deployment-specific local SSH port'
grep -Eq '^ALPINE_IMAGE=.*@sha256:[0-9a-f]{64}$' "$sync_env" \
    || fail 'sync-pins did not restore the Alpine digest'
grep -Eq '^TRIVY_IMAGE=.*@sha256:[0-9a-f]{64}$' "$sync_env" \
    || fail 'sync-pins did not add the scanner digest'
grep -Eq '^BUILDKIT_IMAGE=.*@sha256:[0-9a-f]{64}$' "$sync_env" \
    || fail 'sync-pins did not add the BuildKit digest'
[[ "$(stat -c '%a' "$sync_env")" == '600' ]] \
    || fail 'sync-pins did not restrict the environment file mode'
sync_backup="$(find "$config_fixture" -maxdepth 1 -name 'sync.env.pre-sync-*' -print -quit)"
[[ -n "$sync_backup" && "$(stat -c '%a' "$sync_backup")" == '600' ]] \
    || fail 'sync-pins did not create a private rollback copy'
pass 'safe release pin synchronization'

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose --env-file env.example \
        -f docker-compose.yml \
        -f docker-compose.tor-check.override.yml \
        config >/dev/null
    pass 'Docker Compose configuration'
else
    printf 'SKIP: Docker Compose is not available\n'
fi
rm -rf "$config_fixture"
trap - EXIT

./run.sh help >/dev/null
./run.sh version | grep -Fq "$version"
issues_output="$(./run.sh issues)"
help_output="$(./run.sh help)"
grep -Fq 'HG-001' <<<"$issues_output"
grep -Fq 'doctor --strict' <<<"$help_output"
grep -Fq 'sync-pins' <<<"$help_output"
grep -Fq 'config migrate' <<<"$help_output"
grep -Fq 'migrate-users' <<<"$help_output"
grep -Fq 'legacy-state' <<<"$help_output"
grep -Fq 'evidence' <<<"$help_output"
pass 'Docker-free help and version commands'

legacy_fixture="$(mktemp -d)"
trap 'rm -rf "$legacy_fixture"' EXIT
mkdir -p \
    "$legacy_fixture/data/soft-serve/ssh" \
    "$legacy_fixture/data/tor/hidden_service" \
    "$legacy_fixture/soft-serve-data/ssh" \
    "$legacy_fixture/tor-data/hidden_service"
printf 'current database\n' > "$legacy_fixture/data/soft-serve/soft-serve.db"
printf 'legacy database\n' > "$legacy_fixture/soft-serve-data/soft-serve.db"
printf 'same host identity\n' > "$legacy_fixture/data/soft-serve/ssh/soft_serve_host_ed25519"
cp "$legacy_fixture/data/soft-serve/ssh/soft_serve_host_ed25519" \
    "$legacy_fixture/soft-serve-data/ssh/soft_serve_host_ed25519"
printf 'current onion identity\n' > "$legacy_fixture/data/tor/hidden_service/hs_ed25519_secret_key"
printf 'legacy onion identity\n' > "$legacy_fixture/tor-data/hidden_service/hs_ed25519_secret_key"
legacy_output="$(./scripts/legacy-state.sh "$legacy_fixture")"
grep -Eq '^database[[:space:]]+different$' <<<"$legacy_output"
grep -Eq '^ssh-host-identity[[:space:]]+same$' <<<"$legacy_output"
grep -Eq '^onion-identity[[:space:]]+different$' <<<"$legacy_output"
if grep -Fq 'current onion identity' <<<"$legacy_output"; then
    fail 'legacy-state leaked secret content'
fi
rm -rf "$legacy_fixture"
trap - EXIT
pass 'secret-safe legacy state comparison'

PYTHONPYCACHEPREFIX=/tmp/hidden-git-pycache python3 -m py_compile \
    scripts/extract-oci-provenance.py scripts/vulnerability-policy.py
pass 'release evidence Python syntax'

if grep -RhoE 'uses:[[:space:]]+[^[:space:]]+@(v[0-9]+|main|master|latest)' \
    .github/workflows | grep -q .; then
    fail 'GitHub Actions contain mutable action references'
fi
pass 'immutable GitHub Action references'

[[ -f .github/workflows/ci.yml ]] || fail 'CI workflow is missing'
[[ -f .github/workflows/pages.yml ]] || fail 'release Pages workflow is missing'
[[ ! -e docs/CNAME ]] || fail 'custom-workflow Pages site should not carry an unnecessary CNAME file'
grep -Fq 'release:' .github/workflows/pages.yml \
    || fail 'Pages workflow is not release-triggered'
grep -Fq 'actions/deploy-pages' .github/workflows/pages.yml \
    || fail 'Pages workflow does not deploy through the supported Pages action'
[[ -f .github/dependabot.yml ]] || fail 'Dependabot configuration is missing'
[[ -x tests/rootless-docker.sh ]] || fail 'rootless Docker integration test is missing or not executable'
grep -Fq 'rootless-docker' .github/workflows/ci.yml \
    || fail 'CI does not run the rootless Docker integration test'
pass 'repository automation manifests'

printf 'All static release checks passed.\n'

