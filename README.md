# FoxPrivacy

Turn off Firefox's telemetry, sponsored content, and nagging without breaking
Firefox.

FoxPrivacy builds a [Firefox enterprise policy][policies] file from a reviewed
list of settings and puts it where Firefox reads it. It backs up whatever was
there before and removes itself cleanly. Linux, macOS, and Windows, with nothing
to install first.

> **Status: complete, not yet released.** Linux, macOS and Windows installers
> are built and covered by tests. Nothing has been published yet, so the
> download links below do not resolve until the first release is tagged.

## Why policies instead of about:config

Firefox's policy engine is a documented, supported interface with a published
schema. A `user.js` full of preferences is not: preferences get renamed and
removed between releases, and a stale one fails silently. Policies are checked
against Firefox's own schema in this repo's tests, apply to every profile, live
outside the profile directory, and survive a profile reset.

Where no policy exists for something, the `Preferences` policy sets the
preference, so the change is still declared in one auditable file.

## What it turns off

- Telemetry, Shield studies, and automatic crash-report submission
- Sponsored shortcuts, stories, and address bar suggestions
- Firefox Suggest online suggestions and its data upload
- Pocket
- What's New pages, feature and extension recommendations, onboarding nags
- AI chatbot and on-device ML features
- Link prefetching and speculative connections
- The Windows default-browser agent

Enhanced Tracking Protection is turned up, not off, and left unlocked so you can
still make a per-site exception.

## What it deliberately leaves alone

App updates, Firefox Sync, the password manager, DNS-over-HTTPS, and Encrypted
Client Hello. A stale browser is a bigger risk than a telemetry ping, and
picking a DNS resolver is a trust decision that belongs to you.
See [docs/VISION.md](docs/VISION.md#what-is-deliberately-left-alone).

## Install

Nothing to install first. Linux and macOS need only a POSIX shell and `awk`;
Windows needs only the PowerShell that ships with it.

**Linux and macOS**

```sh
curl -fsSLo foxprivacy.sh https://github.com/andreas-glaser/FoxPrivacy/releases/latest/download/foxprivacy.sh && sudo sh foxprivacy.sh
```

**Windows** - right click Windows PowerShell, choose Run as administrator, then:

```powershell
irm https://github.com/andreas-glaser/FoxPrivacy/releases/latest/download/foxprivacy.ps1 -OutFile "$env:TEMP\foxprivacy.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\foxprivacy.ps1"
```

Both download a single file and then run it. Neither pipes anything into a
shell, so you can read exactly what you are about to run before you run it, and
check it against the published `SHA256SUMS`. See [SECURITY.md](SECURITY.md).

Each opens a menu. Press `i` to install, `q` to walk away. Installing needs
`sudo` or an Administrator PowerShell, because the policy file lives in a system
location that every Firefox profile reads.

## Undo it

The same file you downloaded puts everything back:

```sh
sudo sh foxprivacy.sh --uninstall          # Linux and macOS
```
```powershell
& "$env:TEMP\foxprivacy.ps1" -Uninstall   # Windows, as Administrator
```

That restores the `policies.json` that was there before, byte for byte, or
removes the file if there was not one. Nothing else on your system was touched:
FoxPrivacy never edits a Firefox profile.

## Usage

These examples use the repository layout. If you installed with the one liner
above, the script is the `foxprivacy.sh` you downloaded, so run `sh foxprivacy.sh`
in place of `./install/foxprivacy.sh`.

Run it with no arguments and pick what you want from a menu:

```sh
sudo ./install/foxprivacy.sh
```

```
  1 [x] telemetry                  Telemetry and usage data
  2 [x] studies                    Studies and experiments
  ...
 17 [ ] captive-portal             Captive portal detection
        cost: Public WiFi login pages may not open by themselves.

  14 enabled
  number toggle   s standard   t strict   a all   n none
  d details   p preview json   i install   q quit
```

Or drive it directly:

```sh
./install/foxprivacy.sh --list                 # every setting and what it costs
./install/foxprivacy.sh --dry-run              # print the exact json, write nothing
sudo ./install/foxprivacy.sh --profile standard
sudo ./install/foxprivacy.sh --profile strict --disable captive-portal
sudo ./install/foxprivacy.sh --profile standard --enable search-suggestions
./install/foxprivacy.sh --verify               # still installed and unmodified?
sudo ./install/foxprivacy.sh --uninstall       # restore what was there before
```

Windows takes the same verbs as PowerShell switches:

```powershell
.\install\foxprivacy.ps1 -List
.\install\foxprivacy.ps1 -Profile strict -Disable captive-portal
.\install\foxprivacy.ps1 -Verify
.\install\foxprivacy.ps1 -Uninstall
```

Both installers build the identical policy file from the same manifest, and CI
compares them byte for byte against [committed
fixtures](tests/fixtures/standard.json).

Two profiles: **standard** is the default and should be unnoticeable except for
the absent ads. **strict** adds settings with a real cost, each documented next
to the setting in [docs/POLICIES.md](docs/POLICIES.md). Every setting is an
independent toggle, so neither profile is a package deal.

Installing backs up any `policies.json` that was already there, and `--uninstall`
puts it back byte for byte. If the file was changed by something else in the
meantime, uninstall refuses rather than guessing.

## Verifying it worked

Restart Firefox and open `about:policies`. The Errors tab must be empty, and the
Active tab lists what is in effect. This is the only way to see that Firefox
accepted a policy rather than ignoring it.

## Documentation

- [Vision and scope](docs/VISION.md) - what this is, what it will never be
- [What it changes](docs/POLICIES.md) - every setting, its cost, and the policy behind it
- [Contributing](CONTRIBUTING.md) - start here to propose a change
- [Git and branching](docs/GIT_GUIDE.md)
- [Commit conventions](docs/COMMIT_GUIDE.md)
- [Release guide](docs/RELEASE_GUIDE.md) and [release candidates](docs/RELEASE_CANDIDATES.md)
- [Security policy](SECURITY.md)

## License

[MIT](LICENSE)

FoxPrivacy is not affiliated with or endorsed by Mozilla. Firefox is a trademark
of the Mozilla Foundation.

[policies]: https://firefox-admin-docs.mozilla.org/reference/policies/
