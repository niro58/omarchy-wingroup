#!/usr/bin/env bats

load helper

# A settings file shaped like a real one: two keys that have nothing to do with
# wingroup, a hook for a different event, and a SessionStart hook of the user's
# own. All four have to come through install untouched, and the user's
# SessionStart entry has to survive uninstall as well -- that is the entry a
# careless filter would take out along with ours.
wg_seed_settings() {
  cat >"$WG_CLAUDE_SETTINGS" <<'JSON'
{
  "model": "opus",
  "permissions": { "allow": ["Bash(ls:*)"] },
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "their-pretool" } ] }
    ],
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "their-session-start" } ] }
    ]
  }
}
JSON
}

# How many SessionStart entries run wingroup-hook, counted across every entry
# and every matcher -- so a second install adding a second entry is caught
# wherever it puts it.
wg_hook_count() {
  jq '[.hooks.SessionStart // [] | .[].hooks // [] | .[] | select(.command == "wingroup-hook")] | length' \
    "$WG_CLAUDE_SETTINGS"
}

setup() {
  wg_setup_tmp
  export WG_BIN_DIR="$WG_TMP/bin"
  export WG_WAYBAR_CONFIG="$WG_TMP/config.jsonc"
  export WG_WAYBAR_STYLE="$WG_TMP/style.css"
  export WG_HYPR_BINDINGS="$WG_TMP/bindings.conf"
  export WG_HYPR_AUTOSTART="$WG_TMP/autostart.conf"
  # Never the real one: whether it exists decides what install writes.
  export WG_RESTORE_SCRIPT="$WG_TMP/restore-claude.sh"
  # Never the real ~/.claude/settings.json. Install writes into this file, so a
  # test that let it default would register the hook in the settings of the
  # machine running the suite -- and back that file up on every single case.
  export WG_CLAUDE_SETTINGS="$WG_TMP/claude-settings.json"
  wg_seed_settings
  cp "$WG_CLAUDE_SETTINGS" "$WG_TMP/claude-settings.orig"
  cp "$WG_FIXTURES/waybar-config.jsonc" "$WG_WAYBAR_CONFIG"
  cp "$WG_FIXTURES/waybar-style.css" "$WG_WAYBAR_STYLE"
  printf '# my bindings\n' >"$WG_HYPR_BINDINGS"
  printf '# my autostart\n' >"$WG_HYPR_AUTOSTART"
  cp "$WG_WAYBAR_CONFIG" "$WG_TMP/config.orig"
  cp "$WG_WAYBAR_STYLE" "$WG_TMP/style.orig"
  cp "$WG_HYPR_BINDINGS" "$WG_TMP/bindings.orig"
  cp "$WG_HYPR_AUTOSTART" "$WG_TMP/autostart.orig"
}

teardown() { wg_teardown_tmp; }

# link_binaries globs bin/, so the assertion globs it too rather than naming a
# count that goes stale the next time an executable is added -- which is what
# had already happened to this test.
@test "install links every executable in bin/" {
  "$WG_ROOT/install.sh"
  local f n=0
  for f in "$WG_ROOT"/bin/*; do
    [ -L "$WG_BIN_DIR/$(basename "$f")" ]
    [ -x "$WG_BIN_DIR/$(basename "$f")" ]
    n=$(( n + 1 ))
  done
  # a glob that matched nothing would have asserted nothing
  [ "$n" -gt 0 ]
}

# link_binaries globs bin/, so these come along with the rest -- but they are
# what makes crash detection work at all, and a rename or a missing +x would
# otherwise only show up as the feature silently doing nothing at login.
@test "install links the crash-detection executables too" {
  "$WG_ROOT/install.sh"
  [ -L "$WG_BIN_DIR/wingroup-oomwatch" ]
  [ -L "$WG_BIN_DIR/wingroup-hook" ]
  [ -x "$WG_BIN_DIR/wingroup-oomwatch" ]
  [ -x "$WG_BIN_DIR/wingroup-hook" ]
}

# The numbered workspaces are the user's own and stay on the bar. Left to
# right: the Omarchy menu icon, then 1..0, then the group strip -- which is
# exactly the order "modules-left" already had plus the slots appended.
@test "install keeps hyprland/workspaces where it was and appends the slots after it" {
  "$WG_ROOT/install.sh"
  run bash -c "grep -E '\"modules-left\"' '$WG_WAYBAR_CONFIG'"
  [ "$output" = '  "modules-left": ["custom/omarchy", "hyprland/workspaces", "custom/wingroup0", "custom/wingroup1", "custom/wingroup2", "custom/wingroup3", "custom/wingroup4", "custom/wingroup5", "custom/wingroup6", "custom/wingroup7"],' ]
}

# A group is a *named* workspace, and the numbered module has no icon for a
# name -- it falls through to the "default" glyph and draws an anonymous dot
# per group, next to that group's own name in the strip. "ignore-workspaces"
# takes the dots away and leaves 1..0 alone.
@test "install hides the named group workspaces from the numbered indicator" {
  "$WG_ROOT/install.sh"
  run bash -c "grep -A3 '\"hyprland/workspaces\": {' '$WG_WAYBAR_CONFIG'"
  [[ "$output" == *'"ignore-workspaces": [".*[^0-9].*"]'* ]]
  # inside the object it belongs to, not loose in the file
  run bash -c "grep -c 'ignore-workspaces' '$WG_WAYBAR_CONFIG'"
  [ "$output" -eq 1 ]
}

# The pattern, read back out of the config exactly as installed.
installed_ignore_pattern() {
  sed -n 's/.*"ignore-workspaces": \["\(.*\)"\].*/\1/p' "$WG_WAYBAR_CONFIG"
}

