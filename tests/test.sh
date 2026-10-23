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
if grep -Eq '^HIDDEN_GIT_VERSION=' env.example config/release.env; then
    fail 'VERSION must remain the sole HiddenGit project-version authority'
fi
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

python3 scripts/configctl.py release check >/dev/null
for key in ALPINE_IMAGE GO_IMAGE TRIVY_IMAGE BUILDKIT_IMAGE DIND_ROOTLESS_IMAGE; do
    value="$(python3 scripts/configctl.py release get "$key")"
    [[ "$value" =~ @sha256:[0-9a-f]{64}$ ]] \
        || fail "$key is not digest-pinned in config/release.env"
done
[[ "$(python3 scripts/configctl.py release get SOFT_SERVE_VERSION)" == 'v0.12.3' ]] \
    || fail 'Soft Serve release pin changed from reviewed v0.12.3'
[[ "$(python3 scripts/configctl.py release get SOFT_SERVE_NET_SECURITY_VERSION)" == 'v0.60.0' ]] \
    || fail 'the reviewed x/net security uplift must remain pinned to v0.60.0'
[[ "$(python3 scripts/configctl.py release get ONION_SSH_PORT)" == '2022' ]] \
    || fail 'release-managed onion SSH port must remain 2022'
for forbidden_key in SOFT_SERVE_WISH_VERSION SOFT_SERVE_GO_GIT_VERSION \
    SOFT_SERVE_GO_JOSE_VERSION SOFT_SERVE_X_CRYPTO_VERSION SOFT_SERVE_X_NET_VERSION; do
    if grep -R -Fq "$forbidden_key" config/schema.json env.example docker-compose.yml \
        Dockerfile.soft-serve scripts/release-evidence.sh; then
        fail "$forbidden_key remains in the v2 schema/template/build/evidence surface"
    fi
done
if grep -Eq '^[[:space:]]*go get([[:space:]\\]|$)' Dockerfile.soft-serve; then
    fail 'Soft Serve Dockerfile still mutates the reviewed upstream dependency graph'
fi
grep -Fq 'go mod verify' Dockerfile.soft-serve \
    || fail 'Soft Serve build no longer verifies the upstream module graph'
grep -Fq "go mod edit -require=golang.org/x/net@\${SOFT_SERVE_NET_SECURITY_VERSION}" Dockerfile.soft-serve \
    || fail 'Soft Serve security uplift is not source-owned by release metadata'
grep -Eq 'apk add --no-cache .*bash([[:space:]]|&&|$)' Dockerfile.soft-serve \
    || fail 'Soft Serve runtime image must include bash for generated Git hooks'
for dockerfile in Dockerfile.soft-serve Dockerfile.tor Dockerfile.tor-check Dockerfile.maintenance; do
    if grep -Eq '^ARG (ALPINE_IMAGE|GO_IMAGE)=.+sha256:' "$dockerfile"; then
        fail "$dockerfile duplicates tracked release pins instead of requiring config/release.env build args"
    fi
    grep -Fq 'apk upgrade --no-cache' "$dockerfile" \
        || fail "$dockerfile does not apply current Alpine security package upgrades"
done
pass 'tracked release metadata and upstream module graph ownership'

for forbidden in '.env' '.envBackup' 'data/' 'soft-serve-data/' 'tor-data/' 'trunk/'; do
    if git ls-files | grep -Eq "^${forbidden//./\.}"; then
        fail "runtime or secret path is tracked: $forbidden"
    fi
done
pass 'tracked-secret hygiene'

grep -Fq 'LOCAL_SSH_PORT:-23231}:23231' docker-compose.yml \
    || fail 'Compose local SSH publication is not decoupled from fixed internal 23231'
grep -Fq 'HOST_BIND_ADDRESS:-127.0.0.1' docker-compose.yml \
    || fail 'Compose local SSH publication is not loopback-safe by default'
if grep -Eq 'SOFT_SERVE_(SSH|HTTP|STATS|GIT)_PORT|ONION_TARGET_PORT|SOFT_SERVE_DATA_PATH|[[:space:]]CI:' docker-compose.yml; then
    fail 'Compose still exposes retired internal topology variables'
