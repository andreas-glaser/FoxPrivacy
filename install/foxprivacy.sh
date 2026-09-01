#!/bin/sh
#
# FoxPrivacy - turn off Firefox telemetry, sponsored content, and nagging
# without breaking Firefox.
#
# Builds a Firefox enterprise policies.json from the feature manifest and
# installs it where Firefox reads it, backing up whatever was there first.
#
# Requires only a POSIX shell and awk. No jq, no python, no package manager.
# Run with no arguments for the interactive menu.

set -eu

FOXPRIVACY_VERSION="1.0.0"

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname "$script_dir")

# Test hook: prefixes every path the script touches, so a full install and
# uninstall cycle can run against a temporary directory without root.
ROOT="${FOXPRIVACY_ROOT:-}"

DRY_RUN=0
FORCE=0
TARGET=""
ORIGINAL_ARGS=""

# ---------------------------------------------------------------- output ----

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$(printf '\033[0m'); C_BOLD=$(printf '\033[1m'); C_DIM=$(printf '\033[2m')
  C_RED=$(printf '\033[31m'); C_GREEN=$(printf '\033[32m'); C_YELLOW=$(printf '\033[33m')
  C_BLUE=$(printf '\033[34m')
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''
fi

die()  { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
info() { printf '%s\n' "$*"; }
ok()   { printf '%sOK%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }

# -------------------------------------------------------------- manifest ----

# The manifest lives beside the script in a checkout, or is appended to this
# file after the marker below in the single file release build. It is appended
# as comment lines so the distributed file stays valid shell all the way down
# and can be checked with sh -n and shellcheck; raw text would trip on the first
# apostrophe. A script piped straight into a shell cannot read its own tail,
# which is one reason the documented one liner downloads to a file first.
load_manifest() {
  if [ -n "${FOXPRIVACY_MANIFEST:-}" ]; then
    [ -f "$FOXPRIVACY_MANIFEST" ] || die "manifest not found: $FOXPRIVACY_MANIFEST"
    cat "$FOXPRIVACY_MANIFEST"
    return
  fi
  # A release build carries its own manifest and must use it. Checking the
  # filesystem first would let an unrelated checkout nearby silently override
  # what the downloaded file says it does.
  if [ -f "$0" ] && grep -q '^#__MANIFEST__$' "$0" 2>/dev/null; then
    awk 'f { sub(/^# ?/, ""); print } /^#__MANIFEST__$/ { f = 1 }' "$0"
    return
  fi
  if [ -f "$repo_root/policies/features.conf" ]; then
    cat "$repo_root/policies/features.conf"
    return
  fi
  if [ -f "$script_dir/features.conf" ]; then
    cat "$script_dir/features.conf"
    return
  fi
  die "no feature manifest found.
  Looked for policies/features.conf beside the script and for an embedded copy.
  If you piped this script into a shell, download it to a file and run that
  instead: the embedded manifest can only be read from a real file."
}

# ------------------------------------------------------------ awk helpers ----

# One pass over the manifest producing a record per feature, which every menu
# and listing then reads. Four separate awk programs re-parsing the file for
# each field cost 163 processes to draw one screen.
# shellcheck disable=SC2016  # awk program: $0 and $1 are awk's, not the shell's
AWK_RECORDS='
  function flush() {
    if (cur != "") printf "%s|%s|%s|%s|%s\n", cur, name, summary, cost, presets
  }
  /^[ \t]*#/ { next }
  {
    ci = index($0, ":")
    if (ci == 0) next
    k = substr($0, 1, ci - 1)
    v = substr($0, ci + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
    if (k == "feature") {
      flush()
      cur = v; name = ""; summary = ""; cost = ""; presets = ""
      next
    }
    if (k == "name") name = v
    else if (k == "summary") summary = v
    else if (k == "cost") cost = v
    else if (k == "presets") presets = v
  }
  END { flush() }
'

# shellcheck disable=SC2016  # awk program: $0 and $1 are awk's, not the shell's
AWK_BUILD='
  function fail(m) { printf "manifest error: %s\n", m | "cat 1>&2"; failed = 1; exit 3 }

  function jval(v) {
    if (v ~ /["\\]/) fail("value contains a quote or backslash: " v)
    if (v == "true" || v == "false") return v
    if (v ~ /^-?[0-9]+$/) return v
    return "\"" v "\""
  }

  function addpolicy(v,   ei, path, value, di, top, child) {
    ei = index(v, " = ")
    if (ei == 0) fail("policy line is not <key> = <value>: " v)
    path = substr(v, 1, ei - 1)
    value = substr(v, ei + 3)
    di = index(path, ".")
    if (di == 0) { top = path; child = "" }
    else {
      top = substr(path, 1, di - 1); child = substr(path, di + 1)
      if (index(child, ".") > 0) fail("policy keys nest at most two deep: " path)
    }
    if (!(top in seentop)) { seentop[top] = 1; toporder[++ntop] = top }
    if (child == "") {
      if (top in haschild) fail("policy " top " is used both as a value and as a group")
      isleaf[top] = 1; leafval[top] = value
    } else {
      if (top in isleaf) fail("policy " top " is used both as a value and as a group")
      haschild[top] = 1
      if (!((top SUBSEP child) in seensub)) {
        seensub[top SUBSEP child] = 1
        # The increment is its own statement on purpose. Inside a concatenation
        # mawk parses "top SUBSEP ++subn[top]" as two additions, the increment
        # never happens, and every nested policy silently becomes {}.
        subn[top] = subn[top] + 1
        suborder[top SUBSEP subn[top]] = child
      }
      subval[top SUBSEP child] = value
    }
  }

  function addpref(v,   ei, name, rest, sp, value, status) {
    ei = index(v, " = ")
    if (ei == 0) fail("pref line is not <name> = <value> [status]: " v)
    name = substr(v, 1, ei - 1)
    rest = substr(v, ei + 3)
    sp = index(rest, " ")
    if (sp == 0) { value = rest; status = "default" }
    else { value = substr(rest, 1, sp - 1); status = substr(rest, sp + 1) }
    if (status != "default" && status != "locked" && status != "user" && status != "clear")
      fail("preference status must be default, locked, user, or clear: " status)
    if (name ~ /^Preferences$/) fail("a preference cannot be named Preferences")
    if (!(name in seenpref)) { seenpref[name] = 1; preforder[++npref] = name }
    prefval[name] = value; prefstatus[name] = status
  }

  BEGIN {
    n = split(want, w, " ")
    for (i = 1; i <= n; i++) sel[w[i]] = 1
    ntop = 0; npref = 0; nfrag = 0; failed = 0
  }

  /^[ \t]*#/ { next }
  {
    ci = index($0, ":")
    if (ci == 0) next
    k = substr($0, 1, ci - 1)
    v = substr($0, ci + 1); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
    if (k == "feature") { cur = v; next }
    if (!(cur in sel)) next
    if (k == "policy") addpolicy(v)
    else if (k == "pref") addpref(v)
  }

  END {
    if (failed) exit 3
    for (i = 1; i <= ntop; i++) {
      top = toporder[i]
      if (top == "Preferences") fail("use pref: lines, not a Preferences policy")
      if (top in isleaf) frag = "    \"" top "\": " jval(leafval[top])
      else {
        frag = "    \"" top "\": {\n"
        for (j = 1; j <= subn[top]; j++) {
          c = suborder[top SUBSEP j]
          frag = frag "      \"" c "\": " jval(subval[top SUBSEP c])
          frag = frag (j < subn[top] ? ",\n" : "\n")
        }
        frag = frag "    }"
      }
      frags[++nfrag] = frag
    }
    if (npref > 0) {
      frag = "    \"Preferences\": {\n"
      for (i = 1; i <= npref; i++) {
        p = preforder[i]
        frag = frag "      \"" p "\": {\n"
        frag = frag "        \"Value\": " jval(prefval[p]) ",\n"
        frag = frag "        \"Status\": \"" prefstatus[p] "\"\n"
        frag = frag "      }"
        frag = frag (i < npref ? ",\n" : "\n")
      }
      frag = frag "    }"
      frags[++nfrag] = frag
    }
    printf "{\n  \"policies\": {\n"
    for (i = 1; i <= nfrag; i++) printf "%s%s\n", frags[i], (i < nfrag ? "," : "")
    printf "  }\n}\n"
  }
'

records() { printf '%s\n' "$RECORDS"; }

all_ids() { records | cut -d'|' -f1; }

preset_ids() {
  records | awk -F'|' -v want="$1" \
    '{ n = split($5, p, " "); for (i = 1; i <= n; i++) if (p[i] == want) print $1 }'
}

preset_names() {
  records | awk -F'|' \
    '{ n = split($5, p, " ")
       for (i = 1; i <= n; i++) if (!(p[i] in seen)) { seen[p[i]] = 1; print p[i] } }'
}

feature_exists() { all_ids | grep -qxF "$1"; }

build_json() {
  printf '%s\n' "$MANIFEST" | awk -v want="$1" "$AWK_BUILD" ||
    die "could not build policies.json from the manifest"
}

# ----------------------------------------------------------- environment ----

platform() {
  case "$(uname -s)" in
    Linux)  printf 'linux' ;;
    Darwin) printf 'macos' ;;
    *)      printf 'unsupported' ;;
  esac
}

default_target() {
  case "$(platform)" in
    linux) printf '%s/etc/firefox/policies/policies.json' "$ROOT" ;;
    macos) printf '%s/Applications/Firefox.app/Contents/Resources/distribution/policies.json' "$ROOT" ;;
    *)     die "unsupported platform: $(uname -s). Windows uses install/foxprivacy.ps1." ;;
  esac
}