# Waybar matches an "ignore-workspaces" pattern against the *whole* workspace
# name -- its own manual's example is a complete name -- so "hidden" means the
# pattern consumes the entire name, not just a prefix of it. Checking
# BASH_REMATCH covers both readings at once: a pattern that only matches under
# search semantics matches here too, but leaves a partial BASH_REMATCH behind.
pattern_hides() {
  local pattern="$1" name="$2"
  [[ $name =~ $pattern ]] || return 1
  [[ ${BASH_REMATCH[0]} == "$name" ]]
}

# Asserting the line is present is what let two broken patterns ship. "^[^0-9]"
# matches one character, so under whole-name matching it hid nothing at all;
# "^[^0-9].*" then left the dot for a group named "3dprint". So assert what the
# pattern does, on a name that starts with a digit as well as ones that do not.
@test "the installed pattern hides every group name, digit-leading ones included" {
  "$WG_ROOT/install.sh"
  local pattern name
  pattern="$(installed_ignore_pattern)"
  [ -n "$pattern" ]
  for name in site mgmt template other 3dprint niro-3d-print; do
    pattern_hides "$pattern" "$name" || {
      printf 'pattern %s does not hide workspace %s\n' "$pattern" "$name" >&2
      return 1
    }
  done
}

@test "the installed pattern leaves the numbered workspaces alone" {
  "$WG_ROOT/install.sh"
  local pattern name
  pattern="$(installed_ignore_pattern)"
  for name in 1 6 10 0; do
    # Neither whole-name nor search matching may touch a purely numeric name.
    ! pattern_hides "$pattern" "$name" || {
      printf 'pattern %s wrongly hides workspace %s\n' "$pattern" "$name" >&2
      return 1
    }
    ! [[ $name =~ $pattern ]] || {
      printf 'pattern %s matches inside workspace %s\n' "$pattern" "$name" >&2
      return 1
    }
  done
}

@test "uninstall takes the ignore-workspaces line back out" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
  run bash -c "grep -c 'ignore-workspaces' '$WG_WAYBAR_CONFIG' || true"
  [ "$output" -eq 0 ]
  run bash -c "grep -E '\"modules-left\"' '$WG_WAYBAR_CONFIG'"
  [ "$output" = '  "modules-left": ["custom/omarchy", "hyprland/workspaces"],' ]
}

@test "install adds eight slots to modules-left and eight module definitions" {
  "$WG_ROOT/install.sh"
  run bash -c "grep -o 'custom/wingroup[0-9]' '$WG_WAYBAR_CONFIG' | sort -u | wc -l"
  [ "$output" -eq 8 ]
  run bash -c "grep -c '\"custom/wingroup[0-9]\": {' '$WG_WAYBAR_CONFIG'"
  [ "$output" -eq 8 ]
}

@test "the installed waybar config is still valid JSONC that waybar can read" {
  "$WG_ROOT/install.sh"
  run bash -c "sed 's|//.*||' '$WG_WAYBAR_CONFIG' | jq -e . >/dev/null"
  [ "$status" -eq 0 ]
}

@test "install uses signal 11, not one Omarchy already claims" {
  "$WG_ROOT/install.sh"
  run bash -c "grep -c '\"signal\": 11' '$WG_WAYBAR_CONFIG'"
  [ "$output" -eq 8 ]
  run bash -c "grep -cE '\"signal\": (7|8|9|10),' '$WG_WAYBAR_CONFIG' || true"
  [ "$output" -eq 0 ]
}

@test "install adds the keybinds and the daemon autostart" {
  "$WG_ROOT/install.sh"
  grep -q 'bindd = SUPER, G, Window groups, exec, wingroup menu' "$WG_HYPR_BINDINGS"
  grep -q 'unbind = SUPER, G' "$WG_HYPR_BINDINGS"
  grep -q 'exec-once = wingroup-daemon' "$WG_HYPR_AUTOSTART"
}

# The restore line arranges to run ~/restore-claude.sh at every login. Adding
# it for someone who has no such script is a surprising side effect of
# installing a window grouper, so it is opt-in by having the script.

@test "install leaves the restore autostart out when there is no restore script" {
  run "$WG_ROOT/install.sh"
  [ "$status" -eq 0 ]
  run bash -c "grep -c 'exec-once = wingroup-restore' '$WG_HYPR_AUTOSTART' || true"
  [ "$output" -eq 0 ]
  run bash -c "grep -c 'exec-once = wingroup-daemon' '$WG_HYPR_AUTOSTART'"
  [ "$output" -eq 1 ]
}

@test "install says which autostart lines it added when it skips the restore line" {
  run "$WG_ROOT/install.sh"
  [[ "$output" == *'added "exec-once = wingroup-daemon" and "exec-once = wingroup-oomwatch"'* ]]
  [[ "$output" == *'"exec-once = wingroup-restore" was left out'* ]]
  [[ "$output" == *"$WG_RESTORE_SCRIPT"* ]]
}

