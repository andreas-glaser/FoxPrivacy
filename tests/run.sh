#!/bin/sh
#
# FoxPrivacy test suite.
#
# Needs python3 for JSON inspection. The tool under test needs neither python
# nor jq; that is the point, and there is a test below that proves it.
#
# The two schema checks reach Firefox's source over the network and skip loudly
# when offline, so a green offline run proves less than a green online one.

set -u

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname "$test_dir")
INSTALLER="$repo_root/install/foxprivacy.sh"
MANIFEST="$repo_root/policies/features.conf"

SCHEMA_URL="https://raw.githubusercontent.com/mozilla/gecko-dev/master/browser/components/enterprisepolicies/schemas/policies-schema.json"
POLICIES_URL="https://raw.githubusercontent.com/mozilla/gecko-dev/master/browser/components/enterprisepolicies/Policies.sys.mjs"

pass=0; fail=0; skip=0
export NO_COLOR=1

ok()      { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
not_ok()  { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; return 0; }
skipped() { skip=$((skip + 1)); printf 'skip %s\n' "$1"; [ $# -gt 1 ] && printf '     %s\n' "$2"; return 0; }
check()   { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "expected [$2] got [$3]"; fi; }
section() { printf '\n== %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { printf 'python3 is required to run the tests\n' >&2; exit 1; }

# Reads a dotted path out of a JSON document on stdin. Prints null when absent.
jget() {
  python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception as e:
    print("INVALID JSON: %s" % e); sys.exit(0)
for k in sys.argv[1].split("."):
    if isinstance(d, dict) and k in d:
        d = d[k]
    else:
        print("null"); sys.exit(0)
print(d if isinstance(d, str) else json.dumps(d))
' "$1"
}

is_json() { python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; }

# macOS has shasum and BSD stat; Linux has sha256sum and GNU stat. The CI matrix
# runs this suite on both, so nothing here may assume one of them.
sum256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

file_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

# --------------------------------------------------------------- manifest ----

section "manifest"

if [ -f "$MANIFEST" ]; then ok "features.conf exists"; else not_ok "features.conf exists"; fi

ids=$(sed -n 's/^feature: //p' "$MANIFEST")
check "feature ids are unique" "" "$(printf '%s\n' "$ids" | sort | uniq -d | tr '\n' ' ' | sed 's/ $//')"
check "feature ids are lowercase, digits and hyphens" "" \
  "$(printf '%s\n' "$ids" | grep -vE '^[a-z0-9-]+$' | tr '\n' ' ' | sed 's/ $//')"

# Every block must carry the fields the menu and the docs depend on.
check "every feature has name, summary and presets" "" "$(awk '
  function flush() { if (cur != "") { if (!(cur in hasname) || !(cur in hassum) || !(cur in haspre)) printf "%s ", cur } }
  /^[ \t]*#/ { next }
  { ci = index($0, ":"); if (ci == 0) next
    k = substr($0, 1, ci - 1); v = substr($0, ci + 1); sub(/^[ \t]+/, "", v)
    if (k == "feature") { flush(); cur = v; next }
    if (k == "name" && v != "") hasname[cur] = 1
    if (k == "summary" && v != "") hassum[cur] = 1
    if (k == "presets" && v != "") haspre[cur] = 1 }
  END { flush() }' "$MANIFEST" | sed 's/ $//')"

check "presets are only standard or strict" "" \
  "$(sed -n 's/^presets: //p' "$MANIFEST" | tr ' ' '\n' | sort -u | grep -vxE 'standard|strict' | tr '\n' ' ' | sed 's/ $//')"

check "preference statuses are valid" "" \
  "$(sed -n 's/^pref: [^ ]* = [^ ]* //p' "$MANIFEST" | sort -u | grep -vxE 'default|locked|user|clear' | tr '\n' ' ' | sed 's/ $//')"

# Preferences must arrive through pref: lines. A policy: line naming Preferences
# would bypass the merge and silently drop every other preference.
check "no policy line smuggles in Preferences" "" \
  "$(grep -c '^policy: Preferences' "$MANIFEST" | grep -v '^0$' || printf '')"

check "policy keys nest at most two deep" "" \
  "$(sed -n 's/^policy: \([^ ]*\) =.*/\1/p' "$MANIFEST" | grep -E '\..*\.' | tr '\n' ' ' | sed 's/ $//')"

check "no value contains a quote or backslash" "" \
  "$(grep -nE '^(policy|pref): .*["\\]' "$MANIFEST" | tr '\n' ' ' | sed 's/ $//')"

# strict is meant to be standard plus more, so nothing may be standard-only.
check "strict includes everything standard has" "" "$(awk '
  /^[ \t]*#/ { next }
  { ci = index($0, ":"); if (ci == 0) next
    k = substr($0, 1, ci - 1); v = substr($0, ci + 1); sub(/^[ \t]+/, "", v)
    if (k == "feature") { cur = v; next }
    if (k != "presets") next
    s = 0; t = 0; n = split(v, p, " ")
    for (i = 1; i <= n; i++) { if (p[i] == "standard") s = 1; if (p[i] == "strict") t = 1 }
    if (s && !t) printf "%s ", cur }' "$MANIFEST" | sed 's/ $//')"

check "every feature declares a valid breaks value" "" "$(awk '
  /^[ \t]*#/ { next }
  { ci = index($0, ":"); if (ci == 0) next
    k = substr($0, 1, ci - 1); v = substr($0, ci + 1); sub(/^[ \t]+/, "", v)
    if (k == "feature") { cur = v; seen = 0; next }
    if (k != "breaks") next
    seen = 1
    if (v != "nothing" && v != "convenience" && v != "sites") printf "%s ", cur }
  ' "$MANIFEST" | sed 's/ $//')"

check "every feature has a breaks line" "" "$(awk '
  function flush() { if (cur != "" && !has) printf "%s ", cur }
  /^[ \t]*#/ { next }
  { ci = index($0, ":"); if (ci == 0) next
    k = substr($0, 1, ci - 1)
    if (k == "feature") { flush(); cur = substr($0, ci + 2); has = 0; next }
    if (k == "breaks") has = 1 }
  END { flush() }' "$MANIFEST" | sed 's/ $//')"

# A free lunch and a stated cost are contradictory claims about the same thing.
check "breaks nothing and an empty cost agree" "" "$(awk '
  /^[ \t]*#/ { next }
  { ci = index($0, ":"); if (ci == 0) next
    k = substr($0, 1, ci - 1); v = substr($0, ci + 1); sub(/^[ \t]+/, "", v)
    if (k == "feature") { cur = v; cost = ""; next }
    if (k == "cost") { cost = v; next }
    if (k != "breaks") next
    if ((v == "nothing") != (cost == "")) printf "%s ", cur }
  ' "$MANIFEST" | sed 's/ $//')"

# The rule the project exists to keep: nothing that breaks a website may sit in
# the profile people install without reading anything. Losing a convenience is
# allowed there when the privacy it buys is worth more, which is a judgement
# recorded per feature rather than a list of exceptions kept in this file.
check "nothing that breaks websites is in the standard profile" "" "$(awk '
  /^[ \t]*#/ { next }
  { ci = index($0, ":"); if (ci == 0) next
    k = substr($0, 1, ci - 1); v = substr($0, ci + 1); sub(/^[ \t]+/, "", v)
    if (k == "feature") { cur = v; brk = ""; next }
    if (k == "breaks") { brk = v; next }
    if (k != "presets") next
    if (brk != "sites") next
    n = split(v, p, " ")
    for (i = 1; i <= n; i++) if (p[i] == "standard") printf "%s ", cur }
  ' "$MANIFEST" | sed 's/ $//')"

# The whole point of the search-suggestions decision: this must stay on by
# default, because it is the setting that stops what you type reaching a third
# party before you press Enter.
check "search suggestions are disabled by default" "false" \
  "$(printf '%s' "$("$INSTALLER" --profile standard --dry-run | sed -n '/^{/,$p')" |
     jget policies.SearchSuggestEnabled)"

# ----------------------------------------------------------- firefox schema ----

section "firefox schema"

# The schema shipped inside the installed browser is the only authority on what
# that browser accepts. The gecko-dev mirror lags it: Firefox 154 ships policies
# the mirror has never heard of, so validating against the mirror rejects
# policies that work and would accept ones that no longer do. Prefer local,
# fall back to the network only when no Firefox is installed.
firefox_dir=$(
  for d in /usr/lib/firefox /usr/lib64/firefox /opt/firefox /usr/lib/firefox-esr \
           "${FOXPRIVACY_FIREFOX_DIR:-}" /Applications/Firefox.app/Contents/Resources; do
    [ -n "$d" ] && [ -f "$d/omni.ja" ] && { printf '%s' "$d"; break; }
  done
)

tmp_schema=$(mktemp)
schema_source=""
# unzip exits 2 on omni.ja ("extra bytes at beginning") while still extracting
# the member correctly, so judge the output, not the exit code.
if [ -n "$firefox_dir" ] && command -v unzip >/dev/null 2>&1; then
  unzip -p "$firefox_dir/browser/omni.ja" modules/policies/policies-schema.json \
    > "$tmp_schema" 2>/dev/null || true
fi
if [ -s "$tmp_schema" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
     "$tmp_schema" 2>/dev/null; then
  schema_source="the installed Firefox"
elif curl -fsS --max-time 20 -o "$tmp_schema" "$SCHEMA_URL" 2>/dev/null; then
  schema_source="the gecko-dev mirror, which may lag your Firefox"
fi

if [ -n "$schema_source" ]; then
  printf '     schema from: %s\n' "$schema_source"
  used=$(sed -n 's/^policy: \([^ .]*\).*/\1/p' "$MANIFEST" | sort -u)
  bad=$(printf '%s\n' "$used" | python3 -c '
import json, sys
known = set(json.load(open(sys.argv[1]))["properties"])
print(" ".join(k for k in sys.stdin.read().split() if k not in known))
' "$tmp_schema")
  check "every policy key exists in Firefox's schema" "" "$bad"

  # A key check only sees the top level. A mistyped sub-property such as
  # GenerativeAI.Chatbots passes it, is ignored by Firefox, and appears nowhere
  # a user would look. Validate the whole generated document instead.
  for preset in standard strict; do
    generated=$(mktemp)
    "$INSTALLER" --profile "$preset" --dry-run | sed -n '/^{/,$p' > "$generated"
    problems=$("$repo_root/tools/validate-schema.py" "$tmp_schema" "$generated" 2>&1)
    if [ -z "$problems" ]; then
      ok "$preset validates against Firefox's schema in full"
    else
      not_ok "$preset validates against Firefox's schema in full" "$problems"
    fi
    rm -f "$generated"
  done
else
  skipped "every policy key exists in Firefox's schema" "no local schema and no network"
  skipped "profiles validate against Firefox's schema in full" "no schema available"
fi
rm -f "$tmp_schema"

tmp_pol=$(mktemp)
if curl -fsS --max-time 20 -o "$tmp_pol" "$POLICIES_URL" 2>/dev/null; then
  prefixes=$(sed -n '/let allowedPrefixes = \[/,/\];/p' "$tmp_pol" | grep -o '"[^"]*"' | tr -d '"')
  if [ -z "$prefixes" ]; then
    skipped "every preference is on Firefox's allowlist" "could not parse allowedPrefixes"
  else
    bad=""
    # shellcheck disable=SC2013  # preference names never contain whitespace
    for p in $(sed -n 's/^pref: \([^ ]*\) =.*/\1/p' "$MANIFEST" | sort -u); do
      matched=0
      for prefix in $prefixes; do
        case "$p" in "$prefix"*) matched=1; break ;; esac
      done
      [ "$matched" = "1" ] || bad="${bad:+$bad }$p"
    done
    check "every preference is on Firefox's allowlist" "" "$bad"
  fi
else
  skipped "every preference is on Firefox's allowlist" "could not fetch Policies.sys.mjs"
fi
rm -f "$tmp_pol"

# ------------------------------------------------- preferences vs firefox ----

section "preferences against the installed Firefox"

# The schema check above proves policy keys are real. Nothing proves a
# preference name is real: Firefox accepts any allowlisted name and silently
# does nothing with one that no longer exists.
#
# Firefox keeps pref names in two places: omni.ja for anything defined in JS,
# and the libxul binary for compiled-in static prefs. Searching both catches a
# typo or a removed pref. It cannot prove absence, though, because some names
# are assembled at build time and appear in neither, so a name that is not
# found is reported rather than failed.
firefox_dir=$(
  for d in /usr/lib/firefox /usr/lib64/firefox /opt/firefox /usr/lib/firefox-esr \
           "${FOXPRIVACY_FIREFOX_DIR:-}" /Applications/Firefox.app/Contents/Resources; do
    [ -n "$d" ] && [ -f "$d/omni.ja" ] && { printf '%s' "$d"; break; }
  done
)

if [ -z "$firefox_dir" ]; then
  skipped "every preference is known to the installed Firefox" "no Firefox installation found"
elif ! command -v unzip >/dev/null 2>&1; then
  skipped "every preference is known to the installed Firefox" "unzip is not available"
else
  pref_list=$(mktemp); pref_found=$(mktemp)
  sed -n 's/^pref: \([^ ]*\) =.*/\1/p' "$MANIFEST" | sort -u > "$pref_list"
  {
    for archive in "$firefox_dir/omni.ja" "$firefox_dir/browser/omni.ja"; do
      [ -f "$archive" ] && unzip -p "$archive" 2>/dev/null
    done
    for bin in "$firefox_dir/libxul.so" "$firefox_dir/XUL" "$firefox_dir/firefox"; do
      [ -f "$bin" ] && cat "$bin"
    done
  } | grep -a -oFf "$pref_list" 2>/dev/null | sort -u > "$pref_found"
  unknown=$(comm -23 "$pref_list" "$pref_found" | tr '\n' ' ' | sed 's/ $//')
  if [ -z "$unknown" ]; then
    ok "every preference is known to the installed Firefox"
  else
    skipped "every preference is known to the installed Firefox" \
      "could not confirm: $unknown
     Check each in about:config. A name that is genuinely gone is a bug; some
     compiled-in prefs simply do not appear in either file."
  fi
  rm -f "$pref_list" "$pref_found"
fi

# ------------------------------------------------------------ dependencies ----

section "runtime dependencies"

# The whole point of the awk rewrite: this has to work on a machine with no jq
# and no python, which is the normal state of a fresh macOS or a minimal Linux.
bare=$(mktemp -d)
for tool in sh cat awk sed grep cut tr wc date mkdir mv rm cp chmod dirname uname stat sha256sum shasum; do
  src=$(command -v "$tool" 2>/dev/null) && ln -sf "$src" "$bare/$tool"
done
out=$(PATH="$bare" "$INSTALLER" --profile standard --dry-run 2>&1)
rc=$?
check "runs with no jq and no python on PATH" "0" "$rc"
if printf '%s' "$out" | sed -n '/^{/,$p' | is_json; then
  ok "and still produces valid JSON"
else
  not_ok "and still produces valid JSON"
fi
rm -rf "$bare"

# awk implementations disagree in ways that produce silently wrong output
# rather than errors, so every awk on this machine must agree.
ref=$("$INSTALLER" --profile strict --dry-run | sed -n '/^{/,$p')
for a in gawk mawk busybox original-awk nawk; do
  command -v "$a" >/dev/null 2>&1 || continue
  d=$(mktemp -d)
  if [ "$a" = busybox ]; then
    printf '#!/bin/sh\nexec busybox awk "$@"\n' > "$d/awk"
    chmod +x "$d/awk"
  else
    ln -sf "$(command -v "$a")" "$d/awk"
  fi
  got=$(PATH="$d:$PATH" "$INSTALLER" --profile strict --dry-run | sed -n '/^{/,$p')
  check "$a produces identical output" "$ref" "$got"
  rm -rf "$d"
done

# ------------------------------------------------------------------ build ----

section "build"

check "version matches VERSION file" "$(cat "$repo_root/VERSION")" "$("$INSTALLER" --version)"

std=$("$INSTALLER" --profile standard --dry-run | sed -n '/^{/,$p')
if printf '%s' "$std" | is_json; then ok "standard profile is valid JSON"
else not_ok "standard profile is valid JSON"; fi

std_again=$("$INSTALLER" --profile standard --dry-run | sed -n '/^{/,$p')
check "standard profile is deterministic" "$std" "$std_again"

strict=$("$INSTALLER" --profile strict --dry-run | sed -n '/^{/,$p')
if printf '%s' "$strict" | is_json; then ok "strict profile is valid JSON"
else not_ok "strict profile is valid JSON"; fi

# Nested policies are the case a naive JSON writer gets wrong: mawk once turned
# every one of these into an empty object without erroring.
check "nested policies survive the merge" "false" \
  "$(printf '%s' "$std" | jget policies.FirefoxHome.SponsoredTopSites)"
check "two features merge into one nested policy" "false" \
  "$(printf '%s' "$std" | jget policies.FirefoxHome.Stories)"
check "nested policies are not empty objects" "4" \
  "$(printf '%s' "$std" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["policies"]["FirefoxHome"]))')"

check "preferences carry a value and a status" "true" \
  "$(printf '%s' "$std" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["policies"]["Preferences"]["privacy.globalprivacycontrol.enabled"]["Value"]))')"
check "preference status is default" "default" \
  "$(printf '%s' "$std" | python3 -c 'import json,sys; print(json.load(sys.stdin)["policies"]["Preferences"]["privacy.globalprivacycontrol.enabled"]["Status"])')"

check "strict turns tracking protection up to strict" "strict" \
  "$(printf '%s' "$strict" | jget policies.EnableTrackingProtection.Category)"
check "standard leaves tracking protection at the default category" "null" \
  "$(printf '%s' "$std" | jget policies.EnableTrackingProtection.Category)"
check "standard leaves captive portal detection alone" "null" \
  "$(printf '%s' "$std" | jget policies.CaptivePortal)"
check "tracking protection is not locked" "false" \
  "$(printf '%s' "$std" | jget policies.EnableTrackingProtection.Locked)"

for k in DisableAppUpdate AppUpdateURL ManualAppUpdateOnly DisableAccounts \
         DisableFirefoxAccounts PasswordManagerEnabled; do
  check "$k is never set" "null" "$(printf '%s' "$strict" | jget "policies.$k")"
done

custom=$("$INSTALLER" --profile standard --enable captive-portal --disable telemetry --dry-run |
  sed -n '/^{/,$p')
check "--enable adds a feature" "false" "$(printf '%s' "$custom" | jget policies.CaptivePortal)"
check "--disable removes a feature" "null" "$(printf '%s' "$custom" | jget policies.DisableTelemetry)"

"$INSTALLER" --profile nonsense --dry-run >/dev/null 2>&1
check "an unknown profile is rejected" "1" "$?"
"$INSTALLER" --enable no-such-feature --dry-run >/dev/null 2>&1
check "an unknown feature id is rejected" "1" "$?"

# A malformed manifest must stop the build, not produce a half written policy.
broken=$(mktemp)
printf 'feature: x\nname: X\nsummary: X\ncost:\npresets: standard\npolicy: A.B.C = true\n' > "$broken"
FOXPRIVACY_MANIFEST="$broken" "$INSTALLER" --profile standard --dry-run >/dev/null 2>&1
check "a too-deeply nested policy is refused" "1" "$?"
printf 'feature: x\nname: X\nsummary: X\ncost:\npresets: standard\npref: browser.x = 1 bogus\n' > "$broken"
FOXPRIVACY_MANIFEST="$broken" "$INSTALLER" --profile standard --dry-run >/dev/null 2>&1
check "an invalid preference status is refused" "1" "$?"
printf 'feature: x\nname: X\nsummary: X\ncost:\npresets: standard\npolicy: A = true\npolicy: A.B = true\n' > "$broken"
FOXPRIVACY_MANIFEST="$broken" "$INSTALLER" --profile standard --dry-run >/dev/null 2>&1
check "a key used as both value and group is refused" "1" "$?"
rm -f "$broken"

# --------------------------------------------------------------- fixtures ----

section "fixtures"

# The committed fixtures are the exact bytes both installers must produce. The
# Windows suite checks itself against these same files, which is how the two
# implementations are held to identical output without a shared machine.
for preset in standard strict; do
  fixture="$repo_root/tests/fixtures/$preset.json"
  if [ ! -f "$fixture" ]; then
    not_ok "fixture for $preset exists" "run tools/gen-fixtures.sh"
    continue
  fi
  generated=$("$INSTALLER" --profile "$preset" --dry-run | sed -n '/^{/,$p')
  if [ "$generated" = "$(cat "$fixture")" ]; then
    ok "$preset output matches the committed fixture"
  else
    not_ok "$preset output matches the committed fixture" \
      "run tools/gen-fixtures.sh and commit the result"
  fi
done

check "fixtures contain no CRLF line endings" "0" \
  "$(cat "$repo_root/tests/fixtures/"*.json | tr -dc '\r' | wc -c | tr -d ' ')"

# --------------------------------------------------------- install cycle ----

section "install cycle"

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
export FOXPRIVACY_ROOT="$root"
case "$(uname -s)" in
  Darwin)
    target_rel="Applications/Firefox.app/Contents/Resources/distribution/policies.json"
    state_rel="Applications/Firefox.app/Contents/Resources/distribution/.foxprivacy-state"
    parent_rel="Applications/Firefox.app/Contents/Resources"
    state_dir_rel="Applications/Firefox.app/Contents/Resources/distribution"
    legacy_dir_rel="Library/Application Support/FoxPrivacy"
    ;;
  *)
    target_rel="etc/firefox/policies/policies.json"
    state_rel="etc/firefox/policies/.foxprivacy-state"
    parent_rel="etc/firefox"
    state_dir_rel="etc/firefox/policies"
    legacy_dir_rel="var/lib/foxprivacy"
    ;;
esac
target="$root/$target_rel"
state="$root/$state_rel"

"$INSTALLER" --profile standard >/dev/null 2>&1
check "install exits cleanly" "0" "$?"
if [ -f "$target" ]; then ok "install writes the policy file"
else not_ok "install writes the policy file"; fi
if [ -f "$state" ]; then ok "install records state"; else not_ok "install records state"; fi
if is_json < "$target"; then ok "installed file is valid JSON"
else not_ok "installed file is valid JSON"; fi
check "installed file is world readable" "644" "$(file_mode "$target")"
check "state records the profile" "standard" "$(sed -n 's/^profile=//p' "$state")"
check "installed file matches the recorded checksum" \
  "$(sed -n 's/^sha256=//p' "$state")" "$(sum256 "$target")"

"$INSTALLER" --verify >/dev/null 2>&1
check "verify reports a clean install" "0" "$?"
check "a fresh install creates no backup" "0" \
  "$(find "$root" -name '*.foxprivacy-backup-*' | wc -l | tr -d ' ')"

"$INSTALLER" --profile strict >/dev/null 2>&1
check "reinstalling over our own file creates no backup" "0" \
  "$(find "$root" -name '*.foxprivacy-backup-*' | wc -l | tr -d ' ')"
check "reinstall updates the recorded profile" "strict" "$(sed -n 's/^profile=//p' "$state")"

printf 'tampered\n' >> "$target"
"$INSTALLER" --verify >/dev/null 2>&1
check "verify detects a modified file" "2" "$?"
"$INSTALLER" --uninstall >/dev/null 2>&1
check "uninstall refuses to remove a modified file" "1" "$?"
if [ -f "$target" ]; then ok "the modified file is left alone"
else not_ok "the modified file is left alone"; fi
"$INSTALLER" --uninstall --force >/dev/null 2>&1
check "--force removes a modified file" "0" "$?"
if [ ! -f "$target" ]; then ok "uninstall removes the policy file"
else not_ok "uninstall removes the policy file"; fi
if [ ! -f "$state" ]; then ok "uninstall removes the state file"
else not_ok "uninstall removes the state file"; fi

# ------------------------------------------------------ backup and restore ----

section "backup and restore"

rm -rf "$root"; mkdir -p "$(dirname "$target")"
printf '%s\n' '{"policies":{"DisableDeveloperTools":true}}' > "$target"
existing_sum=$(sum256 "$target")

"$INSTALLER" --profile standard >/dev/null 2>&1
backup=$(find "$root" -name '*.foxprivacy-backup-*' | head -1)
if [ -n "$backup" ]; then ok "an existing policies.json is backed up"
else not_ok "an existing policies.json is backed up"; fi
check "the backup is byte identical to what was there" "$existing_sum" \
  "$(sum256 "$backup")"
check "state records the backup path" "$backup" "$(sed -n 's/^backup=//p' "$state")"

"$INSTALLER" --profile strict >/dev/null 2>&1
check "reinstalling keeps pointing at the original backup" "$backup" \
  "$(sed -n 's/^backup=//p' "$state")"
check "reinstalling does not create a second backup" "1" \
  "$(find "$root" -name '*.foxprivacy-backup-*' | wc -l | tr -d ' ')"

"$INSTALLER" --uninstall >/dev/null 2>&1
check "uninstall restores the original file byte for byte" "$existing_sum" \
  "$(sum256 "$target" 2>/dev/null)"
check "uninstall leaves no backup behind" "0" \
  "$(find "$root" -name '*.foxprivacy-backup-*' | wc -l | tr -d ' ')"

# ------------------------------------------------------- foreign policies ----

section "someone else's policies.json"

rm -rf "$root"; mkdir -p "$(dirname "$target")"
printf '%s\n' '{"policies":{"DisableDeveloperTools":true}}' > "$target"
foreign_sum=$(sum256 "$target")
"$INSTALLER" --uninstall >/dev/null 2>&1
check "uninstall refuses a file FoxPrivacy did not install" "1" "$?"
check "and leaves it untouched" "$foreign_sum" "$(sum256 "$target")"
"$INSTALLER" --verify >/dev/null 2>&1
check "verify reports a foreign policy file" "2" "$?"

rm -rf "$root"; mkdir -p "$(dirname "$target")"
"$INSTALLER" --verify >/dev/null 2>&1
check "verify reports nothing installed" "1" "$?"

# ---------------------------------------------------------------- guards ----

section "guards"

rm -rf "$root"; mkdir -p "$(dirname "$target")"
"$INSTALLER" --profile standard >/dev/null 2>&1
alt="$(dirname "$target")/other.json"
"$INSTALLER" --target "$alt" --profile standard >/dev/null 2>&1
check "installing to a second target is refused" "1" "$?"
if [ ! -f "$alt" ]; then ok "the second target is not written"
else not_ok "the second target is not written"; fi
check "the first install is still the recorded one" "$target" "$(sed -n 's/^target=//p' "$state")"
"$INSTALLER" --target "$alt" --profile standard --force >/dev/null 2>&1
check "--force allows a second target" "0" "$?"

# The installer must create the directory itself here, so do not pre-create it.
# Every level it makes has to be readable by the user Firefox runs as, not just
# the last one.
rm -rf "$root"
umask 077
"$INSTALLER" --profile standard >/dev/null 2>&1
umask 022
check "the policy directory it creates is readable" "755" \
  "$(file_mode "$(dirname "$target")")"
check "and so is every parent it created" "755" "$(file_mode "$root/$parent_rel")"
check "the state directory it creates is readable" "755" "$(file_mode "$root/$state_dir_rel")"
check "the state file it writes is readable" "644" "$(file_mode "$state")"

# A directory somebody else made is left alone, but the user is warned that
# Firefox will not be able to read through it.
rm -rf "$root"; mkdir -p "$(dirname "$target")"; chmod 700 "$(dirname "$target")"
warned=$("$INSTALLER" --profile standard 2>&1 >/dev/null || true)
check "an unreadable existing directory is left alone" "700" \
  "$(file_mode "$(dirname "$target")")"
case "$warned" in
  *"not readable by other users"*) ok "and the user is warned about it" ;;
  *) not_ok "and the user is warned about it" "no warning in: $warned" ;;
