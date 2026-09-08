#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  export WG_BIN_DIR="$WG_TMP/bin"
  export WG_WAYBAR_CONFIG="$WG_TMP/config.jsonc"
  export WG_WAYBAR_STYLE="$WG_TMP/style.css"
  export WG_HYPR_BINDINGS="$WG_TMP/bindings.conf"
  export WG_HYPR_AUTOSTART="$WG_TMP/autostart.conf"
}

teardown() { wg_teardown_tmp; }

wg_ends_with_newline() {
  [ -s "$1" ] || return 0
  [ "$(tail -c1 -- "$1" | wc -l)" -eq 1 ]
}

# --- Finding 1: byte-exact reversal, including no-trailing-newline files ---

@test "install/uninstall round-trips a waybar config with no trailing newline" {
  cp "$WG_FIXTURES/waybar-config-no-eof-nl.jsonc" "$WG_WAYBAR_CONFIG"
  cp "$WG_FIXTURES/waybar-style.css" "$WG_WAYBAR_STYLE"
  printf '# my bindings\n' >"$WG_HYPR_BINDINGS"
  printf '# my autostart\n' >"$WG_HYPR_AUTOSTART"
  cp "$WG_WAYBAR_CONFIG" "$WG_TMP/config.orig"
  run wg_ends_with_newline "$WG_TMP/config.orig"
  [ "$status" -ne 0 ]

  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"

  run diff "$WG_TMP/config.orig" "$WG_WAYBAR_CONFIG"
  [ "$status" -eq 0 ]
  run wg_ends_with_newline "$WG_WAYBAR_CONFIG"
  [ "$status" -ne 0 ]
}

@test "install/uninstall round-trips a waybar style with no trailing newline" {
  cp "$WG_FIXTURES/waybar-config.jsonc" "$WG_WAYBAR_CONFIG"
  cp "$WG_FIXTURES/waybar-style-no-eof-nl.css" "$WG_WAYBAR_STYLE"
  printf '# my bindings\n' >"$WG_HYPR_BINDINGS"
  printf '# my autostart\n' >"$WG_HYPR_AUTOSTART"
  cp "$WG_WAYBAR_STYLE" "$WG_TMP/style.orig"
  run wg_ends_with_newline "$WG_TMP/style.orig"
  [ "$status" -ne 0 ]

  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"

  run diff "$WG_TMP/style.orig" "$WG_WAYBAR_STYLE"
  [ "$status" -eq 0 ]
  run wg_ends_with_newline "$WG_WAYBAR_STYLE"
  [ "$status" -ne 0 ]
}

@test "install/uninstall round-trips hypr bindings with no trailing newline" {
  cp "$WG_FIXTURES/waybar-config.jsonc" "$WG_WAYBAR_CONFIG"
  cp "$WG_FIXTURES/waybar-style.css" "$WG_WAYBAR_STYLE"
  printf '# my bindings' >"$WG_HYPR_BINDINGS"
  printf '# my autostart\n' >"$WG_HYPR_AUTOSTART"
  cp "$WG_HYPR_BINDINGS" "$WG_TMP/bindings.orig"
  run wg_ends_with_newline "$WG_TMP/bindings.orig"
  [ "$status" -ne 0 ]

  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"

  run diff "$WG_TMP/bindings.orig" "$WG_HYPR_BINDINGS"
  [ "$status" -eq 0 ]
  run wg_ends_with_newline "$WG_HYPR_BINDINGS"
  [ "$status" -ne 0 ]
}

@test "install/uninstall round-trips hypr autostart with no trailing newline" {
  cp "$WG_FIXTURES/waybar-config.jsonc" "$WG_WAYBAR_CONFIG"
  cp "$WG_FIXTURES/waybar-style.css" "$WG_WAYBAR_STYLE"
  printf '# my bindings\n' >"$WG_HYPR_BINDINGS"
  printf '# my autostart' >"$WG_HYPR_AUTOSTART"
  cp "$WG_HYPR_AUTOSTART" "$WG_TMP/autostart.orig"
  run wg_ends_with_newline "$WG_TMP/autostart.orig"
  [ "$status" -ne 0 ]

  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"

  run diff "$WG_TMP/autostart.orig" "$WG_HYPR_AUTOSTART"
  [ "$status" -eq 0 ]
  run wg_ends_with_newline "$WG_HYPR_AUTOSTART"
  [ "$status" -ne 0 ]
}

@test "install/uninstall round-trips a file ending in one blank line" {
  cp "$WG_FIXTURES/waybar-config.jsonc" "$WG_WAYBAR_CONFIG"
  cp "$WG_FIXTURES/waybar-style.css" "$WG_WAYBAR_STYLE"
  printf '# my bindings\n\n' >"$WG_HYPR_BINDINGS"
  printf '# my autostart\n' >"$WG_HYPR_AUTOSTART"
  cp "$WG_HYPR_BINDINGS" "$WG_TMP/bindings.orig"

  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"

  run diff "$WG_TMP/bindings.orig" "$WG_HYPR_BINDINGS"
  [ "$status" -eq 0 ]
}

@test "install/uninstall round-trips a file ending in two consecutive blank lines" {
  cp "$WG_FIXTURES/waybar-config.jsonc" "$WG_WAYBAR_CONFIG"
  cp "$WG_FIXTURES/waybar-style.css" "$WG_WAYBAR_STYLE"
  printf '# my bindings\n\n\n' >"$WG_HYPR_BINDINGS"
  printf '# my autostart\n' >"$WG_HYPR_AUTOSTART"
  cp "$WG_HYPR_BINDINGS" "$WG_TMP/bindings.orig"

  "$WG_ROOT/install.sh"
  "$WG_ROOT/uninstall.sh"

  run diff "$WG_TMP/bindings.orig" "$WG_HYPR_BINDINGS"
  [ "$status" -eq 0 ]
}

# --- Finding 2: fail loudly instead of silently no-op-ing on a missing anchor ---

@test "install fails loudly and leaves the config untouched when modules-left has no trailing comma" {
  cp "$WG_FIXTURES/waybar-config-no-comma.jsonc" "$WG_WAYBAR_CONFIG"
  cp "$WG_FIXTURES/waybar-style.css" "$WG_WAYBAR_STYLE"
  printf '# my bindings\n' >"$WG_HYPR_BINDINGS"
  printf '# my autostart\n' >"$WG_HYPR_AUTOSTART"
  cp "$WG_WAYBAR_CONFIG" "$WG_TMP/config.orig"

  run "$WG_ROOT/install.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *modules-left* ]]

  run diff "$WG_TMP/config.orig" "$WG_WAYBAR_CONFIG"
  [ "$status" -eq 0 ]
}