@test "install adds the restore autostart when an executable restore script exists" {
  printf '#!/usr/bin/env bash\n' >"$WG_RESTORE_SCRIPT"
  chmod +x "$WG_RESTORE_SCRIPT"

  run "$WG_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'added "exec-once = wingroup-daemon", "exec-once = wingroup-oomwatch" and "exec-once = wingroup-restore"'* ]]

  grep -q 'exec-once = wingroup-daemon' "$WG_HYPR_AUTOSTART"
  grep -q 'exec-once = wingroup-restore' "$WG_HYPR_AUTOSTART"
  # the daemon line comes first
  run bash -c "grep -n 'exec-once' '$WG_HYPR_AUTOSTART' | head -1"
  [[ "$output" == *wingroup-daemon* ]]
}

@test "a non-executable restore script does not count" {
  printf '#!/usr/bin/env bash\n' >"$WG_RESTORE_SCRIPT"
  chmod -x "$WG_RESTORE_SCRIPT"
  "$WG_ROOT/install.sh"
  run bash -c "grep -c 'exec-once = wingroup-restore' '$WG_HYPR_AUTOSTART' || true"
  [ "$output" -eq 0 ]
}

@test "uninstall reverses the autostart byte for byte with the restore line present" {
  printf '#!/usr/bin/env bash\n' >"$WG_RESTORE_SCRIPT"
  chmod +x "$WG_RESTORE_SCRIPT"
  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
  run cmp "$WG_TMP/autostart.orig" "$WG_HYPR_AUTOSTART"
  [ "$status" -eq 0 ]
}

@test "uninstall reverses the autostart byte for byte without the restore line" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
  run cmp "$WG_TMP/autostart.orig" "$WG_HYPR_AUTOSTART"
  [ "$status" -eq 0 ]
}

# A group can be on screen on a monitor that does not have focus. That is its
# own state, between the dimmed default and the focused group, and it needs a
# rule of its own or the class the bar emits styles nothing.
@test "install styles all three of busy, visible and active" {
  "$WG_ROOT/install.sh"
  run bash -c "grep -c '#custom-wingroup0.busy' '$WG_WAYBAR_STYLE'"
  [ "$output" -eq 1 ]
  run bash -c "grep -c '#custom-wingroup0.visible' '$WG_WAYBAR_STYLE'"
  [ "$output" -eq 1 ]
  run bash -c "grep -c '#custom-wingroup0.active' '$WG_WAYBAR_STYLE'"
  [ "$output" -eq 1 ]
  # Dimmer than the focused group, brighter than a group that is out of sight.
  run bash -c "grep -A1 'wingroup0.visible' '$WG_WAYBAR_STYLE' | head -n1"
  [[ "$output" == *"opacity: 0.85"* ]]
}

# Idle sessions are unused capacity, so the button warms up as they pile up.
# Every step the module can emit needs a rule, or a group four sessions deep
# carries a class that styles nothing.
@test "install writes the idle heat ramp, one rule per step" {
  "$WG_ROOT/install.sh"
  local step
  for step in 1 2 3 4; do
    run bash -c "grep -c '#custom-wingroup0.idle$step' '$WG_WAYBAR_STYLE'"
    [ "$output" -eq 1 ]
    run bash -c "grep -c '#custom-wingroup7.idle$step' '$WG_WAYBAR_STYLE'"
    [ "$output" -eq 1 ]
  done
}

# Warm at one, unmistakably red and bright at the ceiling.
@test "the ramp runs from warm to bright red across its four steps" {
  "$WG_ROOT/install.sh"
  run bash -c "grep '#custom-wingroup0.idle1' '$WG_WAYBAR_STYLE'"
  [[ "$output" == *"#e0a458"* ]]
  [[ "$output" == *"opacity: 0.75"* ]]
  run bash -c "grep '#custom-wingroup0.idle4' '$WG_WAYBAR_STYLE'"
  [[ "$output" == *"#ff3b30"* ]]
  [[ "$output" == *"opacity: 1"* ]]
  [[ "$output" == *"font-weight: bold"* ]]
}

# A group can be the one you are looking at *and* have four sessions waiting in
# it. Both selectors are one id plus one class, so the later rule wins whatever
# they share: the ramp has to come first, or it would dim and un-bold the
# active group -- the one thing it must never do.
@test "the ramp is written before the state rules so active keeps its opacity and bold" {
  "$WG_ROOT/install.sh"
  local heat active
  heat="$(grep -n '#custom-wingroup0.idle4' "$WG_WAYBAR_STYLE" | cut -d: -f1)"
  active="$(grep -n '#custom-wingroup0.active' "$WG_WAYBAR_STYLE" | cut -d: -f1)"
  [ "$heat" -lt "$active" ]
}

# The ramp is inside the marked block like everything else install writes, so
# uninstall takes it back out with the rest and the file is what it was.
@test "uninstall takes the idle ramp back out" {
  "$WG_ROOT/install.sh"
  run bash -c "grep -c 'idle4' '$WG_WAYBAR_STYLE'"
  [ "$output" -eq 1 ]
  "$WG_ROOT/uninstall.sh"
  run bash -c "grep -c 'idle' '$WG_WAYBAR_STYLE'"
  [ "$status" -ne 0 ]
  run diff "$WG_TMP/style.orig" "$WG_WAYBAR_STYLE"
  [ "$status" -eq 0 ]
}

@test "install backs up every file it edits" {
  "$WG_ROOT/install.sh"
  run bash -c "ls $WG_TMP/config.jsonc.bak.* | wc -l"
  [ "$output" -eq 1 ]
}