esac

rm -rf "$root"; mkdir -p "$(dirname "$target")"
"$INSTALLER" --profile standard --dry-run >/dev/null 2>&1
if [ ! -f "$target" ]; then ok "dry run writes nothing"
else not_ok "dry run writes nothing"; fi
if [ ! -f "$state" ]; then ok "dry run records no state"
else not_ok "dry run records no state"; fi

# The record now lives beside the policy file, so installing never needs a
# second, more privileged location. A real macOS install found that the hard
# way: the application bundle was writable, /Library/Application Support was
# not, and the machine ended up half configured.
rm -rf "$root"; mkdir -p "$(dirname "$target")"
"$INSTALLER" --profile standard >/dev/null 2>&1
check "the record sits next to the policy file" "$(dirname "$target")" "$(dirname "$state")"
if [ -f "$state" ]; then ok "and needs no second directory to write it"
else not_ok "and needs no second directory to write it"; fi

# A record written by 1.0.0 lived in a system directory. Those installs must
# still be verifiable and removable.
rm -rf "$root"; mkdir -p "$(dirname "$target")" "$root/$legacy_dir_rel"
"$INSTALLER" --profile standard >/dev/null 2>&1
mv "$state" "$root/$legacy_dir_rel/state"
"$INSTALLER" --verify >/dev/null 2>&1
check "a record from an older version is still read" "0" "$?"
"$INSTALLER" --uninstall >/dev/null 2>&1
check "and can still be uninstalled" "0" "$?"
if [ ! -f "$target" ]; then ok "which removes the policy file"
else not_ok "which removes the policy file"; fi
if [ ! -f "$root/$legacy_dir_rel/state" ]; then ok "and the old record"
else not_ok "and the old record"; fi

