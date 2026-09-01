# FoxPrivacy - Vision

## What this is

FoxPrivacy is an open-source, cross-platform configuration tool that turns off
Firefox's data-collection and commercial-content features while leaving Firefox
working exactly like a normal daily browser.

It ships a small set of reviewed Firefox enterprise policy files and thin
installers that place them where Firefox reads them, back up whatever was there
before, and remove themselves cleanly.

It is a configuration project, not an application. There is no daemon, no
background process, no update channel of its own, and nothing running after the
installer exits.

## Who it is for

- People who want a private Firefox without reading a 400-line `user.js` they
  cannot evaluate.
- Admins who want the same reviewed baseline on Linux, macOS, and Windows.
- Anyone who wants to see exactly what was changed and undo it in one command.

Linux is the primary platform. macOS and Windows are first-class targets, not
afterthoughts, but Linux is where the project is developed and tested first.

## Principles

1. **Official policies before `about:config`.** Firefox's enterprise policy
   engine is a documented, versioned, supported interface. Every setting is
   checked against Firefox's own `policies-schema.json`; an invented policy key
   is silently ignored by Firefox, which is the worst possible failure mode.
   Where no policy exists, the `Preferences` policy sets the pref, so the change
   is still declared in one auditable file rather than sprayed into a profile.

2. **Never touch the user profile.** No `user.js`, no `prefs.js` edits, no
   profile directory scanning. Profiles are the user's data. Policies live
   outside them, apply to every profile, and survive profile resets.

3. **Usable Firefox is a requirement, not a preference.** A setting that breaks
   logins, video, captive-portal WiFi, or password autofill does not go in the
   default profile no matter how good it looks in a privacy checklist. If a
   setting has a real cost, it goes in the strict profile with the cost written
   down next to it.

4. **Reversible by construction.** Every install writes a timestamped backup of
   whatever it replaced. Uninstall restores that backup, or removes the file if
   there was nothing to restore. The tool must be able to leave the machine in
   the state it found it.

5. **Explain every setting.** Each policy in the shipped configuration has a
   documented reason and, where relevant, a documented trade-off. A privacy tool
   that asks for trust without giving reasons is just a different opaque vendor.

6. **No runtime dependencies.** POSIX shell and `awk` on Linux and macOS,
   built-in PowerShell on Windows. No `jq`, no Python, no package manager, no
   vendored binaries. This is a hard constraint, not a preference: a tool that
   needs Homebrew before it can run has already lost the people it is for.
   FoxPrivacy never parses JSON, it only writes it, so it carries a small JSON
   writer instead of a parser dependency.

7. **Dry run first.** Every installer supports `--dry-run` and prints exactly
   which file it would write, where, and what it would back up.

## Non-goals

- **Not a hardening suite.** No `arkenfox`-style fingerprinting-resistance
  overhaul, no RFP, no cipher-suite surgery. Those break sites and belong to a
  different project with a different audience.
- **Not a Firefox fork or a patched build.** Stock Firefox, stock update
  channel.
- **Not an extension manager.** FoxPrivacy will not install uBlock Origin or any
  other add-on on the user's behalf. It may document them.
- **Not a network tool.** No DNS provider is chosen for the user, no proxy is
  configured, no VPN integration. DNS-over-HTTPS is deliberately left untouched
  because picking a resolver is a trust decision the user owns.
- **Not a telemetry-free guarantee.** The tool disables what Firefox exposes as
  disableable. It does not claim to make Firefox silent on the network.

## What gets turned off

Grouped by what the user actually experiences. Every item maps to a policy in
Firefox's schema or to a pref set through the `Preferences` policy.

**Telemetry and studies**
- Usage and health telemetry (`DisableTelemetry`).
- Shield / Normandy studies and remote experiments (`DisableFirefoxStudies`).
- Automatic crash-report submission. Firefox has no policy for this, so it is
  handled through the `Preferences` policy; the crash reporter itself is left
  installed, only the automatic sending is turned off.

**Sponsored and commercial content**
- Sponsored shortcuts, sponsored stories, and the recommendation panes on the
  new tab page (`FirefoxHome`, `NewTabPage`).
- Sponsored and online address-bar suggestions, and the "improve suggestions"
  data upload (`FirefoxSuggest`).
- Pocket (`DisablePocket`).

