# Git, Branching, and Tagging Guide

This guide explains the repository's git setup, branching strategy, and
tagging/release flow. It complements the Commit and Release guides.

## Branch Model

Branches used:
- `main`: stable, released. Protected.
- `dev`: integration branch for the upcoming release.
- `feature/*`: new features (e.g., `feature/macos-target`).
- `fix/*`: bug fixes for the next release (e.g., `fix/backup-overwrite`).
- `hotfix/*`: urgent fixes based off `main` (e.g., `hotfix/broken-uninstall`).
- `release/*`: stabilization before a release, and the base for release
  candidates.

PR targets:
- Features and fixes -> target `dev`.
- Hotfixes -> target `main`, then forward-merge to `dev`.

A hotfix is justified here when the released tool leaves a machine in a bad
state: an uninstall that does not restore the backup, an installer that writes
to the wrong path, or a policy that breaks ordinary browsing. Everything else
waits for `dev`.

## Local Git Setup

Initial configuration:
```bash
# Identity
git config --global user.name "Your Name"
git config --global user.email "you@example.com"

# Safer, cleaner history (recommended)
git config --global pull.rebase true
git config --global rebase.autoStash true
git config --global fetch.prune true

# Optional: sign commits/tags (if you use GPG/SSH signing)
# git config --global commit.gpgsign true
# git config --global tag.gpgSign true
```

Clone and track branches:
```bash
git clone git@github.com:andreas-glaser/foxprivacy.git
cd foxprivacy

# Ensure local tracking branch for dev
git fetch origin dev:dev
git checkout dev
```

Keep your fork up to date (if contributing via a fork):
```bash
# Add upstream once
git remote add upstream git@github.com:andreas-glaser/foxprivacy.git

# Update your local main and dev
git fetch upstream
git checkout main && git rebase upstream/main
git checkout dev && git rebase upstream/dev

# Push synced branches to your fork
git push origin main
git push origin dev
```

## Working on Changes

Feature:
```bash
git checkout dev
git pull --rebase origin dev
git checkout -b feature/your-feature
# ...work, commit...
git push -u origin feature/your-feature
# Open PR -> base: dev
```

Bug fix (non-urgent):
```bash
git checkout dev
git pull --rebase origin dev
git checkout -b fix/short-desc
# ...work, commit...
git push -u origin fix/short-desc
# Open PR -> base: dev
```

Hotfix (urgent fix for released behaviour):
```bash
git checkout main
git pull --rebase origin main
git checkout -b hotfix/short-desc
# ...work, commit...
git push -u origin hotfix/short-desc
# Open PR -> base: main

# After merge, maintainers will forward-merge main -> dev
```

## Changing a Policy File

Policy changes are the only changes that alter what a user's browser does, so
they carry an extra step. Before opening the PR:

```sh
tests/run.sh                                  # schema check against Firefox's own schema
install/foxprivacy.sh --dry-run --profile standard
```

Then install it into a real Firefox and open `about:policies`. The Errors tab
must be empty. A policy Firefox rejects is not an error you will see any other
way. Record in the PR which Firefox version and channel you tested against.

If a setting has a usability cost, its `presets:` line says `strict` only, and
its `cost:` line says what the user loses. `docs/POLICIES.md` is generated from
the manifest by `tools/gen-docs.sh`, so never edit it by hand.

## Version Bumping

There is no build artifact to regenerate, only text files that must agree:

```bash
echo "0.2.0" > VERSION
# install/foxprivacy.sh   -> FOXPRIVACY_VERSION="0.2.0"
# install/foxprivacy.ps1  -> $FoxPrivacyVersion = '0.2.0'
# Update CHANGELOG.md under [Unreleased]
git add VERSION install/foxprivacy.sh install/foxprivacy.ps1 CHANGELOG.md
git commit -m "chore: bump version to 0.2.0"
```

`tests/run.sh` asserts these versions match. A mismatch fails the build rather
than shipping an installer that misreports its own version.

## Version Numbers Mean Something Here

This is a configuration tool, so "breaking" is about the user's browser and the
command line, not about an API:

- **Patch (X.Y.Z+1)**: installer bug fixes, documentation, a corrected policy
  key that Firefox was already rejecting. No change to what a working install
  does.
- **Minor (X.Y+1.0)**: a new platform target, a new flag, or a new policy that
  removes data collection without changing how sites behave.
- **Major (X+1.0.0)**: anything a user would notice in normal browsing. Moving a
  setting from `strict` into `standard`, changing an install path, removing a
  flag, or changing what uninstall restores.

When in doubt about whether a policy change is minor or major, ask whether a
user who re-ran the installer without reading the changelog could be surprised
by their browser. If yes, it is major.

## Tagging and Releases

Release tags follow SemVer with a `v` prefix: `vX.Y.Z`.

Create an annotated tag and push:
```bash
# Ensure dev is merged into main first
git checkout main
git pull --rebase origin main
git merge --no-ff dev -m "Merge dev for v0.2.0 release"
git push origin main

# Tag the release (annotated)
git tag -a v0.2.0 -m "Release v0.2.0"
git push origin v0.2.0
```

What happens next:
- The "Release" workflow triggers on tag `v*`.
- CI validates the CHANGELOG entry and the version consistency check, builds the
  `.tar.gz` and `.zip` archives, writes `SHA256SUMS`, and publishes the GitHub
  Release with those assets.

For a prerelease that testers must opt into, follow
[Release Candidates](RELEASE_CANDIDATES.md). RCs use `vX.Y.Z-rc.N`, are tagged
from a tested release branch, and are published as GitHub prereleases without
moving `main` away from the latest stable version.

Manual release (workflow dispatch):
```bash
# Actions -> Release -> Run workflow -> version: v0.2.0
```

## Forward-Merging Hotfixes

After a hotfix is tagged from `main`, merge it back into `dev` to keep branches
aligned:
```bash
git checkout dev
git pull --rebase origin dev
git merge --no-ff main -m "Merge main into dev after v0.2.1 hotfix"
git push origin dev
```

## Handy Commands

```bash
# See branch graph
git log --oneline --graph --decorate --all --date-order

# Every policy change since the last release, for the changelog
git log --reverse --pretty=format:"- %s (%h)" "$(git describe --tags --abbrev=0)..HEAD" \
  | grep '^- policy:'

# What a release would actually change on disk
git diff "$(git describe --tags --abbrev=0)..HEAD" -- policies/

# Clean stale local branches
git fetch -p
git branch --merged | grep -vE "\*|main|dev" | xargs -r git branch -d

# Abort a rebase if needed
git rebase --abort

# Resolve conflicts then continue
git add -A && git rebase --continue
```