# Reinstalling over an older install must end with one record, not two.
rm -rf "$root"; mkdir -p "$(dirname "$target")" "$root/$legacy_dir_rel"
"$INSTALLER" --profile standard >/dev/null 2>&1
mv "$state" "$root/$legacy_dir_rel/state"
"$INSTALLER" --profile strict >/dev/null 2>&1
if [ -f "$state" ]; then ok "reinstalling writes the record in its new place"
else not_ok "reinstalling writes the record in its new place"; fi
if [ ! -f "$root/$legacy_dir_rel/state" ]; then ok "and retires the old one"
else not_ok "and retires the old one"; fi

# A record we cannot parse must stop us. Treating it as empty made uninstall
# report "OK removed " for the empty string, exit 0, and delete the record,
# which would orphan whatever was actually installed.
rm -rf "$root"; mkdir -p "$(dirname "$target")" "$(dirname "$state")"
printf '%s\n' '{"policies":{"DisableDeveloperTools":true}}' > "$target"
printf 'garbage\n' > "$state"
"$INSTALLER" --uninstall >/dev/null 2>&1
check "uninstall refuses an unreadable record" "1" "$?"
if [ -f "$state" ]; then ok "and keeps the record instead of deleting it"
else not_ok "and keeps the record instead of deleting it"; fi
if [ -f "$target" ]; then ok "and leaves the policy file alone"
else not_ok "and leaves the policy file alone"; fi
"$INSTALLER" --verify >/dev/null 2>&1
check "verify refuses an unreadable record" "1" "$?"