fi
grep -Fq 'nc -w 3 127.0.0.1 23231' scripts/soft-serve-healthcheck.sh \
    || fail 'Soft Serve healthcheck does not target fixed internal SSH 23231'
grep -Fq "HiddenServicePort \${ONION_SSH_PORT} soft-serve:23231" soft-serve-hidden-service.torrc.template \
    || fail 'mandatory onion SSH 2022 mapping is absent from the Tor template'
grep -Fq "\${ONION_COMPAT_HIDDEN_SERVICE_PORT}" soft-serve-hidden-service.torrc.template \
    || fail 'Tor template cannot render the backward-compatible onion port'
grep -Fq "if [ \"\$ONION_PUBLIC_PORT\" != \"\$ONION_SSH_PORT\" ]; then" scripts/tor-entrypoint.sh \
    || fail 'Tor entrypoint does not de-duplicate coincident virtual ports'
grep -Fq 'managed Tor virtual-port topology is missing, duplicated, or inconsistent' scripts/tor-entrypoint.sh \
    || fail 'Tor entrypoint lacks fail-closed exact virtual-port validation'
grep -A2 '^stats:' soft-serve.config.yaml.template | grep -Fq 'enabled: false' \
    || fail 'Soft Serve stats are not disabled'
grep -Fq 'listen_addr: "127.0.0.1:23233"' soft-serve.config.yaml.template \
    || fail 'inert Soft Serve stats listen address is not deterministic loopback'
grep -A2 '^git:' soft-serve.config.yaml.template | grep -Fq 'enabled: false' \
    || fail 'native git daemon is not disabled by default'
grep -A2 '^http:' soft-serve.config.yaml.template | grep -Fq 'enabled: false' \
    || fail 'HTTP server is not disabled by default'
grep -A2 '^lfs:' soft-serve.config.yaml.template | grep -Fq 'enabled: false' \
    || fail 'Git LFS is not disabled in the SSH-only default profile'
grep -Fq 'ssh_enabled: false' soft-serve.config.yaml.template \
    || fail 'Git LFS over SSH is not disabled'
grep -Fq '/run/hidden-git/soft-serve.config.yaml' scripts/soft-serve-entrypoint.sh \
    || fail 'entrypoint does not select managed runtime config'
grep -Fq 'yaml_single_quote_escape' scripts/soft-serve-entrypoint.sh \
    || fail 'entrypoint does not YAML-escape operator presentation values'
grep -Fq "name: '\${SOFT_SERVE_NAME_YAML}'" soft-serve.config.yaml.template \
    || fail 'Soft Serve name is not rendered as an escaped YAML scalar'
grep -Fq "public_url: '\${SOFT_SERVE_SSH_PUBLIC_URL_YAML}'" soft-serve.config.yaml.template \
    || fail 'Soft Serve public SSH URL is not rendered as an escaped YAML scalar'
grep -Fq "if [ -e \"\$SOFT_SERVE_DATA_PATH/soft-serve.db\" ]; then" scripts/soft-serve-entrypoint.sh \
    || fail 'bootstrap suppression does not treat every existing DB path as established state'
grep -Fq 'unset SOFT_SERVE_INITIAL_ADMIN_KEYS' scripts/soft-serve-entrypoint.sh \
    || fail 'existing DB does not suppress stale bootstrap admin keys'
pass 'minimal fixed internal network and bootstrap topology'

for protected in '.env' 'data' 'soft-serve-data' 'tor-data' 'trunk'; do
    grep -Fxq "$protected" .dockerignore \
        || fail ".dockerignore does not protect: $protected"
done
grep -Fxq 'backups/' .gitignore || fail 'encrypted backups are not ignored by Git'
grep -Fxq 'backups' .dockerignore || fail 'encrypted backups enter the Docker build context'
grep -Fxq 'release-evidence' .dockerignore || fail 'release evidence enters the Docker build context'
pass 'build-context and backup secret hygiene'

