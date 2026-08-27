---
title: Development — documentation
---

# Documentation architecture

The site uses the Diátaxis-style split between tutorials, how-to guides,
reference, and explanation, plus project/developer records.

```text
docs/
├─ tutorials/      learning by doing
├─ how-to/         task-oriented operator recipes
├─ reference/      exact contracts and values
├─ explanation/    architecture and rationale
└─ development/    contribution/testing/docs internals

tagged root records
ARCHITECTURE.md ROADMAP.md CHANGELOG.md SECURITY.md RELEASING.md
DEVELOPMENT.md DEV_NOTES.md
          │
          └─ prepare-docs-site.sh ──> project/* in release site
```

## Local preparation

```sh
./scripts/prepare-docs-site.sh .docs-site
```

The script copies only tracked documentation and the public config schema into a
staging directory. Runtime state, `.env`, backups, and release evidence are not
part of the site source.

If Ruby/Jekyll is available locally, build `.docs-site` with the GitHub Pages
compatible Jekyll environment. The authoritative build uses GitHub's pinned
Pages actions in `.github/workflows/pages.yml`.

## Release consistency

Do not edit website copies of the changelog/roadmap/security policy manually.
Edit the canonical root file; the release site assembler republishes it from the
tag. This prevents two drifting histories.

## Link/content review

For a release check:

- every new config key appears in reference and migration docs;
- every removed key appears in upgrade guidance;
- every new command appears in command reference;
- network changes update diagrams and both positive/negative test description;
- security changes update `SECURITY.md` and explanation;
- release behavior updates `RELEASING.md`;
- roadmap and changelog reflect what actually shipped.
