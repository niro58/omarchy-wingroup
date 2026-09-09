#!/usr/bin/env bash
set -euo pipefail

WG_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

: "${WG_BIN_DIR:=$HOME/.local/bin}"
: "${WG_WAYBAR_CONFIG:=$HOME/.config/waybar/config.jsonc}"
: "${WG_WAYBAR_STYLE:=$HOME/.config/waybar/style.css}"
: "${WG_HYPR_BINDINGS:=$HOME/.config/hypr/bindings.conf}"
: "${WG_HYPR_AUTOSTART:=$HOME/.config/hypr/autostart.conf}"
: "${WG_STATE_DIR:=$HOME/.local/state/omarchy/wingroup}"
: "${WG_RESTORE_SCRIPT:=$HOME/restore-claude.sh}"

WG_SLOTS=8
WG_SIGNAL=11

# What install_autostart actually wrote, for the closing summary: "both",
# "daemon", or empty when the block was already there.
WG_AUTOSTART_ADDED=""

backup() {
  [[ -f $1 ]] || return 0
  cp -p "$1" "$1.bak.$(date +%s)"
}

# True (exit 0) if the file's last byte is a newline. A missing or empty file
# counts as "has a newline" -- there is nothing to preserve either way.
wg_ends_with_newline() {
  local f="$1"
  [[ -s "$f" ]] || return 0
  [[ "$(tail -c1 -- "$f" | wc -l)" -eq 1 ]]
}