default_state_dir() {
  if [ -n "${FOXPRIVACY_STATE_DIR:-}" ]; then printf '%s' "$FOXPRIVACY_STATE_DIR"; return; fi
  case "$(platform)" in
    linux) printf '%s/var/lib/foxprivacy' "$ROOT" ;;
    macos) printf '%s/Library/Application Support/FoxPrivacy' "$ROOT" ;;
    *)     die "unsupported platform: $(uname -s)" ;;
  esac
}

# Every integrity check rests on this. Without it, verify would compare two
# identical placeholders and pass, so a missing tool has to be fatal rather
# than quietly permissive.
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    die "neither sha256sum nor shasum is available.
  FoxPrivacy uses checksums to tell its own file apart from yours, and will
  not install without them."
  fi
}

warn_alternate_packaging() {
  [ "$(platform)" = "linux" ] || return 0
  [ -z "$ROOT" ] || return 0
  found=""
  [ -d /snap/firefox ] && found="snap"
  if command -v flatpak >/dev/null 2>&1 && flatpak info org.mozilla.firefox >/dev/null 2>&1; then
    found="${found:+$found and }flatpak"
  fi
  [ -n "$found" ] || return 0
  warn "Firefox from $found detected.
  Policies are written to the system location, which the distribution package
  reads. Whether the $found build reads it too is not confirmed by this project.
  After installing, open about:policies and check the Active tab is not empty.
  Please report what you find: https://github.com/andreas-glaser/foxprivacy/issues"
}

