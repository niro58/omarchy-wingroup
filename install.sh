#!/usr/bin/env bash
set -euo pipefail

WG_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# WG_SLOTS and WG_IDLE_HEAT_MAX: the same file bin/wingroup-waybar reads them
# from, so the bar it writes and the module that fills it cannot drift apart.
# WG_ROOT is resolved from this script's own path, so this works whatever
# directory install.sh is run from.
# shellcheck source=lib/constants.sh
source "$WG_ROOT/lib/constants.sh"

: "${WG_BIN_DIR:=$HOME/.local/bin}"
: "${WG_WAYBAR_CONFIG:=$HOME/.config/waybar/config.jsonc}"
: "${WG_WAYBAR_STYLE:=$HOME/.config/waybar/style.css}"
: "${WG_HYPR_BINDINGS:=$HOME/.config/hypr/bindings.conf}"
: "${WG_HYPR_AUTOSTART:=$HOME/.config/hypr/autostart.conf}"
: "${WG_STATE_DIR:=$HOME/.local/state/omarchy/wingroup}"
: "${WG_RESTORE_SCRIPT:=$HOME/restore-claude.sh}"
: "${WG_CLAUDE_SETTINGS:=$HOME/.claude/settings.json}"

WG_SIGNAL=11

# The SessionStart hook command registered in the Claude Code settings file.
# Written once: install matches on this exact string to stay idempotent, and
# uninstall matches on it to know which entry is ours and leave the rest alone.
WG_CLAUDE_HOOK_CMD="wingroup-hook"

# install.sh has never taken an argument, and the only reason it takes one now
# is that ~/.claude/settings.json is a file we did not create and the user may
# not want us in. Everything else install writes is wingroup's own or already
# marker-fenced; that file is neither, so it gets a way to say no.
WG_CLAUDE_HOOK=1
while (( $# )); do
  case $1 in
    --no-claude-hook) WG_CLAUDE_HOOK=0 ;;
    *)
      printf 'install.sh: unknown option: %s\nusage: install.sh [--no-claude-hook]\n' "$1" >&2
      exit 2 ;;
  esac
  shift
done

# The ramp itself, one declaration block per step, dimmest first: amber at one
# idle session, orange, red-orange, and a bright pure red at four-or-more, with
# opacity and weight climbing alongside the hue so a group full of finished
# sessions reads at a glance on a dark bar rather than only up close. Literal
# colours rather than the theme's @foreground: leaving the palette the rest of
# the bar sits in is the point. As many entries as WG_IDLE_HEAT_MAX.
WG_IDLE_HEAT_RAMP=(
  'color: #e0a458; opacity: 0.75;'
  'color: #ef8354; opacity: 0.85;'
  'color: #f45d48; opacity: 0.95; font-weight: 600;'
  'color: #ff3b30; opacity: 1; font-weight: bold;'
)

# A group holding a session systemd-oomd killed. Deliberately not another step
# on the ramp above: the ramp says how much work is waiting, and this says
# something was taken away from you, which is a different kind of fact and must
# not read as "five idle sessions". So it is the one rule in the block that
# fills the widget rather than only colouring its text -- a lit badge on the bar
# is categorically unlike a hotter label, and no amount of idle heat can be
# mistaken for it.
WG_CRASHED_STYLE='background: #7f1d1d; color: #ffd7d5; opacity: 1; font-weight: bold;'

