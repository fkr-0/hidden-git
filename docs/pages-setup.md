---
title: GitHub Pages and custom-domain setup
---

# One-time GitHub Pages setup for `hiddengit.fkr.dev`

The repository contains the release deployment workflow. GitHub and DNS still
need one-time administrative configuration; a repository `CNAME` file is not
needed for a custom GitHub Actions Pages workflow.

## Repository settings

In **Settings → Pages**:

1. choose **GitHub Actions** as the publishing source;
2. set the custom domain to `hiddengit.fkr.dev`;
3. wait for GitHub's DNS/certificate checks to succeed;
4. enable **Enforce HTTPS** when available.

The workflow uses the `github-pages` environment. Apply any desired environment
protection/reviewer policy without granting the build job Pages write access.

## DNS

At the DNS provider, create the subdomain CNAME required by GitHub Pages. For the
repository `fkr-0/hidden-git`, the expected Pages owner host is
`fkr-0.github.io`; confirm the exact value displayed by GitHub before applying
production DNS.

Avoid wildcard DNS for GitHub Pages unless there is a separately reviewed need.
GitHub recommends domain verification as protection against takeover scenarios.

## Normal publication

Publish a GitHub Release for a tag that exactly matches `v<VERSION>`. The
`Release documentation` workflow checks out that tag, rebuilds the site, and
deploys the Pages artifact. A push to `main` alone does not replace the public
release documentation.

## Recovery/manual publication

`workflow_dispatch` can build a selected ref. Treat a manual deploy as an
operator action and record why it was used, especially if it changes the public
site without a corresponding new GitHub Release.