grep -Fq 'timeout --signal=TERM' scripts/tor-check.sh \
    || fail 'containerized SSH attempts lack a hard timeout'
grep -Fq 'authenticated_check' scripts/tor-check.sh \
    || fail 'containerized SSH checker does not distinguish authenticated qualification from reachability'
grep -Fq 'accepting "Permission denied" would false-pass' scripts/tor-check.sh \
    || fail 'authenticated onion qualification regression guard is missing'
grep -Fq 'timeout --signal=TERM' run.sh \
    || fail 'host-side SSH attempts lack a hard timeout'
pass 'bounded SSH attempts'

if grep -Eq 'read_env_value|sync_env_key_from_example|set_env_value' run.sh scripts/operator-ui.sh scripts/release-evidence.sh; then
    fail 'an independent first-match deployment config parser remains in a consumer path'
fi
if grep -Eq 'HIDDEN_GIT_ENV_FILE|ENV_FILE' scripts/release-evidence.sh; then
    fail 'direct release evidence still reads operator deployment configuration'
fi
if grep -Eq 'BACKUP_IDENTITY_FILE' env.example run.sh scripts/operator-ui.sh; then
    fail 'recovery identity path is still part of current declarative configuration or command fallback paths'
fi
fixed_tmp="$(printf '/%s/' tmp)"
if grep -R -E "mktemp[^[:cntrl:]]*${fixed_tmp}|PYTHONPYCACHEPREFIX=${fixed_tmp}" tests >/dev/null; then
    fail 'test qualification still contains a fixed bare scratch path under the global temporary directory'
fi
pass 'single parser boundary and no fixed test scratch paths'

config_fixture="$(mktemp -d)"
trap 'rm -rf "$config_fixture"' EXIT

configctl() {
    local env_file="$1"
    shift
    python3 scripts/configctl.py --env "$env_file" --schema config/schema.json \
        --template env.example --release-file config/release.env "$@"
}

plan_state() {
    configctl "$1" migrate --json "${@:2}" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])'
}

write_legacy_default() {
    local path="$1"
    cat > "$path" <<'EOF'
HIDDEN_GIT_VERSION=0.0.2
SOFT_SERVE_SSH_PORT=23231
SOFT_SERVE_HTTP_PORT=23232
SOFT_SERVE_STATS_PORT=23233
SOFT_SERVE_GIT_PORT=9418
ONION_TARGET_PORT=23231
SOFT_SERVE_DATA_PATH=/var/lib/soft-serve
CI=1
SOFT_SERVE_HTTP_PUBLIC_URL=http://localhost:23232
SOFT_SERVE_GIT_PUBLIC_URL=git://localhost:9418
SOFT_SERVE_SSH_PUBLIC_URL=ssh://localhost:23231
EOF
    chmod 600 "$path"
}

# 1. current v2 canonical -> no-op
cp env.example "$config_fixture/current-v2.env"
chmod 600 "$config_fixture/current-v2.env"
[[ "$(plan_state "$config_fixture/current-v2.env")" == CURRENT ]]
current_hash="$(sha256sum "$config_fixture/current-v2.env" | awk '{print $1}')"
configctl "$config_fixture/current-v2.env" migrate --apply \
    | grep -Fq 'No changes applied; no rollback copy created'
[[ "$current_hash" == "$(sha256sum "$config_fixture/current-v2.env" | awk '{print $1}')" ]] \
    || fail 'current v2 no-op changed bytes'
[[ "$(find "$config_fixture" -name 'current-v2.env.pre-config-*' | wc -l)" == 0 ]]

# 1b. current v2 with only an unsafe mode -> repair permissions in place.
# Bytes already are their own rollback, so no rollback artifact is warranted.
cp env.example "$config_fixture/mode-only.env"
chmod 0644 "$config_fixture/mode-only.env"
mode_only_hash="$(sha256sum "$config_fixture/mode-only.env" | awk '{print $1}')"
configctl "$config_fixture/mode-only.env" migrate --apply --json \
    > "$config_fixture/mode-only-plan.json"