**Nagging and in-product messaging**
- What's New pages, feature and extension recommendations, address-bar
  interventions, "More from Mozilla", onboarding tours (`UserMessaging`).
- The terms-of-use / data-preferences interstitial (`SkipTermsOfUse`).
- Feedback and "report deceptive site" menu commands, which post data to Mozilla
  (`DisableFeedbackCommands`).
- The Windows default-browser agent, a scheduled task that reports back
  (`DisableDefaultBrowserAgent`).

**AI features**
- The AI chatbot sidebar, link previews, and on-device ML features, off by
  default via the `browser.ml.*` prefs. No policy exists for these yet; if
  Mozilla adds one, the configuration moves to it.

**Speculative network activity**
- Link prefetching and speculative connections (`NetworkPrediction`).

**Tracking protection (turned up, not off)**
- Enhanced Tracking Protection stays on with cryptomining, fingerprinting, and
  email-tracker blocking enabled (`EnableTrackingProtection`). Not locked, so
  the user can still make a per-site exception when a site breaks.

## What is deliberately left alone

These are the decisions most privacy scripts get wrong, so they are written down
as explicit choices rather than omissions:

- **App updates.** Never disabled. A stale browser is a bigger risk than any
  telemetry ping.
- **Firefox Accounts and Sync.** Left available. Turning it off breaks a feature
  people rely on, and it is opt-in already.
- **The password manager and form autofill.** Left available.
- **DNS-over-HTTPS.** Untouched, see non-goals.
- **Encrypted Client Hello and post-quantum key agreement.** Left on. They are
  privacy wins; several hardening guides disable them by mistake.
- **Search suggestions and captive-portal detection.** Left on in the default
  profile because disabling them breaks a search box and a coffee-shop WiFi
  login respectively. Both are off in the strict profile.

## Two profiles

**standard** is the default and the recommended one. Nothing in it should be
noticeable except the absence of ads and nags. If a standard-profile setting
makes an ordinary website misbehave, that is a bug.

**strict** adds settings with a real, documented usability cost: no search
suggestions, no captive-portal probing, strict-category tracking protection,
resist-fingerprinting-adjacent behaviour where it does not break layout.
Choosing strict means accepting that some sites will need an exception.

Both profiles are selections from one manifest, `policies/features.conf`, which
holds every setting FoxPrivacy knows about as data: an id, what it does, what it
costs, which profiles include it, and the policy or preference behind it. The
installer builds `policies.json` by merging the features you enabled.

That manifest is the only place where what-ships is decided. The interactive
menu, the `--enable`/`--disable` flags, the test suite, and `docs/POLICIES.md`
all read it, so a setting cannot be documented one way and shipped another.

The cost of generating rather than committing the finished file is that you
cannot diff the repo against your machine directly. `--dry-run` prints the exact
bytes that would be written, and `--verify` reports whether the installed file
is still the one FoxPrivacy wrote.

## Platform strategy

| Platform | Target | Survives a Firefox update |
|---|---|---|
| Linux (system package) | `/etc/firefox/policies/policies.json` | Yes |
| Linux (snap, flatpak) | The same path, with a warning that it is unconfirmed | Yes, if it is read at all |
| macOS | `/Applications/Firefox.app/Contents/Resources/distribution/policies.json` | No, a full app update replaces the bundle |
| Windows | `Mozilla Firefox\distribution\policies.json`, under whichever Program Files directory actually holds `firefox.exe` | Usually, but not guaranteed |

Each installer also keeps a small record of what it wrote, its checksum, and the
path of any backup it displaced. It sits beside the policy file as
`.foxprivacy-state`, which matters more than it sounds: writing the record then
needs exactly the same permission as writing the policy file, so uninstalling
can never demand more privilege than installing did. On macOS that is the
difference between needing `sudo` and not, because application bundles usually
belong to the user who installed them. Uninstall reads it, and without it the
tool will not touch a policy file it cannot prove it wrote.

Linux is the clean case: `/etc/firefox/policies/` is outside the install tree,
so nothing that updates Firefox can remove it. macOS and Windows put the file
inside the application, which is what Mozilla documents, but means an update can
wipe it. The tool's answer to that is honesty plus a cheap check: a `--verify`
mode that reports whether the configuration is still in place, so re-running the
installer after a major update is a five-second decision rather than a
discovery six months later.

