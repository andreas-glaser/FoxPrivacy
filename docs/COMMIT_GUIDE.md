# Commit Guide

## Pre-Commit Checks

1. **Review changes**
   ```bash
   git status
   git diff
   git diff --staged
   ```

2. **Validate the manifest**
   ```sh
   tests/run.sh    # manifest checks, Firefox schema check, install and restore cycle
   ```
   A policy key Firefox does not recognise is ignored silently, so the schema
   check is the one that matters most. Never commit a change to `policies/`
   without it.

3. **Lint the installers**
   ```sh
   shellcheck install/*.sh tests/*.sh tools/*.sh
   pwsh -c 'Invoke-ScriptAnalyzer -Path install/foxprivacy.ps1'   # if pwsh is available
   ```
   PowerShell analysis runs in CI when no local `pwsh` exists. Say so in the PR
   rather than claiming the script was checked locally.

Commands are declared in `.agents/kit.toml` under `[commands]`. Run those, do
not invent a variant.

## Commit Process

4. **Stage files**
   ```bash
   git add <specific_files>
   # or
   git add -p  # interactive staging
   ```

5. **Create commit**
   ```bash
   git commit -m "<type>: <description>"
   ```

6. **Verify CI/CD**
   ```bash
   gh run list --limit 5
   gh run view  # interactive selection
   ```
   - Or manually: https://github.com/andreas-glaser/foxprivacy/actions
   - Ensure the latest commit is green before creating release tags; never push
     a tag while CI is red.

## Commit Message Format

**Types:**
- `policy`: Change to `policies/features.conf`, meaning a change to what the browser does
- `feat`: New feature (installer flag, new platform target, new verb)
- `fix`: Bug fix
- `docs`: Documentation only
- `style`: Formatting only, no behaviour change
- `refactor`: Code restructuring
- `test`: Test additions or changes
- `chore`: Build, config, CI, dependencies

`policy` exists because it is the only type that changes a user's browser. Those
commits are collected into the "Policy changes" section of the changelog, and a
release with any of them gets extra scrutiny.

**Examples:**
- `policy: disable sponsored address bar suggestions`
- `policy: move captive portal detection to strict profile`
- `feat: add --verify to the Linux installer`
- `fix: restore the backup when uninstall runs twice`
- `docs: explain the macOS app bundle update caveat`
- `chore: bump version to 0.2.0`

## Rules
- Use imperative mood ("add" not "added")
- No period at end
- No AI or Claude references, no Co-Authored-By trailer, no session links
- Plain ASCII punctuation, no em dashes, no curly quotes, no emoji
- A `policy` commit names the policy or the user-visible effect, not the file

## Multi-line Format (when needed)

Use it whenever a `policy` commit has a trade-off worth recording:

```bash
git commit -m "policy: enable strict tracking protection in the strict profile" -m "
- EnableTrackingProtection.Category set to strict
- Cost: some embedded logins and comment widgets need a per-site exception
- Left unlocked so the shield toggle still works
- Refs #12"
```
