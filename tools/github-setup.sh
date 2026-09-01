#!/bin/sh
#
# Applies the repository settings and branch protection this project expects.
#
# Prints what it would do and changes nothing unless you pass --apply. Every
# call is idempotent, so running it twice is safe.
#
# Branches must exist before they can be protected, so push main and dev first.
#
# Needs the gh CLI, authenticated with an account that administers the repo.

set -eu

REPO="${FOXPRIVACY_REPO:-andreas-glaser/foxprivacy}"
APPLY=0

usage() {
  cat <<HELP
Usage: $0 [--apply]

  --apply   actually make the changes. Without it, nothing is changed.

Set FOXPRIVACY_REPO to target a different repository.
HELP
}

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; usage; exit 1 ;;
  esac
  shift
done

command -v gh >/dev/null 2>&1 || { printf 'the gh CLI is required\n' >&2; exit 1; }

run() {
  if [ "$APPLY" = "1" ]; then
    printf '+ %s\n' "$*"
    "$@" >/dev/null
  else
    printf 'would run: %s\n' "$*"
  fi
}

# Job names from .github/workflows/ci.yml. A required check that never reports
# blocks every pull request forever, so these must match the workflow exactly.
CHECKS='"Tests on ubuntu-latest","Tests on macos-latest","Tests on windows-latest","Shellcheck","Runs without jq or python","Single file build"'

printf '== repository settings\n'
run gh repo edit "$REPO" \
  --description "Turn off Firefox telemetry, sponsored content and nagging without breaking Firefox. Official enterprise policies, no dependencies, one command to undo." \
  --homepage "https://github.com/$REPO" \
  --enable-wiki=false \
  --enable-projects=false \
  --enable-issues=true \
  --delete-branch-on-merge=true \
  --add-topic firefox \
  --add-topic privacy \
  --add-topic telemetry \
  --add-topic policies \
  --add-topic hardening \
  --add-topic shell \
  --add-topic powershell \
  --add-topic cross-platform

printf '\n== private vulnerability reporting\n'
# SECURITY.md sends people to the advisory form, so it has to be switched on.
run gh api -X PUT "repos/$REPO/private-vulnerability-reporting"

printf '\n== branch protection: main\n'
# Admins are deliberately not included. The documented release process merges
# dev into main and pushes directly, and enforcing this on admins would break
# it. Force pushes and deletions are blocked for everyone regardless.
main_body=$(cat <<JSON
{
  "required_status_checks": { "strict": true, "contexts": [$CHECKS] },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": true
}
JSON
)
if [ "$APPLY" = "1" ]; then
  printf '%s' "$main_body" | gh api -X PUT "repos/$REPO/branches/main/protection" --input - >/dev/null
  printf '+ protected main\n'
else
  printf 'would PUT repos/%s/branches/main/protection with:\n%s\n' "$REPO" "$main_body"
fi

printf '\n== branch protection: dev\n'
# dev is an integration branch. It must not be force pushed or deleted, but it
# does not need a pull request for every change.
dev_body=$(cat <<JSON
{
  "required_status_checks": { "strict": false, "contexts": [$CHECKS] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false
}
JSON
)
if [ "$APPLY" = "1" ]; then
  printf '%s' "$dev_body" | gh api -X PUT "repos/$REPO/branches/dev/protection" --input - >/dev/null
  printf '+ protected dev\n'
else
  printf 'would PUT repos/%s/branches/dev/protection with:\n%s\n' "$REPO" "$dev_body"
fi

printf '\n'
if [ "$APPLY" = "1" ]; then
  printf 'done. Check the result with:\n'
  printf '  gh api repos/%s/branches/main/protection | less\n' "$REPO"
else
  printf 'Nothing was changed. Re-run with --apply to make these changes.\n'
fi