@test "install is idempotent" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/install.sh"
  run bash -c "grep -o 'custom/wingroup0' '$WG_WAYBAR_CONFIG' | wc -l"
  [ "$output" -eq 2 ]
  run bash -c "grep -c 'ignore-workspaces' '$WG_WAYBAR_CONFIG'"
  [ "$output" -eq 1 ]
  run bash -c "grep -cE '\"modules-left\".*custom/wingroup7' '$WG_WAYBAR_CONFIG'"
  [ "$output" -eq 1 ]
  run bash -c "grep -c 'exec-once = wingroup-daemon' '$WG_HYPR_AUTOSTART'"
  [ "$output" -eq 1 ]
  run bash -c "grep -c 'bindd = SUPER, G, Window groups' '$WG_HYPR_BINDINGS'"
  [ "$output" -eq 1 ]
}

@test "install seeds the state file only when it is absent" {
  "$WG_ROOT/install.sh"
  [ -f "$WG_STATE_DIR/state.json" ]
  wg_state_marker="$(jq -r '.auto' "$WG_STATE_DIR/state.json")"
  [ "$wg_state_marker" = "true" ]
  jq '.auto = false' "$WG_STATE_DIR/state.json" >"$WG_TMP/s" && mv "$WG_TMP/s" "$WG_STATE_DIR/state.json"
  "$WG_ROOT/install.sh"
  run bash -c "jq -r '.auto' '$WG_STATE_DIR/state.json'"
  [ "$output" = "false" ]
}

@test "uninstall restores every file byte for byte" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
  run diff "$WG_TMP/config.orig" "$WG_WAYBAR_CONFIG"
  [ "$status" -eq 0 ]
  run diff "$WG_TMP/style.orig" "$WG_WAYBAR_STYLE"
  [ "$status" -eq 0 ]
  run diff "$WG_TMP/bindings.orig" "$WG_HYPR_BINDINGS"
  [ "$status" -eq 0 ]
  run diff "$WG_TMP/autostart.orig" "$WG_HYPR_AUTOSTART"
  [ "$status" -eq 0 ]
}

@test "uninstall removes the symlinks but leaves the state file" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
  [ ! -e "$WG_BIN_DIR/wingroup" ]
  [ -f "$WG_STATE_DIR/state.json" ]
}

@test "uninstall on a machine that was never installed does nothing and succeeds" {
  run "$WG_ROOT/uninstall.sh"
  [ "$status" -eq 0 ]
  run diff "$WG_TMP/config.orig" "$WG_WAYBAR_CONFIG"
  [ "$status" -eq 0 ]
}

# --- crash detection -------------------------------------------------------

# The watcher is what turns a journal line into a crash record, and it can only
# do that for a session it saw alive. Starting it on demand is too late by
# definition, so it goes in the autostart block next to the daemon.
@test "install autostarts the oom watcher next to the daemon" {
  "$WG_ROOT/install.sh"
  run bash -c "grep -c 'exec-once = wingroup-oomwatch' '$WG_HYPR_AUTOSTART'"
  [ "$output" -eq 1 ]
  # the daemon still comes first
  run bash -c "grep -n 'exec-once' '$WG_HYPR_AUTOSTART' | head -1"
  [[ "$output" == *wingroup-daemon* ]]
}

@test "the oomwatch autostart line is inside the marked block and uninstall takes it out" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
  run bash -c "grep -c 'wingroup-oomwatch' '$WG_HYPR_AUTOSTART' || true"
  [ "$output" -eq 0 ]
  run cmp "$WG_TMP/autostart.orig" "$WG_HYPR_AUTOSTART"
  [ "$status" -eq 0 ]
}

@test "install writes a crashed rule for every slot" {
  "$WG_ROOT/install.sh"
  local i
  for i in 0 1 2 3 4 5 6 7; do
    run bash -c "grep -c '#custom-wingroup$i.crashed' '$WG_WAYBAR_STYLE'"
    [ "$output" -eq 1 ]
  done
}

# A crash is not "more idle sessions", and the rule must not read as one. Every
# step of the ramp colours text and nothing else; this one fills the widget, so
# no amount of idle heat can be mistaken for a session that was killed.
@test "the crashed rule is an alarm, not another step on the idle ramp" {
  "$WG_ROOT/install.sh"
  run bash -c "grep '#custom-wingroup0.crashed' '$WG_WAYBAR_STYLE'"
  [[ "$output" == *"background:"* ]]
  [[ "$output" == *"opacity: 1"* ]]
  [[ "$output" == *"font-weight: bold"* ]]
  # no ramp step fills a background, or the two states would look alike
  run bash -c "grep -c 'idle[0-9].*background' '$WG_WAYBAR_STYLE' || true"
  [ "$output" -eq 0 ]
}

# The mirror of the ramp's ordering rule. The ramp yields to "active" because it
# would otherwise dim the group you are looking at; this raises every property
# it touches and lowers none, and the group you are looking at is exactly the
# one whose lost session you most need to be told about. So it goes last.
@test "the crashed rule comes after the state rules so a crash outranks them" {
  "$WG_ROOT/install.sh"
  local crashed active busy
  crashed="$(grep -n '#custom-wingroup0.crashed' "$WG_WAYBAR_STYLE" | cut -d: -f1)"
  active="$(grep -n '#custom-wingroup0.active' "$WG_WAYBAR_STYLE" | cut -d: -f1)"
  busy="$(grep -n '#custom-wingroup0.busy' "$WG_WAYBAR_STYLE" | cut -d: -f1)"
  [ "$crashed" -gt "$active" ]
  [ "$crashed" -gt "$busy" ]
}

