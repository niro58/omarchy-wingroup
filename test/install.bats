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

# Groups have their own strip now, and Omarchy's numbered-workspace module
# renders a named group workspace as an anonymous dot beside it -- a second,
# worse view of the same thing. It comes out as part of installing.
@test "install takes the numbered workspace indicator out of modules-left" {
  "$WG_ROOT/install.sh"
  run bash -c "grep -E '\"modules-left\"' '$WG_WAYBAR_CONFIG' | grep -v 'wingroup-modules-left' | grep -c 'hyprland/workspaces' || true"
  [ "$output" -eq 0 ]
  # and the rest of modules-left is untouched
  run bash -c "grep -E '\"modules-left\"' '$WG_WAYBAR_CONFIG' | grep -v 'wingroup-modules-left'"
  [[ "$output" == *'["custom/omarchy", "custom/wingroup0"'* ]]
}

@test "uninstall puts the numbered workspace indicator back where it was" {
  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"
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
