#!/usr/bin/env python3
"""Check that the documentation still describes the project as it is.

Prose drifts silently: a feature is renamed, a file is moved, a preference is
replaced by a policy, and the docs keep asserting the old thing. Nothing fails,
the README simply becomes untrue.

This checks the claims that can be checked mechanically:

  - a backticked feature id must exist in the manifest
  - a backticked repository path must exist
  - a backticked preference must be one the manifest actually sets
  - every feature in the standard profile must be mentioned in the README

Dependency free. Exits non-zero on any drift.
"""

import os
import pathlib
import re
import subprocess
import sys

# Prose legitimately describes history, including settings that were removed.
HISTORY = {"CHANGELOG.md"}

# Words that look like feature ids but are not.
NOT_IDS = {
    "cross-platform", "enterprise-policies", "no-dependencies", "dry-run",
    "settings-only", "protection-only", "fail-fast", "timeout-minutes",
    "macos-latest", "ubuntu-latest", "windows-latest", "runs-on", "set-url",
    "single-file", "check-ignore", "byte-for-byte", "no-ff", "read-only",
    "pre-release", "user-js", "about-config", "commit-guide", "release-guide",
}

# Runtime paths that are not files in this repository.
RUNTIME_FILES = {
    "policies.json", "user.js", "prefs.js", "omni.ja", "SHA256SUMS",
    "policies-schema.json", "Policies.sys.mjs", "manifest.json", "const.py",
    "hacs.json", "sshd_config", "state.json",
}


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    os.chdir(root)

    tracked = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True, check=True
    ).stdout.split()
    texts = {
        f: pathlib.Path(f).read_text()
        for f in tracked
        if f.endswith((".md", ".yml", ".conf", ".sh", ".ps1", ".py"))
        and pathlib.Path(f).is_file()
    }

    manifest = pathlib.Path("policies/features.conf").read_text()
    ids = set(re.findall(r"^feature: (\S+)", manifest, re.M))
    prefs = set(re.findall(r"^pref: (\S+)", manifest, re.M))

    basenames = {os.path.basename(f) for f in tracked}
    problems = []

    for name, body in texts.items():
        if name == "policies/features.conf":
            continue

        for token in re.findall(r"`([a-z][a-z0-9]*(?:-[a-z0-9]+)+)`", body):
            if token in ids or token in NOT_IDS or "." in token or "/" in token:
                continue
            problems.append(f"{name}: `{token}` reads as a feature id but is not one")

        for token in re.findall(
            r"`([A-Za-z0-9_./-]+\.(?:sh|ps1|py|json|conf|md|yml))`", body
        ):
            if token.startswith(("/", "~", "http")):
                continue
            candidate = token[2:] if token.startswith("./") else token
            if os.path.exists(candidate):
                continue
            if os.path.basename(candidate) in RUNTIME_FILES:
                continue
            if os.path.exists(os.path.join(os.path.dirname(name), candidate)):
                continue
            # Docs refer to install/foxprivacy.sh by its bare name too.
            if os.path.basename(candidate) in basenames:
                continue
            problems.append(f"{name}: `{token}` does not exist")

        if name in HISTORY:
            continue
        for token in re.findall(
            r"`((?:browser|privacy|network|media|toolkit|datareporting)\."
            r"[A-Za-z0-9._-]+)`",
            body,
        ):
            if token not in prefs:
                problems.append(
                    f"{name}: `{token}` is described as set, but the manifest does not set it"
                )

    # Every setting the default profile applies should be findable in the README,
    # or people are running something the front page never mentioned.
    readme = texts.get("README.md", "").lower()
    standard, current, names = [], None, {}
    for line in manifest.split("\n"):
        if line.startswith("feature: "):
            current = line.split(": ", 1)[1]
        elif line.startswith("name: ") and current:
            names[current] = line.split(": ", 1)[1]
        elif line.startswith("presets: ") and "standard" in line:
            standard.append(current)

    # A feature counts as mentioned if any distinctive word from its id or its
    # human name appears. The README should read as prose, not as a list of ids.
    for feature in standard:
        words = [w for w in feature.split("-") if len(w) > 3]
        words += [w.strip(",.").lower() for w in names.get(feature, "").split() if len(w) > 4]
        if not any(w in readme for w in words):
            problems.append(
                f"README.md: the standard profile includes {feature}"
                f" ({names.get(feature, '')}), and the README never mentions it"
            )

    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