@test "uninstall takes the crashed rule back out with the rest of the block" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
  run bash -c "grep -c 'crashed' '$WG_WAYBAR_STYLE' || true"
  [ "$output" -eq 0 ]
  run diff "$WG_TMP/style.orig" "$WG_WAYBAR_STYLE"
  [ "$status" -eq 0 ]
}

# --- the Claude Code SessionStart hook -------------------------------------

# The schema is Claude Code's, not ours: hooks.SessionStart is a list of
# entries, each with its own list of {type, command}. Asserting the shape and
# not just the string is the point -- a command in the wrong place is a hook
# that never runs, and nothing else in this repo would notice.
@test "install registers the hook with the schema Claude Code expects" {
  "$WG_ROOT/install.sh"
  run jq -e '
    .hooks.SessionStart
    | map(select(any(.hooks[]; .command == "wingroup-hook")))
    | length == 1
  ' "$WG_CLAUDE_SETTINGS"
  [ "$status" -eq 0 ]
  run jq -r '.hooks.SessionStart[] | .hooks[] | select(.command == "wingroup-hook") | .type' \
    "$WG_CLAUDE_SETTINGS"
  [ "$output" = "command" ]
}

# No matcher, deliberately: an absent matcher matches startup, resume, clear,
# compact and fork alike, and every one of those is a session about to be alive
# in a scope. A resumed session is the case that matters most -- it is the one
# you got back after the last crash.
@test "the registered hook carries no matcher, so it fires on every session start" {
  "$WG_ROOT/install.sh"
  run jq -e '
    .hooks.SessionStart
    | map(select(any(.hooks[]; .command == "wingroup-hook")))
    | all(has("matcher") | not)
  ' "$WG_CLAUDE_SETTINGS"
  [ "$status" -eq 0 ]
}

@test "install announces that it registered the hook" {
  run "$WG_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wingroup-hook"* ]]
  [[ "$output" == *"$WG_CLAUDE_SETTINGS"* ]]
}

@test "installing twice does not register the hook twice" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/install.sh"
  run wg_hook_count
  [ "$output" -eq 1 ]
  run "$WG_ROOT/install.sh"
  [[ "$output" == *"already registered"* ]]
}

# The file is the user's, and almost none of it is ours. Losing any of it costs
# them their model, their permissions or somebody else's hook.
@test "install preserves every unrelated key and every existing hook" {
  "$WG_ROOT/install.sh"
  run jq -r '.model' "$WG_CLAUDE_SETTINGS"
  [ "$output" = "opus" ]
  run jq -r '.permissions.allow[0]' "$WG_CLAUDE_SETTINGS"
  [ "$output" = "Bash(ls:*)" ]
  run jq -r '.hooks.PreToolUse[0].hooks[0].command' "$WG_CLAUDE_SETTINGS"
  [ "$output" = "their-pretool" ]
  run jq -e '[.hooks.SessionStart[].hooks[] | select(.command == "their-session-start")] | length == 1' \
    "$WG_CLAUDE_SETTINGS"
  [ "$status" -eq 0 ]
}

# The entry goes in beside the user's rather than into it, so their entry is
# unchanged afterwards and uninstall has one object to remove rather than a
# field to pick out of theirs.
@test "install adds an entry of its own instead of editing the user's" {
  "$WG_ROOT/install.sh"
  run jq -e '.hooks.SessionStart | length == 2' "$WG_CLAUDE_SETTINGS"
  [ "$status" -eq 0 ]
  run jq -c '.hooks.SessionStart[0]' "$WG_CLAUDE_SETTINGS"
  [ "$output" = '{"hooks":[{"type":"command","command":"their-session-start"}]}' ]
}

# The one that matters most. A settings file we cannot parse is a settings file
# we must not write: whatever is in there is still the user's configuration, and
# a merge built on a failed parse would replace all of it with our hook alone.
@test "install refuses to touch a settings file that is not valid JSON" {
  printf '{ "model": "opus",\n  // a comment JSON does not allow\n}\n' >"$WG_CLAUDE_SETTINGS"
  cp "$WG_CLAUDE_SETTINGS" "$WG_TMP/settings.broken"

  run "$WG_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not valid JSON"* ]]

  run cmp "$WG_TMP/settings.broken" "$WG_CLAUDE_SETTINGS"
  [ "$status" -eq 0 ]
}

# A machine with no Claude Code on it is a machine wingroup still installs on.
# The grouping half has nothing to do with sessions, and the crash half falls
# back to naming the project rather than the session.
@test "install succeeds and says so when there is no settings file at all" {
  rm -f "$WG_CLAUDE_SETTINGS"
  run "$WG_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no settings file"* ]]
  [ ! -e "$WG_CLAUDE_SETTINGS" ]
}

@test "--no-claude-hook installs everything else and leaves settings.json alone" {
  run "$WG_ROOT/install.sh" --no-claude-hook
  [ "$status" -eq 0 ]
  [[ "$output" == *"--no-claude-hook"* ]]
  run cmp "$WG_TMP/claude-settings.orig" "$WG_CLAUDE_SETTINGS"
  [ "$status" -eq 0 ]
  # the rest of the install is unaffected
  grep -q 'exec-once = wingroup-oomwatch' "$WG_HYPR_AUTOSTART"
  [ -L "$WG_BIN_DIR/wingroup-hook" ]
}

