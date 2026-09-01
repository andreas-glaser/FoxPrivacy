# Contributing to FoxPrivacy

Thanks for helping. This project configures other people's browsers, so the bar
for a change is "we can show it is safe", not "it looked right".

## Ways to help

- **Report a bug.** Especially an installer that writes to the wrong place, or
  an uninstall that does not restore what was there.
- **Propose a policy change.** Open an issue first, using the policy proposal
  template. Policy changes are the ones that change what a browser does, so they
  get discussed before they get written.
- **Confirm a platform.** Snap and flatpak policy paths, and behaviour after a
  Firefox update, need people testing on real machines. This is genuinely the
  most useful thing an outside contributor can do.
- **Improve the documentation.** If a setting's trade-off is not clear in
  `docs/POLICIES.md`, that is a bug. Edit `policies/features.conf` and run
  `tools/gen-docs.sh`; that page is generated, never edited by hand.

## Before you start

Read [docs/VISION.md](docs/VISION.md), particularly the non-goals. The most
common reason a change gets declined is that it is a good idea for a different
project: this one is not a hardening suite and will not install extensions,
pick a DNS resolver, or break sites for a fingerprinting score.

Two rules decide most policy questions:

1. If a setting has a real usability cost, its `presets:` line says `strict`
   only, never `standard`, and its `cost:` line says what the user loses.
2. If a setting breaks logins, video, or WiFi captive portals, it does not ship
   in the default profile at all.

## Setup

There is nothing to build and no runtime to install.

```bash
git clone git@github.com:andreas-glaser/FoxPrivacy.git
cd FoxPrivacy
git fetch origin dev:dev && git checkout dev
```

The tool itself needs only a POSIX shell and `awk`, which is the point: it has
to run on a stock macOS and a minimal container. Keep it that way.

To run the tests you also need `python3`, used only to inspect JSON. `shellcheck`
lints the scripts and `pwsh` checks the Windows script. Both run in CI if you do
not have them.

## Making a change

```bash
git checkout dev
git pull --rebase origin dev
git checkout -b feature/short-description   # or fix/short-description
```

Branch off `dev` and target `dev` in your PR. Only urgent fixes to released
behaviour go to `main`; see [docs/GIT_GUIDE.md](docs/GIT_GUIDE.md).

Before pushing:

```sh
tests/run.sh
shellcheck install/*.sh tests/*.sh tools/*.sh
```

If you changed `policies/features.conf`, regenerate what is derived from it and
commit the result, or the tests will tell you it is stale:

```sh
tools/gen-docs.sh       # docs/POLICIES.md
tools/gen-fixtures.sh   # tests/fixtures, the bytes both installers must produce
```

The fixture diff is the clearest statement of what your change does to somebody's
browser, so reviewers will read it before anything else.

## If you changed a policy file

Tests prove the file is well formed and that every key exists in Firefox's
schema. They cannot prove Firefox accepted it or that the web still works, so
you have to do that part by hand:

1. Install it into a real Firefox and fully restart the browser.
2. Open `about:policies`. **The Errors tab must be empty.**
3. Check the Active tab lists the policy you added. A policy that is missing
   without an error was probably a typo in a nested key.
4. Browse for a few minutes. Log into something, play a video.
5. Uninstall and confirm the previous state came back.

Put the Firefox version and how it was installed (deb, snap, flatpak, dmg,
Windows installer) in the PR. "Tested and works" without a version number is
not a result anyone can act on.

## Commits

Conventional prefixes, imperative mood, no trailing period. Full list in
[docs/COMMIT_GUIDE.md](docs/COMMIT_GUIDE.md).

```
policy: disable sponsored address bar suggestions
feat: add --verify to the Linux installer
fix: restore the backup when uninstall runs twice
docs: explain the macOS app bundle update caveat
```

`policy:` is specific to this project and marks a change to `policies/*.json`.
Those commits are collected into the changelog's Policy changes section.

Please do not add AI attribution trailers, generated-with footers, or emoji to
commits, PRs, or code. Plain ASCII punctuation.

## Pull requests

- One logical change per PR. A policy change and an installer refactor are two
  PRs.
- Say what you tested and on what. See above.
- New behaviour comes with a test. A bug fix starts with a test that fails
  before the fix.
- Do not silence a check to make it pass. If a check is wrong, fix the check in
  its own commit and say why.

## Code of conduct

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

Contributions are licensed under the [MIT License](LICENSE).