[[ "$mode_only_hash" == "$(sha256sum "$config_fixture/mode-only.env" | awk '{print $1}')" ]] \
    || fail 'mode-only migration changed canonical bytes'
[[ "$(stat -c '%a' "$config_fixture/mode-only.env")" == 600 ]] \
    || fail 'mode-only migration did not restrict permissions to 0600'
[[ "$(find "$config_fixture" -name 'mode-only.env.pre-config-*' | wc -l)" == 0 ]] \
    || fail 'mode-only migration created an unnecessary rollback copy'
python3 - "$config_fixture/mode-only-plan.json" <<'PY'
import json
from pathlib import Path
import sys

plan = json.loads(Path(sys.argv[1]).read_text())
assert plan["state"] == "CURRENT"
assert plan["content_changed"] is False
assert plan["mode_changed"] is True
assert plan["applied"] is True
assert plan["backup"] is None
PY

# 1c. Compose and configctl must not assign different semantics to accepted v2 text.
cp env.example "$config_fixture/quoted-current.env"
python3 - "$config_fixture/quoted-current.env" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
lines = []
for line in path.read_text().splitlines():
    if line.startswith("SOFT_SERVE_NAME="):
        line = 'SOFT_SERVE_NAME="Forge \\"quoted\\" # equals=kept"'
    lines.append(line)
path.write_text("\n".join(lines) + "\n")
path.chmod(0o600)
PY
configctl "$config_fixture/quoted-current.env" check >/dev/null

cp env.example "$config_fixture/compose-dollar.env"
python3 - "$config_fixture/compose-dollar.env" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text().replace("SOFT_SERVE_NAME=HiddenGit", 'SOFT_SERVE_NAME="Forge $HOME"')
path.write_text(text)
path.chmod(0o600)
PY
if configctl "$config_fixture/compose-dollar.env" check >/dev/null 2>&1; then
    fail 'Compose-interpolated dollar reference passed canonical config validation'
fi

cp env.example "$config_fixture/compose-control-escape.env"
python3 - "$config_fixture/compose-control-escape.env" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text().replace("SOFT_SERVE_NAME=HiddenGit", r'SOFT_SERVE_NAME="Forge\nLine2"')
path.write_text(text)
path.chmod(0o600)
PY
if configctl "$config_fixture/compose-control-escape.env" check >/dev/null 2>&1; then
    fail 'Compose control escape passed canonical config validation'
fi

cp env.example "$config_fixture/malformed-public-url.env"
python3 - "$config_fixture/malformed-public-url.env" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text().replace(
    "SOFT_SERVE_SSH_PUBLIC_URL=",
    r'SOFT_SERVE_SSH_PUBLIC_URL="ssh://public.example.invalid:2200/path\\"quoted"',
)
path.write_text(text)
path.chmod(0o600)
PY
if configctl "$config_fixture/malformed-public-url.env" check >/dev/null 2>&1; then
    fail 'malformed SSH public URL containing a quote passed validation'
fi

# 2. current v1 -> v2 ownership migration; also proves release overrides are historical-only.
cat > "$config_fixture/v1.env" <<'EOF'
HIDDEN_GIT_CONFIG_VERSION=1
HIDDEN_GIT_VERSION=0.1.3
ALPINE_IMAGE=alpine:old
GO_IMAGE=golang:old
SOFT_SERVE_VERSION=v0.12.2
SOFT_SERVE_WISH_VERSION=v2.0.3
SOFT_SERVE_GO_GIT_VERSION=v5.19.2
SOFT_SERVE_GO_JOSE_VERSION=v3.0.5
SOFT_SERVE_X_CRYPTO_VERSION=v0.54.0
SOFT_SERVE_X_NET_VERSION=v0.57.0
TRIVY_IMAGE=trivy:old
BUILDKIT_IMAGE=buildkit:old
DIND_ROOTLESS_IMAGE=dind:old
SOFT_SERVE_NAME=HiddenGit
SOFT_SERVE_INITIAL_ADMIN_KEYS=
ONION_PUBLIC_PORT=8002
LOCAL_SSH_PORT=40222
HOST_BIND_ADDRESS=127.0.0.1
SOFT_SERVE_SSH_PUBLIC_URL=ssh://git.example.invalid:2200
SOFT_SERVE_SSH_USER=admin
CHECK_TIMEOUT_SECONDS=180
BACKUP_RECIPIENT=
BACKUP_IDENTITY_FILE=/secret/not-read/recovery.agekey
EOF
chmod 600 "$config_fixture/v1.env"
[[ "$(plan_state "$config_fixture/v1.env")" == MIGRATABLE ]]
preview="$(configctl "$config_fixture/v1.env" migrate)"
if grep -Eq '/secret/not-read|alpine:old' <<<"$preview"; then
    fail 'v1 migration preview leaked removed values'