# ------------------------------------------------------------------ state ----

state_file() { printf '%s/state' "$(default_state_dir)"; }

state_get() {
  [ -f "$(state_file)" ] || return 1
  sed -n "s/^$1=//p" "$(state_file)"
}

state_get_or_empty() { state_get "$1" 2>/dev/null || printf ''; }

write_state() {
  dir=$(default_state_dir)
  (umask 022 && mkdir -p "$dir") || die "cannot create $dir"
  {
    printf 'version=%s\n' "$FOXPRIVACY_VERSION"
    printf 'installed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'profile=%s\n' "$1"
    printf 'target=%s\n' "$2"
    printf 'backup=%s\n' "$3"
    printf 'sha256=%s\n' "$4"
    printf 'features=%s\n' "$5"
  } > "$dir/state"
  chmod 644 "$dir/state"
}

# --------------------------------------------------------------- selection ----

sel_has() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }

sel_add() { if sel_has "$1" "$2"; then printf '%s' "$1"; else printf '%s' "${1:+$1 }$2"; fi; }

sel_remove() {
  out=""
  # Deliberate word splitting: selections are space separated lists of ids.
  # shellcheck disable=SC2086
  for _id in $1; do [ "$_id" = "$2" ] || out="${out:+$out }$_id"; done
  printf '%s' "$out"
}

