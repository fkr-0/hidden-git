---
title: Explanation — release and documentation model
---

# Release and documentation model

The website is a release artifact, not an always-current main-branch preview.

## Pipeline

```text
reviewed source
     │
     ├─ static/config tests
     ├─ build/integration/rootless tests
     ├─ SBOM + provenance + vulnerability policy
     │
     v
annotated tag v<VERSION>
     │
tag-triggered CI green
     │
GitHub Release published
     │
     └─ Release documentation workflow
          ├─ checkout exact release tag
          ├─ verify tag == v<VERSION>
          ├─ rerun static/docs checks
          ├─ assemble tagged canonical docs
          ├─ Jekyll build
          └─ GitHub Pages deployment
                    │
                    v
             hiddengit.fkr.dev
```

Publishing docs from the release event prevents documentation on the custom
domain from racing ahead of released operator behavior. The hosted release is
published only after the tag-triggered CI run, including strict release evidence,
is green.

## One-time GitHub Pages setup

Repository administrators must configure Pages to use **GitHub Actions** and set
the custom domain to `hiddengit.fkr.dev` through repository settings or the
GitHub API. With a custom Actions workflow, a repository `CNAME` file is ignored
and unnecessary.

At the DNS provider configure the subdomain CNAME according to GitHub Pages
instructions (for this repository owner, the expected target is
`fkr-0.github.io`). Verify the exact DNS target in GitHub's Pages UI before
changing production DNS, wait for certificate issuance, and then enable HTTPS.

## Workflow privilege separation

The build job has read-only repository permission. Only the deploy job receives
`pages:write` and `id-token:write`, and it deploys through the protected
`github-pages` environment. Third-party action references are immutable commit
SHAs and remain subject to Dependabot/release review.

## What manual workflow dispatch means

Manual dispatch exists for operator-controlled recovery or preview of a selected
ref. It is not a substitute for the normal release gate. The public site's
release claim should be based on a published release run.