fi
configctl "$config_fixture/v1.env" migrate --apply >/dev/null
grep -Fxq 'HIDDEN_GIT_CONFIG_VERSION=2' "$config_fixture/v1.env"
grep -Fxq 'LOCAL_SSH_PORT=40222' "$config_fixture/v1.env"
grep -Fxq 'SOFT_SERVE_SSH_PUBLIC_URL=ssh://git.example.invalid:2200' "$config_fixture/v1.env"
if grep -Eq '^(ALPINE_IMAGE|SOFT_SERVE_WISH_VERSION|BACKUP_IDENTITY_FILE)=' "$config_fixture/v1.env"; then
    fail 'v1 release/recovery ownership keys survived migration'
fi

# 3. pre-v0.0.2 default
write_legacy_default "$config_fixture/pre-v002.env"
sed -i '/^HIDDEN_GIT_VERSION=/d' "$config_fixture/pre-v002.env"
[[ "$(plan_state "$config_fixture/pre-v002.env")" == MIGRATABLE ]]
configctl "$config_fixture/pre-v002.env" migrate --apply >/dev/null
configctl "$config_fixture/pre-v002.env" check >/dev/null

# 4. v0.0.2 default
write_legacy_default "$config_fixture/v002.env"
[[ "$(plan_state "$config_fixture/v002.env")" == MIGRATABLE ]]
configctl "$config_fixture/v002.env" migrate --apply >/dev/null
configctl "$config_fixture/v002.env" check >/dev/null

# 5. v0.0.3 custom SSH + matching Tor target
write_legacy_default "$config_fixture/v003-custom.env"
sed -i -e 's/^HIDDEN_GIT_VERSION=.*/HIDDEN_GIT_VERSION=0.0.3/' \
    -e 's/^SOFT_SERVE_SSH_PORT=.*/SOFT_SERVE_SSH_PORT=40123/' \
    -e 's/^ONION_TARGET_PORT=.*/ONION_TARGET_PORT=40123/' \
    "$config_fixture/v003-custom.env"
configctl "$config_fixture/v003-custom.env" migrate --apply >/dev/null
grep -Fxq 'LOCAL_SSH_PORT=40123' "$config_fixture/v003-custom.env" \
    || fail 'custom legacy SSH did not become host-only LOCAL_SSH_PORT'

# 6. mismatched old SSH/Tor target -> fail closed
write_legacy_default "$config_fixture/mismatch.env"
sed -i -e 's/^SOFT_SERVE_SSH_PORT=.*/SOFT_SERVE_SSH_PORT=40123/' \
    -e 's/^ONION_TARGET_PORT=.*/ONION_TARGET_PORT=40124/' "$config_fixture/mismatch.env"
if configctl "$config_fixture/mismatch.env" migrate >/dev/null 2>&1; then
    fail 'mismatched legacy SSH/Tor target migrated'
fi

# 7. old+new SSH alias conflict -> fail closed, even if values happen to match.
write_legacy_default "$config_fixture/alias-conflict.env"
printf 'LOCAL_SSH_PORT=23231\n' >> "$config_fixture/alias-conflict.env"
if configctl "$config_fixture/alias-conflict.env" migrate >/dev/null 2>&1; then
    fail 'old+new SSH aliases were accepted together'
