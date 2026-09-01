# Release Guide

For the maintainer cutting a release. Contributors want
[CONTRIBUTING.md](../CONTRIBUTING.md) instead.

## Pre-Release Steps

0. **Sync local `dev` with remote**
   ```bash
   git fetch origin
   git checkout dev
   git rebase origin/dev  # or `git pull --rebase`
   ```

1. **Ensure on `dev` branch**
   ```bash
   git checkout dev
   ```

2. **Run the checks**
   ```sh
   tests/run.sh
   shellcheck install/*.sh tests/*.sh tools/*.sh
   pwsh -c 'Invoke-ScriptAnalyzer -Path install/foxprivacy.ps1'   # or rely on CI
   ```

3. **Confirm the release was actually installed somewhere**
   No release ships on green tests alone. Tests cannot tell you that Firefox
   accepted a policy or that a real site still works. Every release must have
   been installed on a real Firefox with an empty `about:policies` Errors tab,
   on each platform it claims to support. Use the matrix in
   [RELEASE_CANDIDATES.md](RELEASE_CANDIDATES.md), and run a release candidate
   first for anything with a `policy:` commit in it.

4. **Update version files**
   - `VERSION` -> `X.Y.Z`
   - `install/foxprivacy.sh` -> `FOXPRIVACY_VERSION="X.Y.Z"`
   - `install/foxprivacy.ps1` -> `$FoxPrivacyVersion = 'X.Y.Z'`
   - `README.md` -> any install snippet pinned to a tag

   `tests/run.sh` fails if these disagree.

5. **Update CHANGELOG.md**
   - Add section `## [X.Y.Z] - YYYY-MM-DD`
   - Set the date with `date +%F` (ISO, YYYY-MM-DD)
   - **Policy changes** goes first when present, before Added/Changed/Fixed/
     Removed. It is the section that tells a user their browser will behave
     differently, and it is the only reason most people read a changelog for
     this project. Each entry names the effect, not the file.
   - Gather changes since the last tag:
     ```bash
     last_tag=$(git describe --tags --abbrev=0)

     # Quick overview (oldest -> newest)
     git log --reverse --oneline "${last_tag}..HEAD"

     # Detailed subject list to paste and categorize
     git log --reverse --pretty=format:"- %s (%h) by %an" "${last_tag}..HEAD"

     # The section that matters: everything that changes the browser
     git log --reverse --pretty=format:"- %s" "${last_tag}..HEAD" | grep '^- policy:'

     # What actually changed on disk, to check the changelog is honest
     git diff "${last_tag}..HEAD" -- policies/
     ```
   - Optionally include a compare link:
     `https://github.com/andreas-glaser/FoxPrivacy/compare/${last_tag}...vX.Y.Z`
   - Update the reference links at the bottom of `CHANGELOG.md`:
     - Change `[Unreleased]` to compare from the new tag: `.../compare/vX.Y.Z...HEAD`
     - Add a new reference for `[X.Y.Z]` comparing `${last_tag}...vX.Y.Z`

6. **Commit changes**
   ```bash
   git add -A
   git commit -m "chore: prepare release vX.Y.Z"
   ```

## Release Process

7. **Merge to main**
   ```bash
   git checkout main
   git merge dev --no-ff -m "Merge dev for vX.Y.Z release"
   ```

8. **Create and push the tag with a changelog excerpt**
   ```bash
   git tag -a vX.Y.Z -m "Release vX.Y.Z

   ## Policy changes
   - Sponsored address bar suggestions are now off by default

   ## Added
   - macOS target detection

   ## Fixed
   - Uninstall restores the backup when run twice

   ## Changed
   - Captive portal detection moved to the strict profile"

   git push origin main --tags
   ```

9. **GitHub Actions builds the release**
   - Workflow triggers on the tag push, and refuses to build if the tag,
     `VERSION`, both installers and the changelog disagree
   - Builds `foxprivacy-vX.Y.Z.tar.gz` and `foxprivacy-vX.Y.Z.zip`
   - Builds the single file `foxprivacy.sh` and `foxprivacy.ps1` that the
     documented one line install downloads
   - Writes `SHA256SUMS`
   - Publishes the GitHub Release with those assets

10. **Update the GitHub release notes**
    ```bash
    gh release edit vX.Y.Z --notes "<copy of the changelog entry>"
    ```
    - Lead with **Policy changes**. Someone deciding whether to re-run the
      installer should not have to open another file to find out what will
      change in their browser.
    - A major release states what a user must do, in one sentence, at the top.

11. **Verify GitHub Actions**
    ```bash
    gh workflow view "Release"
    gh run list --workflow="Release" --limit 3
    ```
    - Or manually: https://github.com/andreas-glaser/FoxPrivacy/actions
    - Only proceed to tagging once the release-prep commit on `main` is green.

## Post-Release

12. **Verify the published artifacts**
    ```bash
    gh release download vX.Y.Z --dir /tmp/fp-verify
    cd /tmp/fp-verify && sha256sum -c SHA256SUMS
    tar xzf foxprivacy-vX.Y.Z.tar.gz
    ./foxprivacy-vX.Y.Z/install/foxprivacy.sh --dry-run --profile standard
    ```
    Install the downloaded archive, not your working tree. A release that was
    never unpacked has never been tested.

13. **Sync dev with main**
    ```bash
    git checkout dev
    git merge main
    git push origin dev
    ```

## Version Bumping Rules

Summarised here, explained in [GIT_GUIDE.md](GIT_GUIDE.md):

- **Patch**: installer fixes and docs. No change to what a working install does.
- **Minor**: a new platform, a new flag, or a new policy that removes data
  collection without changing how sites behave.
- **Major**: anything a user would notice while browsing. Moving a setting from
  `strict` into `standard`, changing an install path, removing a flag, or
  changing what uninstall restores.

## Files Modified Per Release
- `VERSION`
- `CHANGELOG.md`
- `install/foxprivacy.sh`
- `install/foxprivacy.ps1`
- `README.md`
