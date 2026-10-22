#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
bash -n scripts/ensure-github-labels.sh
for label in dependencies docker ci; do
    grep -Fq -- "- $label" .github/dependabot.yml
    grep -Eq "^ensure_label $label " scripts/ensure-github-labels.sh
done
grep -Fq 'issues: write' .github/workflows/labels.yml

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/labels"
cat > "$tmp/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
    'api --silent')
        name="${3##*/}"
        test -f "$MOCK_LABEL_DIR/$name"
        ;;
    'label create')
        name="$3"
        if [[ -e "$MOCK_LABEL_DIR/$name" ]]; then
            echo "duplicate label creation: $name" >&2
            exit 1
        fi
        : > "$MOCK_LABEL_DIR/$name"
        printf '%s\n' "$name" >> "$MOCK_LABEL_DIR/created"
        ;;
    *) echo "unexpected gh command: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" MOCK_LABEL_DIR="$tmp/labels" GH_REPO=fkr-0/hidden-git

bash scripts/ensure-github-labels.sh >/dev/null
test "$(wc -l < "$tmp/labels/created")" -eq 3
bash scripts/ensure-github-labels.sh >/dev/null
test "$(wc -l < "$tmp/labels/created")" -eq 3
rm "$tmp/labels/ci"
bash scripts/ensure-github-labels.sh >/dev/null
test "$(wc -l < "$tmp/labels/created")" -eq 4
test -f "$tmp/labels/ci"
printf '%s\n' 'PASS: Dependabot labels bootstrap, idempotency and drift repair'