fi

assert_lossy() {
    local key="$1"
    local replacement="$2"
    local file="$config_fixture/lossy-${key}.env"
    write_legacy_default "$file"
    python3 - "$file" "$key" "$replacement" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1]); key=sys.argv[2]; value=sys.argv[3]
lines=path.read_text().splitlines()
for i,line in enumerate(lines):
    if line.startswith(key+'='):
        lines[i]=key+'='+value
        break
else:
    lines.append(key+'='+value)
path.write_text('\n'.join(lines)+'\n')
PY
    chmod 600 "$file"
    [[ "$(plan_state "$file")" == BLOCKED_LOSSY ]] \
        || fail "$key custom legacy topology was not BLOCKED_LOSSY"
    local before_hash before_count preview_output
    before_hash="$(sha256sum "$file" | awk '{print $1}')"
    before_count="$(find "$config_fixture" -maxdepth 1 -name "$(basename "$file").pre-config-*" | wc -l)"
    if configctl "$file" migrate --apply >/dev/null 2>&1; then
        fail "$key lossy migration applied without acknowledgement"
    fi
    [[ "$before_hash" == "$(sha256sum "$file" | awk '{print $1}')" ]] \
        || fail "$key blocked lossy migration wrote bytes"
    [[ "$before_count" == "$(find "$config_fixture" -maxdepth 1 -name "$(basename "$file").pre-config-*" | wc -l)" ]] \
        || fail "$key blocked lossy migration created rollback state"
    preview_output="$(configctl "$file" migrate)"
    grep -Fq "$key" <<<"$preview_output" || fail "$key absent from lossy preview"
    if grep -Fq "$replacement" <<<"$preview_output"; then
        fail "$key lossy preview exposed the retired value"
    fi
    [[ "$(plan_state "$file" --accept-retired-auxiliary-topology)" == MIGRATABLE_ACK ]]
    configctl "$file" migrate --apply --accept-retired-auxiliary-topology >/dev/null
    configctl "$file" check >/dev/null
    if grep -Eq "^${key}=" "$file"; then
        fail "$key survived acknowledged retirement"
    fi
}

# 8-12. custom retired auxiliary topology -> BLOCKED_LOSSY
assert_lossy SOFT_SERVE_HTTP_PORT 30232
assert_lossy SOFT_SERVE_STATS_PORT 30233
assert_lossy SOFT_SERVE_GIT_PORT 19418
assert_lossy SOFT_SERVE_HTTP_PUBLIC_URL https://legacy.example.invalid:30232
assert_lossy SOFT_SERVE_GIT_PUBLIC_URL git://legacy.example.invalid:19418

# 13. duplicate current key -> fail before mutation
cp env.example "$config_fixture/duplicate.env"
printf 'LOCAL_SSH_PORT=49999\n' >> "$config_fixture/duplicate.env"
chmod 600 "$config_fixture/duplicate.env"
duplicate_hash="$(sha256sum "$config_fixture/duplicate.env" | awk '{print $1}')"
if configctl "$config_fixture/duplicate.env" migrate --apply >/dev/null 2>&1; then
    fail 'duplicate current key was accepted'
fi
[[ "$duplicate_hash" == "$(sha256sum "$config_fixture/duplicate.env" | awk '{print $1}')" ]]
[[ "$(find "$config_fixture" -name 'duplicate.env.pre-config-*' | wc -l)" == 0 ]]

# 14. unknown/typo current key -> fail before mutation
cp env.example "$config_fixture/unknown.env"
printf 'LOCAL_SSH_P0RT=49999\n' >> "$config_fixture/unknown.env"
chmod 600 "$config_fixture/unknown.env"
unknown_hash="$(sha256sum "$config_fixture/unknown.env" | awk '{print $1}')"
if configctl "$config_fixture/unknown.env" migrate --apply >/dev/null 2>&1; then
    fail 'unknown current key was accepted'
fi
[[ "$unknown_hash" == "$(sha256sum "$config_fixture/unknown.env" | awk '{print $1}')" ]]
[[ "$(find "$config_fixture" -name 'unknown.env.pre-config-*' | wc -l)" == 0 ]]

