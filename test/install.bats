#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  export WG_BIN_DIR="$WG_TMP/bin"
  export WG_WAYBAR_CONFIG="$WG_TMP/config.jsonc"
  export WG_WAYBAR_STYLE="$WG_TMP/style.css"
  export WG_HYPR_BINDINGS="$WG_TMP/bindings.conf"
  export WG_HYPR_AUTOSTART="$WG_TMP/autostart.conf"
  # Never the real one: whether it exists decides what install writes.
  export WG_RESTORE_SCRIPT="$WG_TMP/restore-claude.sh"
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

@test "install links all three executables" {
  "$WG_ROOT/install.sh"
  [ -L "$WG_BIN_DIR/wingroup" ]
  [ -L "$WG_BIN_DIR/wingroup-daemon" ]
  [ -L "$WG_BIN_DIR/wingroup-waybar" ]
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
  [[ "$output" == *'added "exec-once = wingroup-daemon"'* ]]
  [[ "$output" == *'"exec-once = wingroup-restore" was left out'* ]]
  [[ "$output" == *"$WG_RESTORE_SCRIPT"* ]]
}

@test "install adds the restore autostart when an executable restore script exists" {
  printf '#!/usr/bin/env bash\n' >"$WG_RESTORE_SCRIPT"
  chmod +x "$WG_RESTORE_SCRIPT"

  run "$WG_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *'added "exec-once = wingroup-daemon" and "exec-once = wingroup-restore"'* ]]

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
