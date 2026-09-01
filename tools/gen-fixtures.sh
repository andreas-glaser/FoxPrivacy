#!/bin/sh
#
# Writes the reference policy files in tests/fixtures/.
#
# These are the exact bytes both installers must produce. Committing them means
# a change to the manifest shows up in review as a diff of what the browser will
# actually be told to do, and it gives the Windows installer something to be
# checked against without needing a Linux machine in the same job.
#
# Run after changing the manifest. tests/run.sh fails if these are stale.

set -eu

tools_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname "$tools_dir")
out_dir="${1:-$repo_root/tests/fixtures}"

mkdir -p "$out_dir"
for preset in standard strict; do
  "$repo_root/install/foxprivacy.sh" --profile "$preset" --dry-run |
    sed -n '/^{/,$p' > "$out_dir/$preset.json"
  printf 'wrote %s\n' "$out_dir/$preset.json"
done