# Operator .env cannot override tracked release metadata.
cp env.example "$config_fixture/release-override.env"
printf 'ALPINE_IMAGE=alpine:latest\n' >> "$config_fixture/release-override.env"
chmod 600 "$config_fixture/release-override.env"
if configctl "$config_fixture/release-override.env" check >/dev/null 2>&1; then
    fail 'operator config was allowed to override tracked release metadata'
fi

# 15. inline comments and quoted values parse safely, then canonicalize.
write_legacy_default "$config_fixture/quoted.env"
printf 'SOFT_SERVE_NAME="Legacy # forge"\nONION_PUBLIC_PORT=8002 # inline\n' >> "$config_fixture/quoted.env"
configctl "$config_fixture/quoted.env" migrate --apply >/dev/null
grep -Fxq 'SOFT_SERVE_NAME="Legacy # forge"' "$config_fixture/quoted.env"
grep -Fxq 'ONION_PUBLIC_PORT=8002' "$config_fixture/quoted.env"

# 16. custom LOCAL_SSH_PORT + unrelated explicit public SSH URL stay independent.
cat > "$config_fixture/independent-url.env" <<'EOF'
HIDDEN_GIT_CONFIG_VERSION=1
SOFT_SERVE_NAME=HiddenGit
SOFT_SERVE_INITIAL_ADMIN_KEYS=
ONION_PUBLIC_PORT=8002
LOCAL_SSH_PORT=40123
HOST_BIND_ADDRESS=127.0.0.1
SOFT_SERVE_SSH_PUBLIC_URL=ssh://metadata.example.invalid:2200
SOFT_SERVE_SSH_USER=admin
CHECK_TIMEOUT_SECONDS=180
BACKUP_RECIPIENT=
EOF
chmod 600 "$config_fixture/independent-url.env"
configctl "$config_fixture/independent-url.env" migrate --apply >/dev/null
grep -Fxq 'LOCAL_SSH_PORT=40123' "$config_fixture/independent-url.env"
grep -Fxq 'SOFT_SERVE_SSH_PUBLIC_URL=ssh://metadata.example.invalid:2200' "$config_fixture/independent-url.env"

# 17. first apply + identical second apply: exact bytes, one rollback only.
cat > "$config_fixture/twice.env" <<'EOF'
HIDDEN_GIT_CONFIG_VERSION=1
SOFT_SERVE_NAME=HiddenGit
SOFT_SERVE_INITIAL_ADMIN_KEYS=
ONION_PUBLIC_PORT=8122
LOCAL_SSH_PORT=40222
HOST_BIND_ADDRESS=127.0.0.1
SOFT_SERVE_SSH_PUBLIC_URL=
SOFT_SERVE_SSH_USER=admin
CHECK_TIMEOUT_SECONDS=180
BACKUP_RECIPIENT=
EOF
chmod 600 "$config_fixture/twice.env"
configctl "$config_fixture/twice.env" migrate --apply >/dev/null
first_apply_hash="$(sha256sum "$config_fixture/twice.env" | awk '{print $1}')"
first_backup_count="$(find "$config_fixture" -name 'twice.env.pre-config-*' | wc -l)"
[[ "$first_backup_count" == 1 ]] || fail 'first migration did not create exactly one rollback copy'
configctl "$config_fixture/twice.env" migrate --apply \
    | grep -Fq 'No changes applied; no rollback copy created'
[[ "$first_apply_hash" == "$(sha256sum "$config_fixture/twice.env" | awk '{print $1}')" ]] \
    || fail 'second migration apply changed canonical bytes'
[[ "$first_backup_count" == "$(find "$config_fixture" -name 'twice.env.pre-config-*' | wc -l)" ]] \
    || fail 'second migration apply created another rollback copy'