link_binaries() {
  mkdir -p "$WG_BIN_DIR"
  local f
  for f in "$WG_ROOT"/bin/*; do
    ln -sfn "$f" "$WG_BIN_DIR/$(basename "$f")"
  done
}

# $1: suffix to append to the closing marker line (e.g. " no-eof-nl"). Every
# append/rewrite this script does ends the file in a newline, even when the
# original did not -- so uninstall.sh reads this suffix off the closing marker
# to know whether it must strip that trailing newline back off to reverse
# byte-exactly.
waybar_modules_block() {
  local eof_flag="$1" i
  printf '  // >>> wingroup\n'
  for (( i = 0; i < WG_SLOTS; i++ )); do
    printf '  "custom/wingroup%d": {\n' "$i"
    printf '    "exec": "wingroup-waybar %d",\n' "$i"
    printf '    "return-type": "json",\n'
    printf '    "interval": "once",\n'
    printf '    "signal": %d,\n' "$WG_SIGNAL"
    printf '    "on-click": "wingroup activate %d",\n' "$i"
    printf '    "on-click-right": "wingroup menu",\n'
    printf '    "tooltip": true\n'
    printf '  },\n'
  done
  printf '  // <<< wingroup%s\n' "$eof_flag"
}

# A group is a *named* Hyprland workspace, and Omarchy's "hyprland/workspaces"
# module keys its format-icons by workspace number -- so every group falls
# through to the "default" glyph and draws as an anonymous dot, one per group,
# right next to that group's own name in the strip. Two views of the same
# thing, and the dot is the useless one.
#
# The numbers themselves stay: 1..10 are the user's own, nothing to do with
# groups. "ignore-workspaces" holds regexes matched against the *whole*
# workspace name -- waybar's own manual gives a complete name as its example --
# so the pattern has to describe the entire name, not a prefix of it.
# ".*[^0-9].*" reads "contains at least one non-digit": it drops every named
# workspace and keeps 1..10. Two earlier attempts were wrong and both showed up
# as dots still on the bar: "^[^0-9]" matches a single character, so under
# whole-name matching it matches nothing at all; "^[^0-9].*" then missed a group
# whose name starts with a digit, like "3dprint". (Verified present in the
# waybar 0.15.0 build this targets: strings on the binary matches
# "ignore-workspaces".)
#
# The markers are the same pair uninstall.sh's strip_block already looks for,
# and it strips every block it finds, so this one needs nothing new to reverse
# it. It carries no eof flag -- only the definitions block does, and one flagged
# closing marker anywhere in the file is what strip_block reads.
waybar_ignore_block() {
  printf '    // >>> wingroup\n'
  printf '    "ignore-workspaces": [".*[^0-9].*"],\n'
  printf '    // <<< wingroup\n'
}

install_waybar_config() {
  grep -q 'custom/wingroup0' "$WG_WAYBAR_CONFIG" && return 0

  local eof_flag=""
  wg_ends_with_newline "$WG_WAYBAR_CONFIG" || eof_flag=" no-eof-nl"

  local slots i tmp
  slots=""
  for (( i = 0; i < WG_SLOTS; i++ )); do
    slots+=", \"custom/wingroup$i\""
  done

  # Three edits, one pass.
  #
  # The definitions go in right after the line that opens the top-level object.
  # That is not necessarily line 1: JSONC positively invites a leading comment,
  # and a blank line or a BOM is legal too. Skip blank and comment lines, then
  # anchor on the first line that contains a brace.
  #
  # The slots are appended to "modules-left", after whatever is already there.
  # "hyprland/workspaces" stays and stays where it is: that ordering is what
  # puts the numbered workspaces first and the group strip after them.
  #
  # The "ignore-workspaces" line goes inside the "hyprland/workspaces" object,
  # which is why that object's opening line has to be findable. See
  # waybar_ignore_block for what it is for.
  #
  # Values reach awk through the environment, not -v: an -v assignment runs
  # escape processing over its value, and these blocks are verbatim text that
  # must survive unaltered.
  tmp="$(mktemp)"
  wg_slots="$slots" \
  wg_block="$(waybar_modules_block "$eof_flag")" \
  wg_ignore="$(waybar_ignore_block)" awk '
    !inserted && $0 !~ /^[[:space:]]*(\/\/|\/\*|\*)/ && index($0, "{") > 0 {
      print; print ENVIRON["wg_block"]; inserted = 1; next
    }
    /"modules-left"[[:space:]]*:/ {
      sub(/\][[:space:]]*,[[:space:]]*$/, ENVIRON["wg_slots"] "],")
      print; next
    }
    !ignored && /"hyprland\/workspaces"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ {
      print; print ENVIRON["wg_ignore"]; ignored = 1; next
    }
    { print }
  ' "$WG_WAYBAR_CONFIG" >"$tmp"

  # Every part of the edit has to have landed. The sub() above only fires when
  # the modules-left line is a single line ending in "],", the definitions only
  # go in when an opening brace was found, and the ignore line only goes in
  # when the "hyprland/workspaces" object opens on a line of its own. Any part
  # alone ships a bar that is wrong -- slots wired to modules that do not
  # exist, modules nothing displays, or a dot per group next to the names --
  # and the idempotency guard would then refuse to repair it. So check for all
  # three, and on failure say which is missing and touch nothing.
  local missing="" defs
  defs="$(grep -cE '"custom/wingroup[0-9]+"[[:space:]]*:[[:space:]]*\{' "$tmp" || true)"
  grep -qE '"modules-left"[[:space:]]*:.*"custom/wingroup0"' "$tmp" \
    || missing+=$'\n  - the '"$WG_SLOTS"$' wingroup slots in "modules-left": it must be a single line ending in "],"'
  (( defs == WG_SLOTS )) \
    || missing+=$'\n  - the '"$WG_SLOTS"$' "custom/wingroupN": { ... } module definitions (found '"$defs"$'): they are inserted after the line that opens the top-level object'
  grep -qF '"ignore-workspaces"' "$tmp" \
    || missing+=$'\n  - the "ignore-workspaces" entry that hides named group workspaces from the numbered indicator: it goes inside the "hyprland/workspaces" object, whose opening line must read \'"hyprland/workspaces": {\''
  if [[ -n $missing ]]; then
    rm -f "$tmp"
    printf 'install.sh: cannot edit %s. Missing after the attempted edit:%s\nNo changes were made.\n' \
      "$WG_WAYBAR_CONFIG" "$missing" >&2
    exit 1
  fi

  backup "$WG_WAYBAR_CONFIG"
  if [[ -n $eof_flag ]]; then
    truncate -s -1 "$tmp"
  fi
  mv -f "$tmp" "$WG_WAYBAR_CONFIG"
}

install_waybar_style() {
  grep -q '>>> wingroup' "$WG_WAYBAR_STYLE" && return 0

  local eof_flag=""
  wg_ends_with_newline "$WG_WAYBAR_STYLE" || eof_flag=" no-eof-nl"

  backup "$WG_WAYBAR_STYLE"

  local i base="" busy="" visible="" active=""
  for (( i = 0; i < WG_SLOTS; i++ )); do
    base+="${base:+, }#custom-wingroup$i"
    busy+="${busy:+, }#custom-wingroup$i.busy"
    visible+="${visible:+, }#custom-wingroup$i.visible"
    active+="${active:+, }#custom-wingroup$i.active"
  done

  # Three states, dimmest first, because a group can only be in one of them:
  # "busy" is off screen with a session working, "visible" is on screen on a
  # monitor that does not have focus, "active" is the one being looked at.
  {
    printf '\n/* >>> wingroup */\n'
    printf '%s { padding: 0 6px; opacity: 0.55; }\n' "$base"
    printf '%s { opacity: 1; }\n' "$busy"
    printf '%s { opacity: 0.85; }\n' "$visible"
    printf '%s { opacity: 1; font-weight: bold; }\n' "$active"
    printf '/* <<< wingroup%s */\n' "$eof_flag"
  } >>"$WG_WAYBAR_STYLE"
}