@test "an unknown option is refused before anything is written" {
  run "$WG_ROOT/install.sh" --nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option"* ]]
  run cmp "$WG_TMP/config.orig" "$WG_WAYBAR_CONFIG"
  [ "$status" -eq 0 ]
}

@test "install backs the settings file up before changing it" {
  "$WG_ROOT/install.sh"
  run bash -c "ls '$WG_TMP'/claude-settings.json.bak.* | wc -l"
  [ "$output" -eq 1 ]
  local bak
  bak="$(ls "$WG_TMP"/claude-settings.json.bak.*)"
  run cmp "$WG_TMP/claude-settings.orig" "$bak"
  [ "$status" -eq 0 ]
}

@test "uninstall removes our hook entry and leaves the user's alone" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
  run wg_hook_count
  [ "$output" -eq 0 ]
  run jq -c '.hooks.SessionStart' "$WG_CLAUDE_SETTINGS"
  [ "$output" = '[{"hooks":[{"type":"command","command":"their-session-start"}]}]' ]
  run jq -r '.model' "$WG_CLAUDE_SETTINGS"
  [ "$output" = "opus" ]
  run jq -r '.hooks.PreToolUse[0].hooks[0].command' "$WG_CLAUDE_SETTINGS"
  [ "$output" = "their-pretool" ]
}

# jq reformats, so an uninstall that rewrote a file it had nothing to remove
# from would reflow the user's settings for no reason at all. Uninstalling
# without having installed the hook -- or after --no-claude-hook -- must not
# touch the file.
@test "uninstall leaves settings.json untouched when the hook was never registered" {
  "$WG_ROOT/install.sh" --no-claude-hook
  "$WG_ROOT/uninstall.sh"
  run cmp "$WG_TMP/claude-settings.orig" "$WG_CLAUDE_SETTINGS"
  [ "$status" -eq 0 ]
}

@test "uninstall on a settings file that is not valid JSON changes nothing" {
  "$WG_ROOT/install.sh"
  printf 'not json at all\n' >"$WG_CLAUDE_SETTINGS"
  cp "$WG_CLAUDE_SETTINGS" "$WG_TMP/settings.broken"
  run "$WG_ROOT/uninstall.sh"
  [ "$status" -eq 0 ]
  run cmp "$WG_TMP/settings.broken" "$WG_CLAUDE_SETTINGS"
  [ "$status" -eq 0 ]
}

# The empty containers only go when they are ours to remove: a SessionStart list
# holding nothing but our entry, in a hooks object holding nothing but it.
@test "uninstall cleans up the containers it created on a settings file that had none" {
  printf '%s\n' '{"model":"opus"}' >"$WG_CLAUDE_SETTINGS"
  "$WG_ROOT/install.sh"
  run jq -e '.hooks.SessionStart | length == 1' "$WG_CLAUDE_SETTINGS"
  [ "$status" -eq 0 ]
  "$WG_ROOT/uninstall.sh"
  run jq -e 'has("hooks") | not' "$WG_CLAUDE_SETTINGS"
  [ "$status" -eq 0 ]
  run jq -r '.model' "$WG_CLAUDE_SETTINGS"
  [ "$output" = "opus" ]
}

# A SessionStart entry is allowed to carry a matcher and no "hooks" key at all.
# Claude Code accepts one, so a user can have one, and the strip filter used to
# iterate .hooks[] over that null -- which aborts the whole jq program, not just
# that entry. The error was swallowed by `|| return 0`, so uninstall reported
# success while our command stayed registered, pointing at the symlink
# unlink_binaries had just deleted: a command Claude Code runs, and fails to
# find, at the start of every session from then on. Nothing else in this suite
# notices, because nothing else puts a hookless entry in the file.
@test "uninstall removes our hook past an entry that has no hooks key" {
  jq '.hooks.SessionStart = [{"matcher": "startup"}] + .hooks.SessionStart' \
    "$WG_CLAUDE_SETTINGS" >"$WG_TMP/seeded"
  mv -f "$WG_TMP/seeded" "$WG_CLAUDE_SETTINGS"
  "$WG_ROOT/install.sh"
  run wg_hook_count
  [ "$output" -eq 1 ]

  run bash -c "'$WG_ROOT/uninstall.sh' >/dev/null 2>'$WG_TMP/uninstall.err'"
  [ "$status" -eq 0 ]
  # the removal really happened, rather than warning its way out of it
  [ ! -s "$WG_TMP/uninstall.err" ]
  run wg_hook_count
  [ "$output" -eq 0 ]

  # and the rest of the file is the user's, untouched -- the hookless entry
  # included. It runs nothing either way, but it is the user's text, and an
  # uninstall that promises to leave everything but our own entry alone does not
  # get to tidy it away. (Note the // [] here: this assertion has to walk the
  # same hookless entry the strip filter does, and would abort on it too.)
  run jq -e '[.hooks.SessionStart[] | (.hooks // [])[] | select(.command == "their-session-start")] | length == 1' \
    "$WG_CLAUDE_SETTINGS"
  [ "$status" -eq 0 ]
  run jq -e '[.hooks.SessionStart[] | select(has("hooks") | not) | .matcher] == ["startup"]' \
    "$WG_CLAUDE_SETTINGS"
  [ "$status" -eq 0 ]
  run jq -r '.hooks.PreToolUse[0].hooks[0].command' "$WG_CLAUDE_SETTINGS"
  [ "$output" = "their-pretool" ]
  run jq -r '.model' "$WG_CLAUDE_SETTINGS"
  [ "$output" = "opus" ]
}

