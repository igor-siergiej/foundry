# Dependency & CVE sweep

How every repo in this homelab gets a weekly bump + auto-merge pass,
plus a process for failures and majors.

## Repos in scope

| Repo | Current setup | Action |
|---|---|---|
| `shoppingo` | hand-managed | add `.github/dependabot.yml` from the template below |
| `jewellery-catalogue` | hand-managed | add `.github/dependabot.yml` from the template below |
| `kivo` | `.github/dependabot.yml` exists (bun + github-actions) | enable auto-merge workflow (see below) |
| `mixtape` | hand-managed | add `.github/dependabot.yml` from the template below |
| `portfolio` | hand-managed | add `.github/dependabot.yml` from the template below |
| `utils` | hand-managed | add `.github/dependabot.yml` from the template below |
| `foundry` (this repo) | added in this PR | — |

`kivo` already runs Dependabot; it just needs the auto-merge workflow
copied in.

## Template Dependabot config (per repo)

Replace each repo's existing `.github/dependabot.yml` (or create one)
with this. Adjust the package-ecosystems to whatever that repo
actually uses (the template covers the common cases).

```yaml
version: 2

updates:
  - package-ecosystem: bun
    directory: /
    schedule:
      interval: weekly
      day: monday
      time: "04:00"
    open-pull-requests-limit: 10
    labels:
      - dependencies
    commit-message:
      prefix: "deps"
    groups:
      patch:
        applies-to: version-updates
        update-types:
          - minor
          - patch

  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
      day: monday
      time: "04:00"
    open-pull-requests-limit: 5
    labels:
      - dependencies
      - ci
    commit-message:
      prefix: "ci"
```

If the repo uses npm, add an `npm` block alongside `bun`. If it has
Docker Compose (it shouldn't, but `mixtape` has a `docker-compose.yml`
for local dev), add a `docker` block per the foundry config.

## Auto-merge workflow

Drop the `kivo` repo's existing or this foundry repo's
`.github/workflows/dependabot-merge.yml` into each repo. No changes
needed — the workflow is repo-agnostic.

## Foundry-specific

`foundry` itself doesn't ship a `package.json`; its only "deps" are
Docker images in compose files (SECURITY-AUDIT #8) and GitHub Actions
versions. The Dependabot config in this repo covers both.

**First-run caveat:** Dependabot can't track `:latest` (no version to
compare against), so the very first Dependabot run after this lands
will likely open no PRs. The pinning pass is manual — see "Pinning
images" below.

## Pinning images

For each `<stack>/docker-compose.yml`:

1. `docker pull <image>` to fetch the current `:latest`.
2. Look up its digest: `docker inspect --format '{{index .RepoDigests 0}}' <image>`.
3. Replace `image: <image>:latest` with `image: <image>:<digest>`.

Commit + push + redeploy. Once each image is pinned, Dependabot will
start producing weekly PRs.

Skip this for `mixtape-{api,web}-latest` — those are first-party
`igurusama/imapps:mixtape-*` images built by `mixtape` CI, and the
intentional `:latest` is what `pull_policy: always` in
`mixtape/docker-compose.yml` already pins.

## Process

For each repo, weekly (Monday 04:00):

1. **Dependabot opens PRs** — patch + minor for `bun`, `npm`,
   `github-actions`, `docker`.
2. **CI runs** on the PR (lint, test, e2e per repo's `.kanban-cli.json`).
3. **`dependabot-merge.yml` workflow** checks the PR's update-type:
   - **patch / minor**: `gh pr merge --auto --squash`. Lands once CI
     is green.
   - **major**: labels with `needs-major-review`, leaves the PR open.
     The PR description has `/kanban` so the board capture flow picks
     it up as a Backlog card automatically (see
     `notes-kanban#refining-kanban-captures`).
   - **security**: labels with `security` + `dependencies`, leaves
     the PR open. `/kanban` again.
4. **CI failures** on a patch/minor bump: Dependabot rebase the PR;
   the workflow doesn't merge while CI is red. Open a Backlog card
   with the failing log excerpt + the dep name.

## Flaky CI

The card body calls out 3-4 failures in the last 30 runs on `mixtape`,
`kivo`, `portfolio`. These block auto-merge before the bump even
lands. Fix each flake before enabling auto-merge there — the
`./.kanban-cli.json` retry counter is the indicator; if
`retryPolicy.e2e_local` trips, treat the flake as a separate bug, not
a dep-sweep problem.

## Why Dependabot, not Renovate

Both work. Dependabot is free for public repos and ships with the
GitHub Actions ecosystem; Renovate is more configurable (groups,
schedule windows per package, better major-version UX). For this
homelab's needs (one weekly bump per package manager, auto-merge
patch+minor, manual majors), Dependabot is the boring choice.

If a repo grows past the simple case — grouped updates, per-package
scheduling, custom regex managers — switch that repo to Renovate
instead. Don't mix both on one repo; they collide.