# One declaration per step, or the module emits a class this script writes no
# rule for. The two numbers now come from the same file, so this can only fire
# if someone edits the ramp without editing lib/constants.sh.
if (( ${#WG_IDLE_HEAT_RAMP[@]} != WG_IDLE_HEAT_MAX )); then
  printf 'install.sh: WG_IDLE_HEAT_RAMP has %d entries but WG_IDLE_HEAT_MAX is %d\n' \
    "${#WG_IDLE_HEAT_RAMP[@]}" "$WG_IDLE_HEAT_MAX" >&2
  exit 1
fi

# What install_autostart actually wrote, for the closing summary: "both" when
# the restore line went in alongside the two unconditional ones, "daemon" when
# it did not, or empty when the block was already there.
WG_AUTOSTART_ADDED=""

# What install_claude_hook did, for the closing summary. The hook is the only
# source of exact session ids, so which of these happened changes what the
# feature can do afterwards and the user has to be told.
WG_CLAUDE_HOOK_RESULT=""

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

  local i base="" busy="" visible="" active="" crashed=""
  local -a heat=()
  for (( i = 0; i < WG_SLOTS; i++ )); do
    base+="${base:+, }#custom-wingroup$i"
    busy+="${busy:+, }#custom-wingroup$i.busy"
    visible+="${visible:+, }#custom-wingroup$i.visible"
    active+="${active:+, }#custom-wingroup$i.active"
    crashed+="${crashed:+, }#custom-wingroup$i.crashed"
  done
  # One selector list per step of the ramp, in step order: heat[0] is .idle1.
  local step sel
  for (( step = 1; step <= WG_IDLE_HEAT_MAX; step++ )); do
    sel=""
    for (( i = 0; i < WG_SLOTS; i++ )); do
      sel+="${sel:+, }#custom-wingroup$i.idle$step"
    done
    heat+=("$sel")
  done

  # Three states, dimmest first, because a group can only be in one of them:
  # "busy" is off screen with a session working, "visible" is on screen on a
  # monitor that does not have focus, "active" is the one being looked at.
  #
  # The idle ramp sits *between* the base rule and the three states, and that
  # ordering is the whole trick. A group carries a state class and an idle
  # class at once, and both selectors are one id plus one class -- equal
  # specificity, so the later rule wins each property they share. Coming
  # before the states, the ramp lifts the dimmed default for a group that has
  # work waiting in it, while "active" keeps the last word on opacity and
  # weight: an active group stays fully bright and bold, and merely takes the
  # ramp's colour with it. Coming after, it would dim the group you are
  # looking at -- the one thing the ramp must never do.
  #
  # "crashed" goes last, after the states, and that is the mirror of why the
  # ramp goes before them. The ramp had to yield to "active" because it would
  # otherwise dim and un-bold the group being looked at. This rule raises every
  # property it touches and lowers none -- full opacity, bold, a filled
  # background -- so it can safely take the last word, and it has to: a group
  # you are looking at is exactly the group whose lost session you most need to
  # be told about, and a crash outranks every other thing a button can say.
  #
  # Every rule here is one line with one selector list, so a user who wants a
  # different ramp restates the step they want *after* this block -- last rule
  # of equal specificity wins -- and never has to edit inside the markers.
  {
    printf '\n/* >>> wingroup */\n'
    printf '%s { padding: 0 6px; opacity: 0.55; }\n' "$base"
    for (( step = 0; step < WG_IDLE_HEAT_MAX; step++ )); do
      printf '%s { %s }\n' "${heat[step]}" "${WG_IDLE_HEAT_RAMP[step]}"
    done
    printf '%s { opacity: 1; }\n' "$busy"
    printf '%s { opacity: 0.85; }\n' "$visible"
    printf '%s { opacity: 1; font-weight: bold; }\n' "$active"
    printf '%s { %s }\n' "$crashed" "$WG_CRASHED_STYLE"
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

# The daemon and watcher lines are unconditional and always first. The watcher
# has to be started at login rather than on demand, because the only record of
# what was alive in a scope is the one it keeps while the session is still
# running: start it after the crash and there is nothing left to read.
#
# The restore line arranges
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
exec-once = wingroup-oomwatch
${restore_line}# <<< wingroup$eof_flag
EOF
}

# Registers bin/wingroup-hook as a Claude Code SessionStart hook.
#
# Without it crash detection still works -- the /proc scan learns that *some*
# claude process was running in a scope, and in which directory -- but it can
# never learn the session id, because only Claude Code knows that and only the
# hook is told it. So this is the difference between being handed back the
# session and being handed back the project it was in.
#
# ~/.claude/settings.json is the user's own file, full of things that have
# nothing to do with us, and losing it costs them their permissions, their
# model, their other hooks. So every failure mode here ends in "leave the file
# exactly as it is and carry on": a missing file, an unparseable file, a jq
# that errors, a temp file that will not write. None of them fail the install,
# because a window grouper that refuses to install over a settings file it did
# not like would be worse than one that quietly does less.
#
# The write is the same shape as wg_state_write's, and for the same reason:
# validate the *result* as JSON before it can reach the real path, write it to a
# temp file beside the target so the rename is atomic on the same filesystem,
# and rename rather than truncate-and-write, so an interrupted install cannot
# leave a half-file behind.
install_claude_hook() {
  if (( ! WG_CLAUDE_HOOK )); then
    WG_CLAUDE_HOOK_RESULT="declined"
    return 0
  fi
  if [[ ! -f $WG_CLAUDE_SETTINGS ]]; then
    WG_CLAUDE_HOOK_RESULT="no-settings"
    return 0
  fi
  if ! jq -e . "$WG_CLAUDE_SETTINGS" >/dev/null 2>&1; then
    WG_CLAUDE_HOOK_RESULT="unparseable"
    return 0
  fi

  # Idempotency is on the command string, not on the shape around it: a second
  # install must not add a second entry, and a user who moved our entry under a
  # matcher of their own still counts as having it.
  if jq -e --arg c "$WG_CLAUDE_HOOK_CMD" \
      'any(.hooks.SessionStart // [] | .[].hooks // [] | .[]; .command == $c)' \
      "$WG_CLAUDE_SETTINGS" >/dev/null 2>&1; then
    WG_CLAUDE_HOOK_RESULT="already"
    return 0
  fi

  # Appended as an entry of its own rather than merged into an existing one, so
  # nothing the user already had is rewritten -- uninstall then has a single
  # entry to take back out and cannot disturb theirs either.
  #
  # No "matcher": omitting it matches every way a session starts -- startup,
  # resume, clear, compact, fork -- and every one of those is a session that is
  # about to be alive in a scope and has to be recorded. A resumed session is
  # exactly the case that matters most: it is the one you got back after the
  # last crash.
  #
  # The timeout is ours to set and the default is ten minutes. The hook writes
  # one small JSON file; if it has not managed that in five seconds something is
  # wrong, and the right thing is to drop it and let the session start.
  local updated
  # shellcheck disable=SC2016  # $c is a jq variable, not a shell one
  updated="$(jq --arg c "$WG_CLAUDE_HOOK_CMD" '
      .hooks //= {}
    | .hooks.SessionStart //= []
    | .hooks.SessionStart += [{hooks: [{type: "command", command: $c, timeout: 5}]}]
  ' "$WG_CLAUDE_SETTINGS" 2>/dev/null)" || {
    WG_CLAUDE_HOOK_RESULT="failed"
    return 0
  }
  if ! jq -e . >/dev/null 2>&1 <<<"$updated"; then
    WG_CLAUDE_HOOK_RESULT="failed"
    return 0
  fi

  local tmp
  tmp="$(mktemp "$(dirname -- "$WG_CLAUDE_SETTINGS")/.wingroup.XXXXXX")" || {
    WG_CLAUDE_HOOK_RESULT="failed"
    return 0
  }
  if ! printf '%s\n' "$updated" >"$tmp"; then
    rm -f "$tmp"
    WG_CLAUDE_HOOK_RESULT="failed"
    return 0
  fi
  # Guarded, unlike every other backup call in this script, because this is the
  # one file that is not ours. `backup` is a bare command under `set -e`, so a
  # failed cp here would abort the whole install -- the single outcome this
  # function is written to make impossible -- and leak the temp file with it.
  if ! backup "$WG_CLAUDE_SETTINGS"; then
    rm -f "$tmp"
    WG_CLAUDE_HOOK_RESULT="failed"
    return 0
  fi
  # mktemp makes the temp file 0600 and mv carries that across. Tightening a
  # file we did not create is still changing it behind the user's back, so the
  # mode of what we are replacing is copied over first.
  chmod --reference="$WG_CLAUDE_SETTINGS" "$tmp" 2>/dev/null || true
  if ! mv -f "$tmp" "$WG_CLAUDE_SETTINGS"; then
    rm -f "$tmp"
    WG_CLAUDE_HOOK_RESULT="failed"
    return 0
  fi
  WG_CLAUDE_HOOK_RESULT="added"
}

seed_state() {
  mkdir -p "$WG_STATE_DIR"
  [[ -f "$WG_STATE_DIR/state.json" ]] && return 0
  printf '%s\n' '{"auto":true,"follow":true,"catchall":null,"groups":[],"overrides":{}}' >"$WG_STATE_DIR/state.json"
}

link_binaries
install_waybar_config
install_waybar_style
install_bindings
install_autostart
install_claude_hook
seed_state

printf 'wingroup installed. Reload with: hyprctl reload && pkill -SIGUSR2 waybar\n'
case $WG_AUTOSTART_ADDED in
  both)
    printf 'Autostart (%s): added "exec-once = wingroup-daemon", "exec-once = wingroup-oomwatch" and "exec-once = wingroup-restore".\n' \
      "$WG_HYPR_AUTOSTART" ;;
  daemon)
    printf 'Autostart (%s): added "exec-once = wingroup-daemon" and "exec-once = wingroup-oomwatch".\n' \
      "$WG_HYPR_AUTOSTART"
    printf '  No executable restore script at %s, so "exec-once = wingroup-restore" was left out.\n' \
      "$WG_RESTORE_SCRIPT"
    printf '  To enable it later, see "Startup integration" in the README.\n' ;;
  *)
    printf 'Autostart (%s): already configured, left unchanged.\n' "$WG_HYPR_AUTOSTART" ;;