sel_toggle() {
  if sel_has "$1" "$2"; then sel_remove "$1" "$2"; else sel_add "$1" "$2"; fi
}

# Reorders a selection into manifest order so generated files are stable.
sel_normalise() {
  out=""
  # shellcheck disable=SC2086
  for _id in $(all_ids); do sel_has "$1" "$_id" && out="${out:+$out }$_id"; done
  printf '%s' "$out"
}

count_words() { printf '%s' "$1" | wc -w | tr -d ' '; }

# ------------------------------------------------------------------ verbs ----

cmd_list() {
  printf '%sFoxPrivacy features%s\n\n' "$C_BOLD" "$C_RESET"
  records | awk -F'|' -v b="$C_BOLD" -v r="$C_RESET" -v d="$C_DIM" -v y="$C_YELLOW" '
    {
      printf "  %s%-26s%s %s\n", b, $1, r, $2
      printf "  %-26s %s%s%s\n", "", d, $3, r
      printf "  %-26s %sin: %s%s\n", "", d, $5, r
      if ($4 != "") printf "  %-26s %scost: %s%s\n", "", y, $4, r
      printf "\n"
    }'
}

cmd_verify() {
  target="${TARGET:-$(default_target)}"

  if [ ! -f "$(state_file)" ]; then
    if [ -f "$target" ]; then
      printf '%snot installed by FoxPrivacy%s\n' "$C_YELLOW" "$C_RESET"
      info "A policies.json exists at $target but FoxPrivacy did not put it there."
      return 2
    fi
    printf '%snot installed%s\n' "$C_YELLOW" "$C_RESET"
    info "No policy file at $target"
    return 1
  fi

  recorded_target=$(state_get target)
  recorded_sha=$(state_get sha256)

  if [ ! -f "$recorded_target" ]; then
    printf '%smissing%s\n' "$C_RED" "$C_RESET"
    info "FoxPrivacy installed $recorded_target but it is gone."
    info "A Firefox update may have removed it. Re-run the installer."
    return 2
  fi

  if [ "$(sha256 "$recorded_target")" != "$recorded_sha" ]; then
    printf '%schanged%s\n' "$C_YELLOW" "$C_RESET"
    info "$recorded_target has been modified since FoxPrivacy installed it."
    info "Re-run the installer to restore it, or leave it if the change was yours."
    return 2
  fi

  ok "installed and unchanged"
  info "  profile:  $(state_get profile)"
  info "  target:   $recorded_target"
  info "  features: $(count_words "$(state_get features)") enabled"
  info "  since:    $(state_get installed_at)"
  printf '\n%sRestart Firefox and open about:policies to confirm it took effect.%s\n' \
    "$C_DIM" "$C_RESET"
  return 0
}

