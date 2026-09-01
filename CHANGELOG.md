# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries under **Policy changes** come first in every release. They are the ones
that change what a browser does after an install, and they are why most people
read this file. See [docs/GIT_GUIDE.md](docs/GIT_GUIDE.md) for what counts as a
major, minor, or patch change in a configuration tool.

## [Unreleased]

## [1.0.0] - 2026-09-01

### Added
- `install/foxprivacy.sh` for Linux and macOS: interactive menu, `--profile`,
  `--enable`/`--disable`, `--list`, `--dry-run`, `--verify`, `--uninstall`.
  POSIX shell and `awk` only, with an embedded JSON writer, so it needs no
  `jq`, no Python and nothing installed first
- `policies/features.conf`, the single manifest every setting is declared in
- Backup of any existing `policies.json`, restored byte for byte on uninstall
- `tests/run.sh`: manifest invariants, install and restore cycle against a
  temporary root, and checks of every policy key and preference name against
  Firefox's own schema and allowlist
- `install/foxprivacy.ps1` for Windows: the same verbs as PowerShell switches,
  using only the PowerShell that ships with Windows 10 and 11
- `tests/fixtures/`: committed reference policy files that both installers are
  checked against byte for byte, so the two implementations cannot drift
- `tests/run.ps1`, the Windows test suite
- Single file builds via `tools/build-dist.sh`, with the manifest appended to
  the installer, and a documented one line install per platform that downloads
  a file rather than piping into a shell
- `tools/gen-docs.sh` and `tools/gen-fixtures.sh`, generating `docs/POLICIES.md`
  and the fixtures from the manifest
- `tools/github-setup.sh`, applying repository settings and branch protection,
  which changes nothing unless given `--apply`
- `tools/validate-schema.py`, validating a generated policy file against
  Firefox's own schema in full rather than checking top-level names. A mistyped
  sub-property like `GenerativeAI.Chatbots` passes a name check, is ignored by
  Firefox, and surfaces nowhere a user would look
- `.github/workflows/ci.yml`: the suite on Linux, macOS and Windows runners,
  shellcheck, PSScriptAnalyzer, a single file build check, and an Alpine job
  proving the tool runs with only busybox available
- `.github/workflows/release.yml`: builds archives and single file downloads,
  publishes `SHA256SUMS`, and refuses to release if the tag, `VERSION`, both
  installers and the changelog disagree
- Project vision and scope (`docs/VISION.md`)
- Contribution, git, commit, release, and release candidate guides
- MIT license, changelog, and project metadata

### Changed
- Policy keys are validated against the schema inside the installed Firefox
  rather than the gecko-dev mirror. The mirror lags shipped Firefox: 154 has 125
  policies including `GenerativeAI`, `DisableRemoteImprovements` and
  `VisualSearchEnabled`, none of which the mirror knows. Validating against it
  rejected working policies and would have accepted removed ones
- Features now declare `breaks:` as `nothing`, `convenience` or `sites`. The
  rule that nothing site-breaking may sit in the standard profile is derived
  from that, instead of from a hardcoded list of exceptions in the test suite
- The installer parses the manifest once into records instead of re-parsing it
  for every field. Drawing the menu went from 163 processes to 9
- macOS state moved to `/Library/Application Support/FoxPrivacy`, the documented
  location, rather than `/usr/local/var` which belongs to Homebrew
- A release build now prefers its own embedded manifest over any file it happens
  to find nearby, so a downloaded installer always does what its own copy says

### Fixed
- `DisablePocket` was doing nothing. It is still in Firefox 154's schema, so it
  raised no error, but the browser has no implementation for it at all, which is
  why `about:policies` never listed it. Removed. `FirefoxHome.Pocket` and
  `FirefoxHome.Stories` set the same preference, so they were one control wearing
  two names; only the working one remains
- The AI settings were applied as preferences, and one name was wrong: Firefox
  154 reads `browser.tabs.groups.smart.userEnabled`, not
  `browser.tabs.groups.smart.enabled`, so smart tab groups were never disabled.
  Replaced with the `GenerativeAI` policy, which is validated against the schema
  where a preference name is not
- `NetworkPrediction` was credited with stopping link prefetching. It only sets
  the two DNS prefetch preferences, so `network.prefetch-next` is now set too

### Changed
- Shell scripts pass `shellcheck` with no findings at default severity. The
  first run surfaced 27, including `CDPATH= cd` reading as a typo and eighteen
  `A && B || C` chains in the test harness where a surprising `C` would have
  reported the opposite result

### Security
- Installers refuse to remove or overwrite a `policies.json` they did not write,
  and refuse to touch one that changed after they wrote it, unless forced
- A missing checksum tool is fatal rather than silently disabling every
  integrity check
- Release artefacts are published with `SHA256SUMS`, and the documented install
  never pipes a download into a shell
- Directories the installer creates are readable by the user Firefox runs as
  regardless of the caller's umask, at every level it creates, so a restrictive
  umask cannot make Firefox silently ignore the policy file
- A policy directory somebody else created is never chmodded, but the user is
  warned when Firefox will not be able to read through it
- Every preference name is checked against the installed Firefox's own resource
  archives, because Firefox accepts an allowlisted name that no longer exists
  and silently does nothing with it

### Policy changes
- Standard profile: telemetry, studies, automatic crash report submission,
  sponsored shortcuts and stories, Firefox Suggest online and sponsored results,
  Pocket, in-product nags, the terms of use interstitial, feedback commands, the
  Windows default browser agent, AI features, and link prefetching are off.
  Global Privacy Control and Enhanced Tracking Protection are on, unlocked.
- **Search suggestions are off in the standard profile.** Every keystroke in the
  address bar was being sent to the default search engine before submitting, so
  a password typed there by mistake reached the engine. Disabling it costs a
  suggestion dropdown, which is worth far less than what it leaks.
- Standard also stops trending suggestions (which contact the engine the moment
  the address bar is focused), address bar speculative connections, single word
  hostname guessing, and link prefetching. `NetworkPrediction` only sets the two
  DNS prefetch prefs, so `network.prefetch-next` is now set explicitly rather
  than assumed.
- Strict profile adds: no recommended stories, no captive portal detection,
  strict tracking protection, fingerprinting protection, no address or payment
  card autofill, cross site referrer trimming, WebRTC local address hiding, and
  HTTPS only mode.
- App updates, Sync, the password manager, DNS-over-HTTPS, and Encrypted Client
  Hello are deliberately untouched, and a test asserts they stay that way.

[Unreleased]: https://github.com/andreas-glaser/foxprivacy/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/andreas-glaser/foxprivacy/releases/tag/v1.0.0