esac
# Say which of these happened either way. Every outcome but "added" leaves crash
# detection able to name the project a lost session was in but not the session
# itself, and that is a difference the user should hear about now rather than
# discover the first time they lose one.
case $WG_CLAUDE_HOOK_RESULT in
  added)
    printf 'Claude Code hook (%s): registered "%s" on SessionStart.\n' \
      "$WG_CLAUDE_SETTINGS" "$WG_CLAUDE_HOOK_CMD" ;;
  already)
    printf 'Claude Code hook (%s): already registered, left unchanged.\n' "$WG_CLAUDE_SETTINGS" ;;
  declined)
    printf 'Claude Code hook: skipped (--no-claude-hook).\n'
    printf '  Crashed sessions will be detected, but only by project, not by session id.\n' ;;
  no-settings)
    printf 'Claude Code hook: no settings file at %s, so nothing was registered.\n' \
      "$WG_CLAUDE_SETTINGS"
    printf '  Crashed sessions will be detected, but only by project, not by session id.\n' ;;
  unparseable)
    printf 'Claude Code hook: %s is not valid JSON, so it was left untouched.\n' \
      "$WG_CLAUDE_SETTINGS"
    printf '  Fix or remove it and re-run ./install.sh to register the hook.\n' ;;
  failed)
    printf 'Claude Code hook: could not update %s, which is unchanged.\n' "$WG_CLAUDE_SETTINGS"
    printf '  See "Crashed sessions" in the README for the entry to add by hand.\n' ;;
esac
printf 'Then create your first group, e.g.: wingroup new shop shop-web shop-api\n'
printf 'and file the windows you already have open: wingroup tidy\n'
