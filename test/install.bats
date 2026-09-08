#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  export WG_BIN_DIR="$WG_TMP/bin"
  export WG_WAYBAR_CONFIG="$WG_TMP/config.jsonc"
  export WG_WAYBAR_STYLE="$WG_TMP/style.css"
  export WG_HYPR_BINDINGS="$WG_TMP/bindings.conf"
  export WG_HYPR_AUTOSTART="$WG_TMP/autostart.conf"
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
