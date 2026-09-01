# Release Candidates

Release candidates let testers try the next FoxPrivacy version before it becomes
the release everyone downloads.

## Why this project needs them

A bad policy file does not crash. It silently changes a browser, on every
machine that ran the installer, and the user finds out when a site stops
working or when a setting they expected to be off is still on. There is no
automatic rollback: the fix is a person re-running the installer.

Tests catch a malformed file or a policy key Firefox does not know. They cannot
catch "this breaks logins on a banking site" or "Firefox 148 renamed this
policy". Only installing the thing on a real browser catches that, so anything
carrying a `policy:` commit goes through an RC.

## Version and branch policy

- Use `vX.Y.Z-rc.N`, for example `v0.2.0-rc.1`.
- Start `release/X.Y.Z` from the tested `origin/dev` commit.
- Keep `main` on the latest stable release until the final version is ready.
- Never move or reuse an RC tag. Publish `rc.2` if another candidate is needed.
- Set `VERSION`, `FOXPRIVACY_VERSION` in `install/foxprivacy.sh`, and
  `$FoxPrivacyVersion` in `install/foxprivacy.ps1` to the same version without
  the leading `v`.
- Add an exact `## [X.Y.Z-rc.N]` entry to `CHANGELOG.md`.

The release workflow accepts stable `X.Y.Z` versions and this RC format, and
publishes an RC as a GitHub **prerelease**. That matters for one specific
reason: the `latest` release URL keeps pointing at the last stable version, so
the install command in the README does not start handing an RC to people who
never asked for one.

## Prepare and publish an RC

Replace the example version in these commands:

```bash
git fetch origin
git switch -c release/0.2.0 origin/dev

# Update VERSION, both installers, and CHANGELOG.md to 0.2.0-rc.1.

tests/run.sh
shellcheck install/*.sh tests/*.sh tools/*.sh
git diff --check

git add VERSION CHANGELOG.md install/foxprivacy.sh install/foxprivacy.ps1
git commit -m "chore: prepare v0.2.0-rc.1"
git push -u origin release/0.2.0
```

Wait for CI to pass on the release branch. Then tag that exact commit:

```bash
git tag -a v0.2.0-rc.1 -m "Release candidate v0.2.0-rc.1"
git push origin v0.2.0-rc.1
```

Confirm that:

1. The GitHub release is marked **Pre-release**, not **Latest**.
2. Both archives and `SHA256SUMS` are attached.
3. The installer inside the archive reports the RC version with `--version`.

Do not merge the RC-only version commit into `main`. Continue fixes on the
release branch.

## Test matrix

An RC is done when every row a release claims to support has been walked
through by a person. Record the Firefox version and channel in the RC issue,
because "it worked" without a version number is not a result.

| Platform | Install source to test | Why it is separate |
|---|---|---|
| Linux | distro package (deb/rpm) | The `/etc/firefox/policies` path, the primary target |
| Linux | snap | Different confinement, policy path needs confirming per release |
| Linux | flatpak | Read-only app tree, policy path needs confirming per release |
| macOS | Mozilla .dmg build | Policies live inside the app bundle |
| Windows | Mozilla installer | Policies live inside Program Files |

For each row:

1. Note the Firefox version from `about:support`.
2. Run the installer with `--dry-run` first and read what it says it will do.
3. Install, then fully quit and reopen Firefox. Policies are read at startup.
4. Open `about:policies`. **The Errors tab must be empty.** This is the check
   that catches a renamed or removed policy, and nothing else catches it.
5. On the Active tab, confirm the policies you expected are listed. A policy
   that is absent without an error was probably dropped by a typo.
6. Browse normally for a few minutes. Log into something. Play a video. Check
   that the new tab page, address bar, and search still behave.
7. Run `--verify` and confirm it reports the installed profile correctly.
8. Uninstall. Confirm the previous file was restored, or removed if there was
   none, and that `about:policies` is clean after a restart.

Step 8 is not optional. An uninstall that does not restore state is the one bug
in this project that leaves a user worse off than never having found it.

## How a tester installs an RC

There is no update channel to opt into. A tester downloads the prerelease and
runs it, which also means an RC never reaches anyone who did not go looking:

```bash
gh release download v0.2.0-rc.1 --dir ~/fp-rc
cd ~/fp-rc
sha256sum -c SHA256SUMS          # shasum -a 256 -c SHA256SUMS on macOS
tar xzf foxprivacy-v0.2.0-rc.1.tar.gz
cd foxprivacy-v0.2.0-rc.1
./install/foxprivacy.sh --dry-run --profile standard
./install/foxprivacy.sh --profile standard
```

Verify the checksum before running anything. This project's whole job is to be
trusted with a browser configuration, so telling people to pipe an unverified
download into a shell would be a poor advertisement for it.

To go back to the stable version, uninstall the RC and run the stable release's
installer:

```bash
./install/foxprivacy.sh --uninstall
```

## Finish the stable release

After testing, change the version to `X.Y.Z`, consolidate the RC changelog
entries into one `## [X.Y.Z]` section, run the full checks, and follow
[RELEASE_GUIDE.md](RELEASE_GUIDE.md). The stable tag is created only after the
release branch reaches `main`. Merge the final release state back into `dev`.

## Upstream references

- [Firefox enterprise policy documentation](https://firefox-admin-docs.mozilla.org/reference/policies/)
- [Firefox policy templates and releases](https://github.com/mozilla/policy-templates)
- [The policy schema Firefox validates against](https://raw.githubusercontent.com/mozilla/gecko-dev/master/browser/components/enterprisepolicies/schemas/policies-schema.json)
