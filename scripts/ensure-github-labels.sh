#!/usr/bin/env bash
set -euo pipefail

# Dependabot does not create labels named in .github/dependabot.yml.
# Bootstrap them on the repository, without modifying any existing labels.
repo="${GH_REPO:-${GITHUB_REPOSITORY:-${1:-}}}"
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    printf 'usage: GH_REPO=owner/repo %s\n' "$0" >&2
    exit 2
fi
command -v gh >/dev/null || { printf 'gh CLI is required\n' >&2; exit 2; }

ensure_label() {
    local name="$1" color="$2" description="$3"
    if gh api --silent "repos/$repo/labels/$name" >/dev/null 2>&1; then
        printf 'EXISTS %s\n' "$name"
        return 0
    fi
    # A permission error also fails closed here: do not ignore create failures.
    gh label create "$name" --repo "$repo" --color "$color" --description "$description"
    printf 'CREATED %s\n' "$name"
}

ensure_label dependencies 0366d6 'Dependency upgrades and maintenance'
ensure_label docker 0e8a16 'Docker image and Compose dependency updates'
ensure_label ci 5319e7 'Continuous integration and GitHub Actions'
