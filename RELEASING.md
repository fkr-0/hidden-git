# Releasing HiddenGit

## Version policy

HiddenGit follows Semantic Versioning 2.0.0.

- `0.y.z` denotes an experimental product whose operator contract may still change.
- Increment `z` for compatible fixes, hardening, documentation, and release-engineering improvements.
- Increment `y` for a new capability or an intentionally changed pre-`1.0` operator or configuration contract.
- Use `1.0.0` only after the stability criteria in `ROADMAP.md` are satisfied.
- Prereleases use standard SemVer identifiers such as `0.1.0-rc.1`.

`VERSION` is canonical. The following release metadata must agree:

- `VERSION`;
- `HIDDEN_GIT_VERSION` in `env.example`;
- the `README.org` release subtitle;
- the dated release section in `CHANGELOG.md`;
- the local annotated Git tag `v<VERSION>`;
- the release documentation assembled from that tag.

## Changelog policy

`CHANGELOG.md` follows Keep a Changelog. User- and operator-visible changes are grouped under `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, and `Security` as applicable.

Keep upcoming work under `Unreleased`. When releasing:

1. choose the version according to the policy above;
2. move relevant entries into a dated version section;
3. describe migrations, compatibility changes, security implications, and known limitations;
4. leave unrelated future work under `Unreleased`.

## Local release procedure

The procedure creates a local commit and annotated tag only. It does not push, publish, deploy, sign, upload, or create a remote release.

### 1. Preflight

```sh
git status --short --branch
git log -1 --oneline --decorate
git tag --list --sort=version:refname
./run.sh version
```

Confirm that unrelated work is absent and that `v<VERSION>` does not already exist.

### 2. Release metadata

Update and review:

```text
VERSION
env.example
config/schema.json
README.org
CHANGELOG.md
ARCHITECTURE.md
ROADMAP.md
SECURITY.md
DEVELOPMENT.md
DEV_NOTES.md
docs/
.github/workflows/pages.yml
issues.yml
```

### 3. Static and configuration gates

```sh
./tests/test.sh
./run.sh config check
./run.sh config
./scripts/prepare-docs-site.sh .docs-site
./run.sh doctor --strict
```

`config check` must reject legacy/duplicate/unknown/drifted files rather than allowing Compose to normalize them implicitly. If a supported old deployment needs migration, preview and explicitly apply `config migrate` before release qualification, then prove a second apply is a no-op.

`prepare-docs-site.sh` must assemble only public tracked documentation plus the public config schema; inspect the staging tree for accidental runtime data before a release. `doctor --strict` evaluates the local deployment and may fail for intentionally local conditions. Such a failure must be resolved or recorded in the release evidence; it must not be silently ignored.

### 4. Build and integration gates

```sh
./run.sh build
./tests/backup-restore.sh
./tests/non-root-migration.sh
./tests/e2e.sh
./tests/rootless-docker.sh
```

The E2E and rootless tests require Docker and network access to bootstrap Tor and fetch or build pinned images.

### 5. Supply-chain gate

```sh
VULNERABILITY_POLICY_STRICT=1 ./run.sh evidence release-evidence
```

Review the generated summaries, provenance, SBOMs, and vulnerability-policy results. Generated evidence is intentionally ignored by Git and must not contain runtime state or credentials.

### 6. Review and commit

```sh
git diff --check
git diff --stat
git diff
git add -- <reviewed release paths>
git diff --cached --check
git commit -m "release: finalize hidden-git <VERSION>"
```

### 7. Tag gate

Re-run mandatory checks against the committed tree, then create an annotated tag:

```sh
version="$(tr -d '[:space:]' < VERSION)"
test -z "$(git status --porcelain)"
test -z "$(git tag --list "v${version}")"
git tag -a "v${version}" -m "HiddenGit v${version}"
test "$(git rev-parse HEAD)" = "$(git rev-list -n 1 "v${version}")"
git show --no-patch --decorate "v${version}"
```

Do not move or replace an existing release tag.

## CI and documentation release behavior

Tag pushes matching `v*` run the full CI workflow. Static validation rejects a tag whose name does not equal `v<VERSION>`. The release-evidence job generates provenance, SBOM, and vulnerability artifacts for the tagged source. **Do not publish the GitHub Release until the tag-triggered CI run, including release evidence, is green.**

Publishing a GitHub Release is a **second explicit remote action** after that CI gate. The `Release documentation` workflow then:

1. checks out exactly `github.event.release.tag_name`;
2. verifies that tag equals `v<VERSION>` and points at the checked-out commit;
3. reruns static/config/documentation checks;
4. assembles canonical root project records with `docs/` and the public config schema;
5. builds the Jekyll site with pinned GitHub Pages actions;
6. verifies the artifact excludes `.env`, `data/`, and `backups/`;
7. deploys only from the separate job that has `pages:write` and `id-token:write` through the `github-pages` environment.

A push to `main` does not update the public release documentation. `workflow_dispatch` exists only for deliberate operator recovery/preview and should not silently replace the published-release provenance story.

### One-time Pages/custom-domain precondition

Before the first hosted documentation release, a repository administrator must configure **Settings → Pages** to use GitHub Actions and set the custom domain to `hiddengit.fkr.dev`. Configure the DNS subdomain CNAME according to the exact target GitHub displays (expected for the current owner: `fkr-0.github.io`), wait for DNS/certificate validation, then enable HTTPS. A repository `CNAME` file is intentionally unnecessary for this custom Actions workflow.

Remote tag push, hosted release creation, Pages settings, and DNS changes are intentionally outside the local release procedure and each require an explicit operator decision.

## Failed release

When a mandatory gate fails:

- do not create the tag;
- keep the evidence and exact failing command;
- fix the narrow failure without unrelated dependency or formatting churn;
- rerun the failed gate and every gate affected by the change;
- document any accepted warning or omitted environment-specific check.

If a local unpushed tag was created by mistake, inspect it before deleting it. Never rewrite a tag that may have been shared.
