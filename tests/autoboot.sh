#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
FIXTURE="$TMP_DIR/repo"
FAKE_BIN="$TMP_DIR/bin"
FAKE_STATE="$TMP_DIR/state"
SYSTEMD_DIR="$TMP_DIR/systemd-user"

cleanup() {
    chmod -R u+w "$TMP_DIR" 2>/dev/null || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$FIXTURE" "$FAKE_BIN" "$FAKE_STATE"
tar \
    --exclude=.git \
    --exclude=.ws-bridge \
    --exclude=.env \
    --exclude='.env.*' \
    --exclude=data \
    --exclude=backups \
    --exclude=retired-state \
    --exclude=release-evidence \
    --exclude=soft-serve-data \
    --exclude=tor-data \
    -C "$ROOT_DIR" -cf - . | tar -C "$FIXTURE" -xf -
cp "$FIXTURE/env.example" "$FIXTURE/.env"
chmod 600 "$FIXTURE/.env"

cat > "$FAKE_BIN/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_STATE_DIR:?}"
printf 'docker %s\n' "$*" >> "$FAKE_STATE_DIR/docker.log"
if [[ "${FAKE_DOCKER_DOWN:-0}" == 1 ]]; then
    exit 1
fi
if [[ "${1:-}" == compose && "${2:-}" == version ]]; then
    printf 'Docker Compose version v2.fake\n'
    exit 0
fi
if [[ "${1:-}" == context && "${2:-}" == show ]]; then
    printf '%s\n' "${FAKE_DOCKER_CONTEXT:-fixture-context}"
    exit 0
fi
if [[ "${1:-}" == compose ]]; then
    shift
    args=" $* "
    if [[ "$args" == *' config '* || "$args" == *' config ' ]]; then
        exit 0
    fi
    if [[ "$args" == *' ps --status running --services '* ]]; then
        cat "$FAKE_STATE_DIR/services" 2>/dev/null || true
        exit 0
    fi
    if [[ "$args" == *' ps -q tor '* ]]; then
        if grep -Fxq tor "$FAKE_STATE_DIR/services" 2>/dev/null; then
            printf 'fake-tor-id\n'
        fi
        exit 0
    fi
    if [[ "$args" == *' exec -T tor '* ]]; then
        if [[ "$args" == *'cat /var/lib/tor/hidden_service/hostname'* ]]; then
            printf 'fixture-hidden-service.onion\n'
            exit 0
        fi
        if [[ "$args" == *"grep -c '^HiddenServicePort ' /run/hidden-git/torrc"* ]]; then
            if [[ "${FAKE_TOR_TOPOLOGY:-current}" == stale ]]; then
                printf '1\n'
            else
                printf '2\n'
            fi
            exit 0
        fi
        if [[ "$args" == *'grep -Fxq HiddenServicePort 2022 soft-serve:23231 /run/hidden-git/torrc'* ]]; then
            [[ "${FAKE_TOR_TOPOLOGY:-current}" != stale ]]
            exit
        fi
        if [[ "$args" == *'grep -Fxq HiddenServicePort 8002 soft-serve:23231 /run/hidden-git/torrc'* ]]; then
            exit 0
        fi
    fi
    if [[ "$args" == *' up -d --no-build --wait '* ]]; then
        printf 'soft-serve\ntor\n' > "$FAKE_STATE_DIR/services"
        exit 0
    fi
fi
printf 'unexpected fake docker invocation: %s\n' "$*" >&2
exit 2
SH
chmod +x "$FAKE_BIN/docker"

cat > "$FAKE_BIN/loginctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${FAKE_LINGER:-yes}"
SH
chmod +x "$FAKE_BIN/loginctl"

cat > "$FAKE_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${FAKE_STATE_DIR:?}"
printf 'systemctl %s\n' "$*" >> "$FAKE_STATE_DIR/systemctl.log"
case " $* " in
    *' is-enabled '*) printf 'enabled\n' ;;
    *' is-active '*) printf 'active\n' ;;
esac
exit 0
SH
chmod +x "$FAKE_BIN/systemctl"

export PATH="$FAKE_BIN:$PATH"
export FAKE_STATE_DIR="$FAKE_STATE"
export HIDDEN_GIT_SYSTEMD_USER_DIR="$SYSTEMD_DIR"

printf 'soft-serve\ntor\n' > "$FAKE_STATE/services"

