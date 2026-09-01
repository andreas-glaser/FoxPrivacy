# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries under **Policy changes** come first in every release. They are the ones
that change what a browser does after an install, and they are why most people
read this file. See [docs/GIT_GUIDE.md](docs/GIT_GUIDE.md) for what counts as a
major, minor, or patch change in a configuration tool.

## [Unreleased]

### Fixed
- The installer told macOS users to re-run with `sudo` when they already had.
  It now prints the underlying error, and when it is already running as root it
  explains what is actually refusing the write

### Fixed
- The Windows installer had the same half-install defect as the shell one, and
  now undoes the write if the record cannot be saved
- A record that could not be parsed was treated as an empty one. Uninstall
  reported `OK removed` for the empty string, exited successfully, and deleted
  the record, which would orphan whatever was actually installed. Both
  installers now refuse to act on a record they cannot understand, and leave it
  in place
- Uninstall checks it can write the record before removing the policy file,
  rather than discovering it afterwards
- An install could write the policy file and then fail to record itself, leaving
  a machine with a policy file the tool would not remove because it could not
  prove it wrote it. Found on a real Mac, where the application bundle was
  writable but `/Library/Application Support` was not. The install is now undone
  if the record cannot be written, restoring any file it replaced, and both
  directories are checked before anything is written

### Changed
- Files created while running as root now match the ownership of the directory
  they are created in. Installing once with `sudo` used to leave a root owned
  directory inside an application bundle that belongs to you, which made `sudo`
  permanent. Matching the parent grants nothing new: whoever owns it can already
  replace anything inside it
- The README no longer carries a version status banner, which went stale on
  every fix. The macOS and Windows update caveat now sits with the verification
  instructions, where it is relevant
- The record of what was installed now sits beside the policy file as
  `.foxprivacy-state`, rather than in a separate system directory. Writing it
  then needs exactly the same permission as writing the policy file, so an
  install can no longer half succeed, and on macOS it removes the need for
  `sudo` entirely when the application bundle belongs to you. Records written by
  1.0.0 are still read, so those installs remain verifiable and removable
- The interactive menu checks it can write to the target before it opens, so a
  macOS permission problem is reported immediately rather than after twenty
  settings have been chosen. The probe removes anything it created

### Known issues
- **Installing on macOS from Terminal needs a one-time permission.** macOS App Management refuses to
  let one program modify another application's bundle, even as root, and the
  policy file lives inside `Firefox.app`. The refusal depends on which program
  asks, not which user you are: the same command succeeds over ssh. Work around
  Grant your terminal App Management in System Settings, Privacy and Security,
  or run the installer over ssh. Writing to the `org.mozilla.firefox` preference
  domain instead was built and tested on macOS 26, and does not work without an
  installed configuration profile, so the app bundle remains the only route

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
- `foxprivacy.ps1 -Profile standard` opened the interactive menu instead of
  installing, and then waited on `Read-Host` forever. That is the command the
  README tells Windows users to run, and it hung a CI job for thirteen minutes
  before anything noticed. `-Profile` is an alias for `-ProfileName`, and the
  binder did not record it under the parameter's own name, so the argument check
  concluded there were no arguments. It now decides on the value, not on how the
  binder recorded it
- The menu refuses to start when there is no terminal attached, rather than
  blocking on input that can never arrive
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
- The README described a profile that no longer existed: it omitted search
  suggestions entirely, which is the most consequential setting in the project,
  and still advertised Pocket, which was removed. `tools/check-drift.py` now
  fails the build when the documentation stops describing what ships
- Every CI job has a timeout, so a hang fails in minutes rather than sitting for
  the six hour default
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

[Unreleased]: https://github.com/andreas-glaser/FoxPrivacy/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/andreas-glaser/FoxPrivacy/releases/tag/v1.0.0
