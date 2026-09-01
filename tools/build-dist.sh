#!/bin/sh
#
# Builds the single file distributables in dist/.
#
# The installer normally reads policies/features.conf from the checkout. For
# distribution it has to be one file a person can download and read, so the
# manifest is appended after the marker and the script reads it from its own
# tail. It is appended as comment lines, which keeps the distributed file valid
# shell and valid PowerShell rather than raw text after an exit.
#
# This is why the documented one liner downloads to a file instead of piping
# into a shell: a piped script has no file to read the manifest from.

set -eu

tools_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname "$tools_dir")
out_dir="${1:-$repo_root/dist}"

MANIFEST="$repo_root/policies/features.conf"
SH_SRC="$repo_root/install/foxprivacy.sh"
PS_SRC="$repo_root/install/foxprivacy.ps1"

[ -f "$MANIFEST" ] || { printf 'missing %s\n' "$MANIFEST" >&2; exit 1; }
[ -f "$SH_SRC" ] || { printf 'missing %s\n' "$SH_SRC" >&2; exit 1; }

mkdir -p "$out_dir"

# A source script that already carries a manifest would end up with two.
if grep -q '^#__MANIFEST__$' "$SH_SRC"; then
  printf 'refusing to build: %s already contains a __MANIFEST__ marker\n' "$SH_SRC" >&2
  exit 1
fi

{
  cat "$SH_SRC"
  printf '\n#__MANIFEST__\n'
  sed 's/^/# /' "$MANIFEST"
} > "$out_dir/foxprivacy.sh"
chmod 755 "$out_dir/foxprivacy.sh"
printf 'wrote %s\n' "$out_dir/foxprivacy.sh"

if [ -f "$PS_SRC" ]; then
  if grep -q '^#__MANIFEST__$' "$PS_SRC"; then
    printf 'refusing to build: %s already contains a __MANIFEST__ marker\n' "$PS_SRC" >&2
    exit 1
  fi
  # Same treatment for PowerShell, for the same reason.
  {
    cat "$PS_SRC"
    printf '\n#__MANIFEST__\n'
    sed 's/^/# /' "$MANIFEST"
  } > "$out_dir/foxprivacy.ps1"
  chmod 644 "$out_dir/foxprivacy.ps1"
  printf 'wrote %s\n' "$out_dir/foxprivacy.ps1"
fi