# Invalid config fails before systemd state is touched.
cp "$FIXTURE/.env" "$TMP_DIR/good.env"
printf 'TYPO_BOOT_KEY=1\n' >> "$FIXTURE/.env"
if (cd "$FIXTURE" && ./run.sh autoboot install >/dev/null 2>&1); then
    printf '%s\n' 'autoboot install accepted invalid config' >&2
    exit 1
fi
[[ ! -e "$SYSTEMD_DIR/hidden-git-autoboot.service" ]]
[[ ! -e "$FAKE_STATE/systemctl.log" ]]
cp "$TMP_DIR/good.env" "$FIXTURE/.env"
chmod 600 "$FIXTURE/.env"

# Host-boot authority requires a lingering user manager before any unit write.
export FAKE_LINGER=no
if (cd "$FIXTURE" && ./run.sh autoboot install >/dev/null 2>&1); then
    printf '%s\n' 'autoboot install accepted a non-lingering user manager' >&2
    exit 1
fi
[[ ! -e "$SYSTEMD_DIR/hidden-git-autoboot.service" ]]
export FAKE_LINGER=yes

# A one-off DOCKER_HOST is not a durable boot authority. Installation requires
# a named Docker context that the systemd user service can persist explicitly.
export DOCKER_HOST='tcp://127.0.0.1:65535'
rm -f "$FAKE_STATE/systemctl.log"
if (cd "$FIXTURE" && ./run.sh autoboot install >/dev/null 2>&1); then
    printf '%s\n' 'autoboot install accepted an ad-hoc DOCKER_HOST' >&2
    exit 1
fi
[[ ! -e "$SYSTEMD_DIR/hidden-git-autoboot.service" ]]
[[ ! -e "$FAKE_STATE/systemctl.log" ]]
unset DOCKER_HOST

# A running stack from an older source revision cannot authorize boot recovery.
# The installer must first observe the current mandatory 2022 Tor topology.
export FAKE_TOR_TOPOLOGY=stale
rm -f "$FAKE_STATE/systemctl.log"
if (cd "$FIXTURE" && ./run.sh autoboot install >/dev/null 2>&1); then
    printf '%s\n' 'autoboot install accepted a stale running Tor topology' >&2
    exit 1
fi
[[ ! -e "$SYSTEMD_DIR/hidden-git-autoboot.service" ]]
[[ ! -e "$FAKE_STATE/systemctl.log" ]]
unset FAKE_TOR_TOPOLOGY

# Existing unit names are ownership boundaries. Install refuses to overwrite a
# foreign/custom unit before invoking systemctl or changing its bytes.
mkdir -p "$SYSTEMD_DIR"
printf '%s\n' '# foreign unit' > "$SYSTEMD_DIR/hidden-git-autoboot.service"
foreign_hash="$(sha256sum "$SYSTEMD_DIR/hidden-git-autoboot.service" | awk '{print $1}')"
rm -f "$FAKE_STATE/systemctl.log"
if (cd "$FIXTURE" && ./run.sh autoboot install >/dev/null 2>&1); then
    printf '%s\n' 'autoboot install overwrote a conflicting existing unit' >&2
    exit 1
fi
[[ "$foreign_hash" == "$(sha256sum "$SYSTEMD_DIR/hidden-git-autoboot.service" | awk '{print $1}')" ]]
[[ ! -e "$FAKE_STATE/systemctl.log" ]]
rm -f "$SYSTEMD_DIR/hidden-git-autoboot.service"

# Install is deterministic and idempotent.
(cd "$FIXTURE" && ./run.sh autoboot install >/dev/null)
service_hash="$(sha256sum "$SYSTEMD_DIR/hidden-git-autoboot.service" | awk '{print $1}')"
timer_hash="$(sha256sum "$SYSTEMD_DIR/hidden-git-autoboot.timer" | awk '{print $1}')"
grep -Fq "WorkingDirectory=$FIXTURE" "$SYSTEMD_DIR/hidden-git-autoboot.service"
grep -Fxq 'Environment=DOCKER_CONTEXT=fixture-context' "$SYSTEMD_DIR/hidden-git-autoboot.service"
grep -Fq "ExecStart=$FIXTURE/run.sh autoboot reconcile" "$SYSTEMD_DIR/hidden-git-autoboot.service"
grep -Fxq '# Managed by HiddenGit autoboot' "$SYSTEMD_DIR/hidden-git-autoboot.service"
grep -Fxq '# Managed by HiddenGit autoboot' "$SYSTEMD_DIR/hidden-git-autoboot.timer"
grep -Fxq 'OnBootSec=45s' "$SYSTEMD_DIR/hidden-git-autoboot.timer"
grep -Fxq 'OnUnitActiveSec=5min' "$SYSTEMD_DIR/hidden-git-autoboot.timer"
if grep -Fq 'OnUnitInactiveSec=' "$SYSTEMD_DIR/hidden-git-autoboot.timer"; then
    printf '%s\n' 'autoboot timer still depends on service deactivation instead of activation-based retry' >&2
    exit 1