# 18. sentinel DB/repository/Tor files outside the config file remain byte-identical.
sentinel="$config_fixture/sentinel-runtime"
mkdir -p "$sentinel/data/soft-serve/repos/example.git" "$sentinel/data/tor/hidden_service"
printf 'db sentinel\n' > "$sentinel/data/soft-serve/soft-serve.db"
printf 'repo sentinel\n' > "$sentinel/data/soft-serve/repos/example.git/HEAD"
printf 'tor sentinel\n' > "$sentinel/data/tor/hidden_service/hs_ed25519_secret_key"
sentinel_before="$(find "$sentinel" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
cat > "$config_fixture/sentinel-migrate.env" <<'EOF'
HIDDEN_GIT_CONFIG_VERSION=1
SOFT_SERVE_NAME=HiddenGit
SOFT_SERVE_INITIAL_ADMIN_KEYS=
ONION_PUBLIC_PORT=8002
LOCAL_SSH_PORT=23231
HOST_BIND_ADDRESS=127.0.0.1
SOFT_SERVE_SSH_PUBLIC_URL=
SOFT_SERVE_SSH_USER=admin
CHECK_TIMEOUT_SECONDS=180
BACKUP_RECIPIENT=
EOF
chmod 600 "$config_fixture/sentinel-migrate.env"
configctl "$config_fixture/sentinel-migrate.env" migrate --apply >/dev/null
sentinel_after="$(find "$sentinel" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}')"
[[ "$sentinel_before" == "$sentinel_after" ]] \
    || fail 'configuration migration changed sentinel runtime-state bytes'
pass '23 representative schema-v2 migration fixtures'

# Release metadata itself gets duplicate/unknown rejection through the same parser.
cp config/release.env "$config_fixture/release-duplicate.env"
printf 'ALPINE_IMAGE=alpine:duplicate\n' >> "$config_fixture/release-duplicate.env"
if python3 scripts/configctl.py --release-file "$config_fixture/release-duplicate.env" release check >/dev/null 2>&1; then
    fail 'duplicate tracked release key was accepted'
fi
cp config/release.env "$config_fixture/release-unknown.env"
printf 'ALP1NE_IMAGE=typo\n' >> "$config_fixture/release-unknown.env"
if python3 scripts/configctl.py --release-file "$config_fixture/release-unknown.env" release check >/dev/null 2>&1; then
    fail 'unknown tracked release key was accepted'
fi
pass 'tracked release metadata parser rejection'

# sync-pins is compatibility-only and must never mutate operator configuration.
cp env.example "$config_fixture/sync.env"
chmod 600 "$config_fixture/sync.env"
sync_hash="$(sha256sum "$config_fixture/sync.env" | awk '{print $1}')"
HIDDEN_GIT_ENV_FILE="$config_fixture/sync.env" ./run.sh sync-pins >/dev/null
[[ "$sync_hash" == "$(sha256sum "$config_fixture/sync.env" | awk '{print $1}')" ]] \
    || fail 'sync-pins mutated the v2 operator config'
[[ "$(find "$config_fixture" -name 'sync.env.pre-*' | wc -l)" == 0 ]] \
    || fail 'sync-pins created an obsolete rollback copy'
pass 'non-mutating sync-pins compatibility behavior'

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    HIDDEN_GIT_ENV_FILE="$config_fixture/current-v2.env" ./run.sh config >/dev/null
    pass 'Docker Compose configuration through validated tracked release metadata'
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
grep -Fq 'accept-retired-auxiliary-topology' <<<"$help_output"
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

pycache_dir="$(mktemp -d)"
PYTHONPYCACHEPREFIX="$pycache_dir" python3 -m py_compile \
    scripts/configctl.py scripts/extract-oci-provenance.py scripts/vulnerability-policy.py
rm -rf "$pycache_dir"
pass 'release/config Python syntax'

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
[[ -x tests/autoboot.sh ]] || fail 'autoboot lifecycle test is missing or not executable'
grep -Fq 'rootless-docker' .github/workflows/ci.yml \
    || fail 'CI does not run the rootless Docker integration test'
pass 'repository automation manifests'

./tests/autoboot.sh
pass 'isolated autoboot lifecycle and reconciliation'

printf 'All static release checks passed.\n'
