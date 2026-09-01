## What this changes

<!-- One or two sentences. Link the issue if there is one. -->

## Why

<!-- What problem this solves. For a policy change, what data or nagging it
     removes, and what it costs the user. -->

## How it was tested

<!-- Required. Delete what does not apply. -->

- [ ] `tests/run.sh`
- [ ] `shellcheck install/*.sh tests/*.sh tools/*.sh`

**If this touches `policies/features.conf`, all of the following are required:**

- Firefox version:
- Installed from: <!-- deb / rpm / snap / flatpak / dmg / Windows installer -->
- [ ] Installed into a real Firefox and fully restarted the browser
- [ ] `about:policies` Errors tab is empty
- [ ] `about:policies` Active tab lists the policy this PR adds or changes
- [ ] Browsed normally: a login, a video, the new tab page, the address bar
- [ ] Uninstalled and confirmed the previous state was restored

## Checklist

- [ ] Targets `dev`, not `main` (unless this is a hotfix for released behaviour)
- [ ] Commit messages follow [docs/COMMIT_GUIDE.md](../docs/COMMIT_GUIDE.md)
- [ ] A setting with a usability cost is `presets: strict` only, and its
      `cost:` line says what the user loses
- [ ] `CHANGELOG.md` updated under `[Unreleased]`
- [ ] No check was silenced or weakened to make this pass