cmd_install() {
  profile="$1"; features="$2"
  target="${TARGET:-$(default_target)}"
  dir=$(dirname "$target")

  [ -n "$features" ] || die "nothing selected. Nothing would change."

  body=$(build_json "$features")

  if [ "$DRY_RUN" = "1" ]; then
    warn_alternate_packaging
    printf '%sDry run. Nothing was written.%s\n\n' "$C_BOLD" "$C_RESET"
    info "would write:   $target"
    if [ -f "$target" ]; then
      info "would back up: $target -> $target.foxprivacy-backup-<timestamp>"
    else
      info "would back up: nothing, no file there yet"
    fi
    info "profile:       $profile"
    info "features:      $(count_words "$features") enabled"
    printf '\n%s\n' "$body"
    return 0
  fi

  warn_alternate_packaging

  prior_target=$(state_get_or_empty target)
  if [ -n "$prior_target" ] && [ "$prior_target" != "$target" ] && [ -f "$prior_target" ] &&
     [ "$FORCE" != "1" ]; then
    die "FoxPrivacy is already installed at $prior_target.
  Installing to $target as well would lose the record of the first one, and
  uninstall could never clean it up. Uninstall that one first:
    $0 --uninstall
  Or re-run with --force to abandon the record of it."
  fi

  # mkdir applies the caller's umask to every level it creates. A restrictive
  # umask would leave the directory unreadable by the user Firefox runs as, and
  # Firefox would ignore the policy file without saying anything. The subshell
  # keeps the umask change from leaking into the rest of the run.
  if [ -d "$dir" ]; then
    # A directory somebody else created is left exactly as it is, but if Firefox
    # cannot traverse it our file is ignored with no error anywhere, so say so.
    if command -v find >/dev/null 2>&1 &&
       [ -z "$(find "$dir" -maxdepth 0 -perm -005 2>/dev/null)" ]; then
      warn "$dir is not readable by other users.
  Firefox usually runs as your login user, not as root, and will silently
  ignore the policy file if it cannot read this directory. Consider:
    sudo chmod 755 \"$dir\""
    fi
  elif ! (umask 022 && mkdir -p "$dir") 2>/dev/null; then
    die "cannot create $dir
  This needs root. Re-run with sudo:
    sudo $0 $ORIGINAL_ARGS"
  fi
  if [ ! -w "$dir" ]; then
    die "cannot write to $dir
  This needs root. Re-run with sudo:
    sudo $0 $ORIGINAL_ARGS"
  fi

  # Back up anything we did not write ourselves. A file we installed is
  # replaced, and the original backup reference carries forward so uninstall
  # still restores what the user actually had.
  backup=$(state_get_or_empty backup)
  ours_sha=$(state_get_or_empty sha256)
  if [ -f "$target" ] && [ "$(sha256 "$target")" != "$ours_sha" ]; then
    backup="$target.foxprivacy-backup-$(date +%Y%m%dT%H%M%S)"
    cp -p "$target" "$backup" || die "could not back up $target"
    info "backed up existing policies.json to $backup"
  fi

  printf '%s\n' "$body" > "$target.foxprivacy-tmp"
  chmod 644 "$target.foxprivacy-tmp"
  mv "$target.foxprivacy-tmp" "$target"

  write_state "$profile" "$target" "$backup" "$(sha256 "$target")" "$features"

  ok "installed the $profile profile to $target"
  info "$(count_words "$features") features enabled"
  printf '\n%sNext: quit Firefox completely, start it again, and open about:policies.%s\n' \
    "$C_BOLD" "$C_RESET"
  printf '%sThe Errors tab must be empty. That is the only proof Firefox accepted this.%s\n' \
    "$C_DIM" "$C_RESET"
}

cmd_uninstall() {
  target="${TARGET:-$(default_target)}"

  if [ ! -f "$(state_file)" ]; then
    if [ -f "$target" ]; then
      die "there is a policies.json at $target but FoxPrivacy has no record of
  installing it. Refusing to touch a file that is not ours. Remove it by hand
  if you want it gone."
    fi
    info "nothing to uninstall"
    return 0
  fi

  recorded_target=$(state_get target)
  backup=$(state_get backup)
  recorded_sha=$(state_get sha256)

  if [ -f "$recorded_target" ] && [ "$(sha256 "$recorded_target")" != "$recorded_sha" ] &&
     [ "$FORCE" != "1" ]; then
    die "$recorded_target has changed since FoxPrivacy installed it.
  Someone edited it, or another tool overwrote it. Refusing to remove it.
  Re-run with --force if you are sure."
  fi

  if [ "$DRY_RUN" = "1" ]; then
    printf '%sDry run. Nothing was removed.%s\n\n' "$C_BOLD" "$C_RESET"
    if [ -n "$backup" ]; then info "would restore: $backup -> $recorded_target"
    else info "would remove:  $recorded_target"; fi
    info "would remove:  $(state_file)"
    return 0
  fi

  if [ ! -w "$(dirname "$recorded_target")" ]; then
    die "cannot write to $(dirname "$recorded_target")
  This needs root. Re-run with sudo:
    sudo $0 $ORIGINAL_ARGS"
  fi

  if [ -n "$backup" ] && [ -f "$backup" ]; then
    mv "$backup" "$recorded_target"
    ok "restored the policies.json that was there before FoxPrivacy"
  else
    rm -f "$recorded_target"
    ok "removed $recorded_target"
    [ -n "$backup" ] && warn "the recorded backup $backup is gone, so nothing was restored"
  fi

  rm -f "$(state_file)"
  rmdir "$(default_state_dir)" 2>/dev/null || true
  printf '\n%sRestart Firefox. about:policies should now be empty.%s\n' "$C_DIM" "$C_RESET"
}