install_bindings() {
  grep -q '>>> wingroup' "$WG_HYPR_BINDINGS" && return 0

  local eof_flag=""
  wg_ends_with_newline "$WG_HYPR_BINDINGS" || eof_flag=" no-eof-nl"

  backup "$WG_HYPR_BINDINGS"
  cat >>"$WG_HYPR_BINDINGS" <<EOF

# >>> wingroup
unbind = SUPER, G
bindd = SUPER, G, Window groups, exec, wingroup menu
bindd = SUPER CTRL, G, Send window to group, exec, wingroup send
# <<< wingroup$eof_flag
EOF
}

# The daemon line is unconditional and always first. The restore line arranges
# to run $WG_RESTORE_SCRIPT at every login, so it only goes in for someone who
# actually has that script -- opting a stranger into respawning terminals at
# login is a surprising thing for a window grouper to do. $restore_line keeps
# its own trailing newline so the closing marker, and the eof_flag that
# uninstall.sh reads off it to reverse this byte-exactly, land either way.
install_autostart() {
  grep -q '>>> wingroup' "$WG_HYPR_AUTOSTART" && return 0

  local eof_flag=""
  wg_ends_with_newline "$WG_HYPR_AUTOSTART" || eof_flag=" no-eof-nl"

  local restore_line=""
  if [[ -x $WG_RESTORE_SCRIPT ]]; then
    restore_line="exec-once = wingroup-restore"$'\n'
    WG_AUTOSTART_ADDED="both"
  else
    WG_AUTOSTART_ADDED="daemon"
  fi

  backup "$WG_HYPR_AUTOSTART"
  cat >>"$WG_HYPR_AUTOSTART" <<EOF

# >>> wingroup
exec-once = wingroup-daemon
${restore_line}# <<< wingroup$eof_flag
EOF
}

seed_state() {
  mkdir -p "$WG_STATE_DIR"
  [[ -f "$WG_STATE_DIR/state.json" ]] && return 0
  printf '%s\n' '{"auto":true,"catchall":null,"groups":[],"overrides":{}}' >"$WG_STATE_DIR/state.json"
}

link_binaries
install_waybar_config
install_waybar_style
install_bindings
install_autostart
seed_state

printf 'wingroup installed. Reload with: hyprctl reload && pkill -SIGUSR2 waybar\n'
case $WG_AUTOSTART_ADDED in
  both)
    printf 'Autostart (%s): added "exec-once = wingroup-daemon" and "exec-once = wingroup-restore".\n' \
      "$WG_HYPR_AUTOSTART" ;;
  daemon)
    printf 'Autostart (%s): added "exec-once = wingroup-daemon".\n' "$WG_HYPR_AUTOSTART"
    printf '  No executable restore script at %s, so "exec-once = wingroup-restore" was left out.\n' \
      "$WG_RESTORE_SCRIPT"
    printf '  To enable it later, see "Startup integration" in the README.\n' ;;
  *)
    printf 'Autostart (%s): already configured, left unchanged.\n' "$WG_HYPR_AUTOSTART" ;;
esac
printf 'Then create your first group, e.g.: wingroup new everest everest-web everest-rs\n'
printf 'and file the windows you already have open: wingroup tidy\n'