# ----------------------------------------------------------------- macos ----

section "macos path logic"

# macOS is not this machine, so this proves the platform branch resolves
# correctly, not that the tool works on a Mac.
fake_bin=$(mktemp -d)
printf '#!/bin/sh\necho Darwin\n' > "$fake_bin/uname"; chmod +x "$fake_bin/uname"
mac_root=$(mktemp -d)
mac_out=$(PATH="$fake_bin:$PATH" FOXPRIVACY_ROOT="$mac_root" "$INSTALLER" \
  --profile standard --dry-run 2>&1)
check "macOS targets the app bundle" \
  "$mac_root/Applications/Firefox.app/Contents/Resources/distribution/policies.json" \
  "$(printf '%s' "$mac_out" | sed -n 's/^would write:  *//p')"
PATH="$fake_bin:$PATH" FOXPRIVACY_ROOT="$mac_root" "$INSTALLER" --profile standard >/dev/null 2>&1
check "macOS install exits cleanly" "0" "$?"
if [ -f "$mac_root/Applications/Firefox.app/Contents/Resources/distribution/policies.json" ]
then ok "macOS install writes into the app bundle"
else not_ok "macOS install writes into the app bundle"; fi
if [ -f "$mac_root/Applications/Firefox.app/Contents/Resources/distribution/.foxprivacy-state" ]
then ok "macOS state goes to the documented macOS location"
else not_ok "macOS state goes to the documented macOS location"; fi
PATH="$fake_bin:$PATH" FOXPRIVACY_ROOT="$mac_root" "$INSTALLER" --uninstall >/dev/null 2>&1
check "macOS uninstall exits cleanly" "0" "$?"
printf '#!/bin/sh\necho OpenBSD\n' > "$fake_bin/uname"
PATH="$fake_bin:$PATH" "$INSTALLER" --profile standard --dry-run >/dev/null 2>&1
check "an unsupported platform is refused" "1" "$?"
rm -rf "$fake_bin" "$mac_root"