# ------------------------------------------------------------ interactive ----

interactive_render() {
  printf '\n%sFoxPrivacy %s%s  %s%s%s\n\n' \
    "$C_BOLD" "$FOXPRIVACY_VERSION" "$C_RESET" "$C_DIM" "$(default_target)" "$C_RESET"
  records | awk -F'|' -v sel=" $1 " -v r="$C_RESET" -v d="$C_DIM" \
      -v g="$C_GREEN" -v y="$C_YELLOW" -v bl="$C_BLUE" '
    {
      i++
      if (index(sel, " " $1 " ") > 0) { mark = "x"; colour = g } else { mark = " "; colour = d }
      printf " %s%2d%s %s[%s]%s %-26s %s\n", bl, i, r, colour, mark, r, $1, $2
      if ($4 != "") printf "        %scost: %s%s\n", y, $4, r
    }'
  printf '\n %s%s enabled%s\n' "$C_BOLD" "$(count_words "$1")" "$C_RESET"
  printf ' %snumber%s toggle   %ss%s standard   %st%s strict   %sa%s all   %sn%s none\n' \
    "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET" \
    "$C_BLUE" "$C_RESET"
  printf ' %sd%s details   %sp%s preview json   %si%s install   %sq%s quit\n\n' \
    "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET" "$C_BLUE" "$C_RESET"
}

interactive_details() {
  printf '\n'
  records | awk -F'|' -v sel=" $1 " -v b="$C_BOLD" -v r="$C_RESET" '
    index(sel, " " $1 " ") > 0 { printf " %s%s%s\n   %s\n", b, $1, r, $3 }'
  printf '\n'
}

id_at_index() { all_ids | sed -n "${1}p"; }

cmd_interactive() {
  standard_sel=$(sel_normalise "$(preset_ids standard | tr '\n' ' ')")
  strict_sel=$(sel_normalise "$(preset_ids strict | tr '\n' ' ')")
  sel="$standard_sel"
  total=$(all_ids | wc -l | tr -d ' ')

  while :; do
    interactive_render "$sel"
    printf '%s> %s' "$C_BOLD" "$C_RESET"
    if ! read -r choice; then printf '\n'; return 0; fi

    case "$choice" in
      q|Q|'') return 0 ;;
      s|S) sel="$standard_sel" ;;
      t|T) sel="$strict_sel" ;;
      a|A) sel=$(sel_normalise "$(all_ids | tr '\n' ' ')") ;;
      n|N) sel="" ;;
      d|D) interactive_details "$sel" ;;
      p|P)
        if [ -z "$sel" ]; then warn "nothing selected, there is nothing to preview"; continue; fi
        printf '\n'; build_json "$sel"; printf '\n'
        ;;
      i|I)
        if [ -z "$sel" ]; then warn "nothing selected"; continue; fi
        profile="custom"
        [ "$sel" = "$standard_sel" ] && profile="standard"
        [ "$sel" = "$strict_sel" ] && profile="strict"
        printf '\n'
        cmd_install "$profile" "$sel"
        return 0
        ;;
      *)
        if printf '%s' "$choice" | grep -Eq '^[0-9]+$' &&
           [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then
          sel=$(sel_normalise "$(sel_toggle "$sel" "$(id_at_index "$choice")")")
        else
          warn "not a choice: $choice"
        fi
        ;;
    esac
  done
}

# ------------------------------------------------------------------- cli ----

