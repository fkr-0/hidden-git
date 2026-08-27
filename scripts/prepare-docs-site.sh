#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${1:-${ROOT_DIR}/.docs-site}"

case "$OUTPUT" in
    /*) ;;
    *) OUTPUT="${ROOT_DIR}/${OUTPUT}" ;;
esac
OUTPUT="$(realpath -m "$OUTPUT")"
case "$OUTPUT" in
    "$ROOT_DIR"/*) ;;
    *) printf 'refusing to build documentation outside repository: %s\n' "$OUTPUT" >&2; exit 2 ;;
esac

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"
cp -a "$ROOT_DIR/docs/." "$OUTPUT/"
mkdir -p "$OUTPUT/project" "$OUTPUT/assets"

copy_project_doc() {
    local source="$1"
    local destination="$2"
    local title="$3"
    {
        printf '%s\n' '---'
        printf 'title: "%s"\n' "$title"
        printf '%s\n' '---'
        printf '\n'
        cat "$ROOT_DIR/$source"
    } > "$OUTPUT/project/$destination"
}

copy_project_doc ARCHITECTURE.md architecture.md 'Canonical architecture'
copy_project_doc ROADMAP.md roadmap.md 'Roadmap'
copy_project_doc CHANGELOG.md changelog.md 'Changelog'
copy_project_doc SECURITY.md security.md 'Security policy'
copy_project_doc RELEASING.md releasing.md 'Release process'
copy_project_doc DEVELOPMENT.md development.md 'Development guide'
copy_project_doc DEV_NOTES.md dev-notes.md 'Developer notes'

cp "$ROOT_DIR/config/schema.json" "$OUTPUT/assets/config-schema.json"
printf '%s\n' "$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")" > "$OUTPUT/assets/release-version.txt"

printf 'Prepared HiddenGit documentation source at %s\n' "$OUTPUT"