# Install puts our command in an entry of its own, but the file is the user's
# and they may have tidied it since -- ours folded in beside their own commands
# is a shape uninstall has to cope with. Only the command is ours: the entry,
# its matcher and everything else in its list are theirs and stay.
@test "uninstall takes our command out of a shared entry and leaves theirs" {
  cat >"$WG_CLAUDE_SETTINGS" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "matcher": "startup", "hooks": [
        { "type": "command", "command": "their-session-start" },
        { "type": "command", "command": "wingroup-hook", "timeout": 5 },
        { "type": "command", "command": "their-other-hook" }
      ] }
    ]
  }
}
JSON
  run bash -c "'$WG_ROOT/uninstall.sh' >/dev/null 2>'$WG_TMP/uninstall.err'"
  [ "$status" -eq 0 ]
  [ ! -s "$WG_TMP/uninstall.err" ]
  run jq -c '.hooks.SessionStart' "$WG_CLAUDE_SETTINGS"
  [ "$output" = '[{"matcher":"startup","hooks":[{"type":"command","command":"their-session-start"},{"type":"command","command":"their-other-hook"}]}]' ]
}

# The one failure in uninstall that must not be silent. Everything else it
# gives up on leaves the machine tidier than it found it; this one does the
# opposite, because unlink_binaries has already taken wingroup-hook off $PATH.
# A registration left behind is a command Claude Code runs and fails to find at
# every session start, and nothing connects that back to an uninstall that said
# it had finished.
@test "uninstall says so on stderr when it cannot remove the hook" {
  [ "$(id -u)" -ne 0 ] || skip "root writes into a read-only directory regardless"
  # Its own directory: uninstall writes the waybar and hypr files too, and those
  # live in $WG_TMP.
  mkdir -p "$WG_TMP/claude"
  export WG_CLAUDE_SETTINGS="$WG_TMP/claude/settings.json"
  wg_seed_settings
  "$WG_ROOT/install.sh"
  # The rewrite goes through a temp file beside the settings file, so a
  # directory it cannot create one in is a removal that cannot happen -- the
  # same shape as a read-only home or a full disk.
  chmod 500 "$WG_TMP/claude"
  run bash -c "'$WG_ROOT/uninstall.sh' >/dev/null 2>'$WG_TMP/uninstall.err'"
  # restored before the assertions, or a failing one leaves behind a directory
  # teardown cannot delete
  chmod 700 "$WG_TMP/claude"
  [ "$status" -eq 0 ]

  local err
  err="$(cat "$WG_TMP/uninstall.err")"
  [[ "$err" == *"could not remove the SessionStart hook"* ]]
  [[ "$err" == *"$WG_CLAUDE_SETTINGS"* ]]
  # and it names the entry, because taking it out by hand is the user's job now
  [[ "$err" == *"wingroup-hook"* ]]

  # the warning is true rather than precautionary: the hook really is still there
  run wg_hook_count
  [ "$output" -eq 1 ]
}

# The upgrade path, and the reason install cannot stop at "my marker is there".
#
# A machine that installed wingroup before the watcher existed has a block with
# the daemon and the restore in it and nothing else. Treating the marker as
# "already configured" leaves that machine without the watcher for good -- and
# nothing complains, because every other part still works, right up until a
# reboot loses every session. This happened on a real machine.
wg_seed_old_block() {
  cat >"$WG_HYPR_AUTOSTART" <<'CONF'
# my autostart

# >>> wingroup
exec-once = wingroup-daemon
exec-once = wingroup-restore
# <<< wingroup
CONF
}

@test "install adds the watcher to a block installed before the watcher existed" {
  printf '#!/usr/bin/env bash\n' >"$WG_RESTORE_SCRIPT"
  chmod +x "$WG_RESTORE_SCRIPT"
  wg_seed_old_block

  "$WG_ROOT/install.sh"
  run bash -c "grep -c 'exec-once = wingroup-oomwatch' '$WG_HYPR_AUTOSTART'"
  [ "$output" -eq 1 ]
  # and the lines that were already there are still there, once each
  run bash -c "grep -c 'exec-once = wingroup-daemon' '$WG_HYPR_AUTOSTART'"
  [ "$output" -eq 1 ]
  run bash -c "grep -c 'exec-once = wingroup-restore' '$WG_HYPR_AUTOSTART'"
  [ "$output" -eq 1 ]
}

@test "install says which line it added to an existing block" {
  printf '#!/usr/bin/env bash\n' >"$WG_RESTORE_SCRIPT"
  chmod +x "$WG_RESTORE_SCRIPT"
  wg_seed_old_block

  run "$WG_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'added the missing "exec-once = wingroup-oomwatch"'* ]]
}

# The added line has to land inside the markers, or uninstall walks away from it
# and leaves an exec-once for a command it has just unlinked.
@test "a line added to an existing block is inside it and uninstall takes it out" {
  printf '#!/usr/bin/env bash\n' >"$WG_RESTORE_SCRIPT"
  chmod +x "$WG_RESTORE_SCRIPT"
  wg_seed_old_block
  cp "$WG_HYPR_AUTOSTART" "$WG_TMP/old-block.orig"

  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
  run bash -c "grep -c 'wingroup-oomwatch' '$WG_HYPR_AUTOSTART' || true"
  [ "$output" -eq 0 ]
}