fi
if grep -Fq 'Persistent=' "$SYSTEMD_DIR/hidden-git-autoboot.timer"; then
    printf '%s\n' 'autoboot timer carries ineffective Persistent= policy without an OnCalendar timer' >&2
    exit 1
fi
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify \
        "$SYSTEMD_DIR/hidden-git-autoboot.service" \
        "$SYSTEMD_DIR/hidden-git-autoboot.timer" >/dev/null
fi
(cd "$FIXTURE" && ./run.sh autoboot install >/dev/null)
[[ "$service_hash" == "$(sha256sum "$SYSTEMD_DIR/hidden-git-autoboot.service" | awk '{print $1}')" ]]
[[ "$timer_hash" == "$(sha256sum "$SYSTEMD_DIR/hidden-git-autoboot.timer" | awk '{print $1}')" ]]

# Healthy reconciliation is a no-op: no Compose up occurs.
: > "$FAKE_STATE/docker.log"
(cd "$FIXTURE" && ./run.sh autoboot reconcile >/dev/null)
if grep -Fq 'up -d --no-build --wait' "$FAKE_STATE/docker.log"; then
    printf '%s\n' 'healthy autoboot reconciliation mutated the stack' >&2
    exit 1
fi

# Prior explicit stop/down is recovered from existing local images.
: > "$FAKE_STATE/services"
: > "$FAKE_STATE/docker.log"
(cd "$FIXTURE" && ./run.sh autoboot reconcile >/dev/null)
grep -Fxq soft-serve "$FAKE_STATE/services"
grep -Fxq tor "$FAKE_STATE/services"
grep -Fq 'up -d --no-build --wait' "$FAKE_STATE/docker.log"

# A Docker-daemon outage fails without fabricating service state; the next timer
# attempt after daemon recovery repairs the stack.
: > "$FAKE_STATE/services"
export FAKE_DOCKER_DOWN=1
if (cd "$FIXTURE" && ./run.sh autoboot reconcile >/dev/null 2>&1); then
    printf '%s\n' 'autoboot reconciliation succeeded while Docker was unavailable' >&2
    exit 1
fi
[[ ! -s "$FAKE_STATE/services" ]]
unset FAKE_DOCKER_DOWN
(cd "$FIXTURE" && ./run.sh autoboot reconcile >/dev/null)
grep -Fxq soft-serve "$FAKE_STATE/services"
grep -Fxq tor "$FAKE_STATE/services"

# Status is read-only and removal is idempotent; removing autoboot never stops
# the deployment itself.
status_output="$(cd "$FIXTURE" && ./run.sh autoboot status)"
grep -Fq 'Autoboot timer enabled: enabled' <<<"$status_output"
grep -Fq 'Managed units current:  yes' <<<"$status_output"
grep -Fq 'Recorded Docker context: fixture-context' <<<"$status_output"
grep -Fq 'Current Docker context:  fixture-context' <<<"$status_output"
grep -Fq 'Docker context match:    yes' <<<"$status_output"

# Changing the interactive Docker context does not silently retarget the
# installed boot authority. Status exposes the drift so the operator can
# qualify the intended context and explicitly reinstall the managed unit.
export FAKE_DOCKER_CONTEXT=other-context
status_output="$(cd "$FIXTURE" && ./run.sh autoboot status)"
grep -Fq 'Recorded Docker context: fixture-context' <<<"$status_output"
grep -Fq 'Current Docker context:  other-context' <<<"$status_output"
grep -Fq 'Docker context match:    no' <<<"$status_output"
unset FAKE_DOCKER_CONTEXT

(cd "$FIXTURE" && ./run.sh autoboot remove >/dev/null)
[[ ! -e "$SYSTEMD_DIR/hidden-git-autoboot.service" ]]
[[ ! -e "$SYSTEMD_DIR/hidden-git-autoboot.timer" ]]
(cd "$FIXTURE" && ./run.sh autoboot remove >/dev/null)

printf 'PASS: autoboot install/status/remove and boot/Docker/explicit-stop reconciliation are idempotent and fail closed\n'