# ------------------------------------------------------------- single file ----

section "single file build"

dist_dir=$(mktemp -d)
"$repo_root/tools/build-dist.sh" "$dist_dir" >/dev/null 2>&1
check "the build succeeds" "0" "$?"

# The distributed file carries the manifest in its own tail. It must still be
# valid shell from top to bottom, or nobody can check what they are about to run.
sh -n "$dist_dir/foxprivacy.sh" 2>/dev/null
check "the single file is valid shell all the way down" "0" "$?"

# It has to work with no repository around it, which is how a downloader gets it.
sandbox=$(mktemp -d)
cp "$dist_dir/foxprivacy.sh" "$sandbox/foxprivacy.sh"
standalone=$("$sandbox/foxprivacy.sh" --profile strict --dry-run 2>/dev/null | sed -n '/^{/,$p')
if [ "$standalone" = "$(cat "$repo_root/tests/fixtures/strict.json")" ]; then
  ok "the single file reads its embedded manifest and matches the fixture"
else
  not_ok "the single file reads its embedded manifest and matches the fixture"
fi

sf_root=$(mktemp -d)
FOXPRIVACY_ROOT="$sf_root" "$sandbox/foxprivacy.sh" --profile standard >/dev/null 2>&1
check "the single file installs" "0" "$?"
FOXPRIVACY_ROOT="$sf_root" "$sandbox/foxprivacy.sh" --verify >/dev/null 2>&1
check "the single file verifies" "0" "$?"
FOXPRIVACY_ROOT="$sf_root" "$sandbox/foxprivacy.sh" --uninstall >/dev/null 2>&1
check "the single file uninstalls" "0" "$?"
if [ ! -f "$sf_root/$target_rel" ]
then ok "and leaves nothing behind"; else not_ok "and leaves nothing behind"; fi

