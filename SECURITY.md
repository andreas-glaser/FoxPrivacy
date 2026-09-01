# Security Policy

## Reporting a vulnerability

Please report privately, not in a public issue.

Use [GitHub private vulnerability reporting][gh-report] on this repository, or
email the maintainer at the address on their GitHub profile.

Expect an acknowledgement within a week. If a fix is needed, it ships as a
hotfix release from `main` rather than waiting for the next feature release,
and the changelog says what was wrong.

## What is in scope

This project writes a configuration file into a privileged location, so the
things that matter here are:

- The installer writing outside its declared target path.
- The installer running with more privilege than it needs, or being coaxed into
  it by a crafted path or environment.
- Uninstall failing to restore what was replaced, or destroying a backup.
- A shipped policy that weakens Firefox's security posture: disabling updates,
  loosening TLS, disabling Encrypted Client Hello, or turning off tracking
  protection. Report these as vulnerabilities, not as bugs.
- A release artifact that does not match its published checksum.

## What is not in scope

- Firefox itself. Report those to [Mozilla][moz-security].
- A privacy setting you think should also be disabled. That is a policy
  proposal, so please open a normal issue.
- The fact that policies do not make Firefox silent on the network. That is
  stated as a non-goal in [docs/VISION.md](docs/VISION.md); it is a limitation,
  not a vulnerability.

## Verifying a release

Every release publishes `SHA256SUMS` alongside its archives. Check it before
running anything:

```sh
sha256sum -c SHA256SUMS      # shasum -a 256 -c SHA256SUMS on macOS
```

This project asks to be trusted with a browser configuration, so the documented
install commands **download a file and then run it**. Nothing is ever piped into
a shell. The difference matters: a downloaded file can be read before it runs,
checked against the checksum above, and inspected afterwards to see what you
actually executed. A piped script cannot be any of those things, and the server
can serve different bytes to `curl` than it shows in a browser.

There is no `curl | sh` install command for FoxPrivacy and there will not be
one.

[gh-report]: https://github.com/andreas-glaser/foxprivacy/security/advisories/new
[moz-security]: https://www.mozilla.org/security/