# The block is the user's file too. Whatever they put in it -- their own
# exec-once, a comment, an order they chose -- an upgrade must not rewrite.
@test "an upgrade leaves what the user put inside the block alone" {
  cat >"$WG_HYPR_AUTOSTART" <<'CONF'
# my autostart

# >>> wingroup
exec-once = wingroup-daemon
# I moved this one on purpose
exec-once = my-own-thing
# <<< wingroup
CONF

  "$WG_ROOT/install.sh"
  run bash -c "grep -c 'exec-once = my-own-thing' '$WG_HYPR_AUTOSTART'"
  [ "$output" -eq 1 ]
  run bash -c "grep -c 'I moved this one on purpose' '$WG_HYPR_AUTOSTART'"
  [ "$output" -eq 1 ]
  run bash -c "grep -c 'exec-once = wingroup-oomwatch' '$WG_HYPR_AUTOSTART'"
  [ "$output" -eq 1 ]
}

# Nothing missing means nothing written -- no edit, and no backup of a file that
# was not touched.
@test "a block that already has every line is left alone" {
  "$WG_ROOT/install.sh"
  cp "$WG_HYPR_AUTOSTART" "$WG_TMP/after-first.conf"
  run "$WG_ROOT/install.sh"
  [[ "$output" == *"already configured, left unchanged"* ]]
  run cmp "$WG_TMP/after-first.conf" "$WG_HYPR_AUTOSTART"
  [ "$status" -eq 0 ]
}

# The style block is generated and entirely ours -- the comment above it tells
# the user to restate anything they want changed *after* it, never inside it --
# so an out-of-date one is rewritten rather than walked past.
#
# Walked past is what it used to be, and it is how a machine that installed
# before the crashed rule existed ended up with a bar that could never show a
# crash: the block was there, install skipped it, and the one rule the feature
# needs to be visible was never written. Nothing said so. Seen on a real
# machine, which is the only reason it was noticed at all.
wg_seed_old_style() {
  cat >"$WG_WAYBAR_STYLE" <<'CSS'
/* the user's own css */
#clock { color: #fff; }

/* >>> wingroup */
#custom-wingroup0 { padding: 0 6px; opacity: 0.55; }
#custom-wingroup0.busy { opacity: 1; }
/* <<< wingroup */

/* more of the user's css */
#battery { color: #0f0; }
CSS
}

@test "an out-of-date style block gains the rules it is missing" {
  wg_seed_old_style

  "$WG_ROOT/install.sh"
  run bash -c "grep -c 'custom-wingroup0.crashed' '$WG_WAYBAR_STYLE'"
  [ "$output" -eq 1 ]
  # and the full ramp, which the old block also predates
  run bash -c "grep -c 'custom-wingroup0.idle1' '$WG_WAYBAR_STYLE'"
  [ "$output" -eq 1 ]
}

@test "refreshing the style block says so" {
  wg_seed_old_style
  run "$WG_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wingroup block was out of date and has been rewritten"* ]]
}

# The block is ours; every line around it is the user's and must come through
# a refresh untouched, in order.
@test "refreshing the style block leaves the user's css alone" {
  wg_seed_old_style

  "$WG_ROOT/install.sh"
  run bash -c "grep -c '#clock { color: #fff; }' '$WG_WAYBAR_STYLE'"
  [ "$output" -eq 1 ]
  run bash -c "grep -c '#battery { color: #0f0; }' '$WG_WAYBAR_STYLE'"
  [ "$output" -eq 1 ]
  # the user's own comment survives, and ours has not been duplicated
  run bash -c "grep -c \"the user's own css\" '$WG_WAYBAR_STYLE'"
  [ "$output" -eq 1 ]
  run bash -c "grep -c '>>> wingroup' '$WG_WAYBAR_STYLE'"
  [ "$output" -eq 1 ]
}

# A block that is already current is not rewritten. Otherwise every install
# would back the file up and churn it for no change -- and, worse, the blank
# line before the block would accumulate one per run.
@test "a current style block is left byte for byte" {
  "$WG_ROOT/install.sh"
  cp "$WG_WAYBAR_STYLE" "$WG_TMP/style.after-first"
  run "$WG_ROOT/install.sh"
  [[ "$output" != *"out of date"* ]]
  run cmp "$WG_TMP/style.after-first" "$WG_WAYBAR_STYLE"
  [ "$status" -eq 0 ]
}

# Refreshing must not leave the file one blank line taller each time, which is
# what a strip that keeps the separator and an append that adds another would.
@test "refreshing twice does not grow the file" {
  wg_seed_old_style
  "$WG_ROOT/install.sh"
  cp "$WG_WAYBAR_STYLE" "$WG_TMP/style.after-refresh"
  # force a second refresh from the same starting point
  wg_seed_old_style
  "$WG_ROOT/install.sh"
  run cmp "$WG_TMP/style.after-refresh" "$WG_WAYBAR_STYLE"
  [ "$status" -eq 0 ]
}

# And uninstall still has to hand the file back exactly as it was found, even
# though what it is removing is not what install first wrote there.
@test "uninstall restores a refreshed style file byte for byte" {
  wg_seed_old_style
  cp "$WG_WAYBAR_STYLE" "$WG_TMP/style.old-block"

  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
  run bash -c "grep -c 'wingroup' '$WG_WAYBAR_STYLE' || true"
  [ "$output" -eq 0 ]
  run bash -c "grep -c '#battery { color: #0f0; }' '$WG_WAYBAR_STYLE'"
  [ "$output" -eq 1 ]
}