if [ -f "$dist_dir/foxprivacy.ps1" ]
then ok "the Windows single file is built too"
else not_ok "the Windows single file is built too"; fi
check "the Windows single file embeds the manifest" "1" \
  "$(grep -c '^# feature: telemetry$' "$dist_dir/foxprivacy.ps1")"

rm -rf "$dist_dir" "$sandbox" "$sf_root"

# ------------------------------------------------------------------- docs ----

section "docs"

tmp_doc=$(mktemp)
"$repo_root/tools/gen-docs.sh" "$tmp_doc" >/dev/null 2>&1
if diff -q "$tmp_doc" "$repo_root/docs/POLICIES.md" >/dev/null 2>&1; then
  ok "docs/POLICIES.md matches the manifest"
else
  not_ok "docs/POLICIES.md matches the manifest" "run tools/gen-docs.sh and commit the result"
fi
rm -f "$tmp_doc"

# ------------------------------------------------------------------ drift ----

section "documentation drift"

# Prose goes stale silently: a feature is renamed, a preference is replaced by a
# policy, a file moves, and the docs keep asserting the old thing without
# anything failing.
drift=$("$repo_root/tools/check-drift.py" 2>&1)
if [ -z "$drift" ]; then
  ok "the documentation still describes the project as it is"
else
  not_ok "the documentation still describes the project as it is" "$drift"
fi

# ----------------------------------------------------------------- result ----

printf '\n%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