usage() {
  cat <<HELP
FoxPrivacy $FOXPRIVACY_VERSION - Firefox privacy configuration

  Run with no arguments for an interactive menu.

  $0 [options]

OPTIONS
  -i, --interactive      Pick features from a menu
  -p, --profile NAME     Install a preset: standard (default) or strict
      --enable IDS       Comma separated feature ids to add to the profile
      --disable IDS      Comma separated feature ids to remove from the profile
  -l, --list             Show every feature and what it costs
      --verify           Report whether the configuration is still installed
  -u, --uninstall        Restore what was there before FoxPrivacy
  -n, --dry-run          Print what would change and exit
      --target PATH      Write somewhere other than the platform default
      --force            Proceed even if the installed file was modified
  -v, --version          Print the version
  -h, --help             This text

EXAMPLES
  $0                                   interactive menu
  $0 --profile standard                install the safe defaults
  $0 --profile strict --disable captive-portal
  $0 --profile standard --enable search-suggestions,strict-tracking
  $0 --list
  $0 --verify
  $0 --uninstall

VERIFYING
  Restart Firefox and open about:policies. The Errors tab must be empty and
  the Active tab lists what is in effect. Nothing else proves Firefox accepted
  the configuration.
HELP
}

main() {
  ORIGINAL_ARGS="$*"
  action=""; profile="standard"; enable=""; disable=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -i|--interactive) action="interactive" ;;
      -u|--uninstall)   action="uninstall" ;;
      --verify)         action="verify" ;;
      -l|--list)        action="list" ;;
      -n|--dry-run)     DRY_RUN=1 ;;
      --force)          FORCE=1 ;;
      -p|--profile)     [ $# -ge 2 ] || die "--profile needs a name"; profile="$2"; shift ;;
      --enable)         [ $# -ge 2 ] || die "--enable needs feature ids"; enable="$2"; shift ;;
      --disable)        [ $# -ge 2 ] || die "--disable needs feature ids"; disable="$2"; shift ;;
      --target)         [ $# -ge 2 ] || die "--target needs a path"; TARGET="$2"; shift ;;
      -v|--version)     printf '%s\n' "$FOXPRIVACY_VERSION"; exit 0 ;;
      -h|--help)        usage; exit 0 ;;
      -*)               die "unknown option: $1. Try --help." ;;
      *)                die "unexpected argument: $1. Try --help." ;;
    esac
    shift
  done

  command -v awk >/dev/null 2>&1 || die "awk is required but not available"
  MANIFEST=$(load_manifest)
  [ -n "$MANIFEST" ] || die "the feature manifest is empty"
  RECORDS=$(printf '%s\n' "$MANIFEST" | awk "$AWK_RECORDS")
  [ -n "$RECORDS" ] || die "the feature manifest declares no features"

  case "$action" in
    list)      cmd_list; return 0 ;;
    verify)    cmd_verify; return $? ;;
    uninstall) cmd_uninstall; return 0 ;;
  esac

  # No verb and no arguments: a person at a terminal gets the menu.
  if [ -z "$action" ] && [ -z "$ORIGINAL_ARGS" ]; then
    if [ -t 0 ]; then action="interactive"; else usage; return 0; fi
  fi

  if [ "$action" = "interactive" ]; then cmd_interactive; return 0; fi

  preset_names | grep -qxF "$profile" ||
    die "unknown profile: $profile. Known profiles: $(preset_names | tr '\n' ' ')"

  sel=$(preset_ids "$profile" | tr '\n' ' ')

  # shellcheck disable=SC2086
  for _id in $(printf '%s' "$enable" | tr ',' ' '); do
    feature_exists "$_id" || die "unknown feature: $_id. Run --list to see them."
    sel=$(sel_add "$sel" "$_id")
  done
  # shellcheck disable=SC2086
  for _id in $(printf '%s' "$disable" | tr ',' ' '); do
    feature_exists "$_id" || die "unknown feature: $_id. Run --list to see them."
    sel=$(sel_remove "$sel" "$_id")
  done

  [ -z "$enable$disable" ] || profile="custom"
  cmd_install "$profile" "$(sel_normalise "$sel")"
}

main "$@"
exit $?