A registry-based Windows install (`HKLM\SOFTWARE\Policies\Mozilla\Firefox`)
survives updates and stays on the table as a later addition. It is not in the
first version because it needs a JSON-to-registry mapping, a different uninstall
path, and its own tests, and the file-based install is the same shared
configuration on all three platforms.

## Shape of the repository

```
policies/
  features.conf      every setting as data: what, why, what it costs
install/
  foxprivacy.sh      Linux and macOS, POSIX shell and awk only
  foxprivacy.ps1     Windows, built-in PowerShell only
tools/
  gen-docs.sh        writes docs/POLICIES.md from the manifest
  gen-fixtures.sh    writes the reference policy files in tests/fixtures
  build-dist.sh      appends the manifest to each installer for release
  github-setup.sh    repository settings and branch protection
docs/
  VISION.md          this file
  POLICIES.md        generated: every setting, what it does, what it costs
tests/
  run.sh             manifest invariants, Firefox schema check, install cycle
  run.ps1            the same on Windows
  fixtures/          the exact bytes both installers must produce
```

The installers are deliberately dumb. They read the manifest, merge, validate,
back up, copy, and report. All the judgement lives in the manifest, where it can
be reviewed as data instead of as control flow.

Two implementations of the same thing is a risk, so it is pinned down rather
than trusted: both build the same policy file from the same manifest, and both
are checked against the committed fixtures. If they ever disagree by a single
byte, CI fails.

## Verification

A configuration tool that cannot be checked is a configuration tool that cannot
be trusted. Three levels, all documented:

1. `foxprivacy --verify` compares the installed file against the shipped one and
   reports which profile is active, or that none is.
2. `about:policies` in Firefox shows the active policies and, on the Errors tab,
   anything Firefox rejected. An empty Errors tab is the pass condition.
3. `about:support` and `about:config` for spot-checking individual prefs the
   `Preferences` policy set.

Tests run the installer against a temporary root, so install, backup, re-install,
uninstall, and restore are covered without touching a real Firefox. Every policy
key in the shipped files is checked against Firefox's own schema, which is the
check that catches the failure mode that matters most.

## Roadmap

**v1.0 - all three platforms**
Feature manifest with standard and strict profiles. `foxprivacy.sh` for Linux
and macOS and `foxprivacy.ps1` for Windows, both with an interactive menu,
install, uninstall, verify, dry run, and backup, both building byte identical
policy files checked against committed fixtures. No runtime dependencies on any
platform. CI on Linux, macOS, Windows and bare Alpine. Single file builds, a
release workflow publishing checksums, and a documented one line install that
downloads a file rather than piping into a shell.

**Later, if it earns its place**
Windows registry mode. Snap and flatpak targets once their policy paths are
confirmed by testing rather than by blog post. A `--diff` that shows what an
install would change against what is already there.

## Risks and open questions

- **macOS has no route outside the application bundle.** Firefox does have a
  macOS policies provider that reads the `org.mozilla.firefox` preference
  domain, which looks like the answer: it would survive Firefox updates and
  sidestep App Management entirely. It does not work on a machine without MDM.
  Tested on macOS 26.6.2: a plist in `/Library/Preferences` is not visible to
  the app's domain at all, and one hand-placed in `/Library/Managed Preferences`
  is still not honoured after restarting `cfprefsd`. Forced values have to come
  from a real installed configuration profile. Until FoxPrivacy ships a
  `.mobileconfig`, which needs manual approval and so is not obviously better,
  the app bundle is the only route, and App Management is a permission the user
  grants once.
- **Snap and flatpak policy paths.** These need to be confirmed by installing and
  reading `about:policies`, not assumed. The installer detects both, writes to
  the system location anyway, and warns that whether that build reads it is
  unconfirmed. Refusing outright was the original plan, but it would block the
  people best placed to answer the question from testing at all.
- **The `Preferences` policy restricts which prefs it will set.** The crash
  reporter and `browser.ml.*` settings depend on that allowlist. Each one has to
  be verified in a running Firefox, and any that Firefox rejects has to be
  documented as unsupported rather than left in the file looking effective.
- **Policies win over the UI.** A setting Firefox reports as "managed by your
  organization" can confuse a user who forgot they installed this. Locking is
  therefore used sparingly, and the uninstall path has to be genuinely easy.
- **Firefox changes.** Policies get added, renamed, and removed between releases.
  The schema check is the early-warning system; it should run in CI against the
  current Firefox schema, not a vendored copy that quietly goes stale.
