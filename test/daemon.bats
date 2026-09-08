#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  export WG_RESOLVE_RETRIES=1
  export WG_RESOLVE_DELAY=0
  export WG_DAEMON_NO_MAIN=1
  source "$WG_ROOT/bin/wingroup-daemon"
  wg_stub_cwd
}

teardown() { wg_teardown_tmp; }

feed() {
  local line
  while IFS= read -r line; do
    wg_daemon_handle_line "$line"
  done <"$1"
}

@test "a project window is moved to its group exactly once" {
  export WG_REFRESH_DEBOUNCE_MS=5000
  feed "$WG_FIXTURES/events.txt"
  run bash -c "grep -c 'movetoworkspacesilent name:everest,address:0xaaa1' '$WG_DISPATCH_LOG'"
  [ "$output" -eq 1 ]
}

@test "no other window is moved" {
  export WG_REFRESH_DEBOUNCE_MS=5000
  feed "$WG_FIXTURES/events.txt"
  run bash -c "wc -l <'$WG_DISPATCH_LOG'"
  [ "$output" -eq 1 ]
}

@test "a floating window is never moved" {
  wg_daemon_handle_line "openwindow>>aaa7,1,org.gnome.Nautilus,Home"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "a window with no project is left alone under the default catchall" {
  wg_daemon_handle_line "openwindow>>aaa6,1,Alacritty,niro@niro:~"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "auto=false disables all moves" {
  wg_state_write "$(jq '.auto = false' "$WG_STATE_DIR/state.json")"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "a window already on its group workspace is not moved again" {
  wg_state_write "$(jq '.groups[0].name = "1" | .groups[0].label = "one"' "$WG_STATE_DIR/state.json")"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "a burst of title events collapses to one refresh" {
  export WG_REFRESH_DEBOUNCE_MS=5000
  wg_daemon_handle_line "windowtitle>>aaa1"
  wg_daemon_handle_line "windowtitle>>aaa2"
  wg_daemon_handle_line "windowtitle>>aaa3"
  run bash -c "wc -l <'$WG_REFRESH_LOG'"
  [ "$output" -eq 1 ]
}

@test "with debouncing off every title event refreshes" {
  export WG_REFRESH_DEBOUNCE_MS=0
  wg_daemon_handle_line "windowtitle>>aaa1"
  wg_daemon_handle_line "windowtitle>>aaa2"
  wg_daemon_handle_line "windowtitle>>aaa3"
  run bash -c "wc -l <'$WG_REFRESH_LOG'"
  [ "$output" -eq 3 ]
}

@test "an unrecognised event line is ignored without error" {
  run wg_daemon_handle_line "somefutureevent>>whatever,1,2,3"
  [ "$status" -eq 0 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# Resolving one window used to build the whole table and throw all but one row
# away, once for floating/workspace and again for every retry -- up to eleven
# full builds per window opened. On a login burst that puts the daemon tens of
# seconds behind, moving windows after the user has already started typing.
@test "opening a window resolves only that window's cwd" {
  export WG_RESOLVE_RETRIES=10
  export WG_CWD_LOG="$WG_TMP/cwd.log"
  : >"$WG_CWD_LOG"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  # Seven clients in the fixture; the old code looked up 14 cwds (two builds).
  run bash -c "wc -l <'$WG_CWD_LOG'"
  [ "$output" -eq 1 ]
  run bash -c "sort -u '$WG_CWD_LOG'"
  [ "$output" = "1001" ]
}

@test "opening a window queries the compositor once" {
  export WG_RESOLVE_RETRIES=10
  export WG_HYPRCTL_LOG="$WG_TMP/hyprctl.log"
  : >"$WG_HYPRCTL_LOG"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run bash -c "grep -c '^-j clients$' '$WG_HYPRCTL_LOG'"
  [ "$output" -eq 1 ]
}

@test "an unresolvable window still retries the configured number of times" {
  export WG_RESOLVE_RETRIES=3
  export WG_HYPRCTL_LOG="$WG_TMP/hyprctl.log"
  : >"$WG_HYPRCTL_LOG"
  wg_daemon_handle_line "openwindow>>aaa6,1,Alacritty,niro@niro:~"
  # One fetch for floating/workspace/group, then WG_RESOLVE_RETRIES more.
  run bash -c "grep -c '^-j clients$' '$WG_HYPRCTL_LOG'"
  [ "$output" -eq 4 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "closewindow prunes the override for that window" {
  wg_daemon_handle_line "closewindow>>aaa3"
  run bash -c "jq -r '.overrides[\"0xaaa3\"] // \"gone\"' '$WG_STATE_DIR/state.json'"
  [ "$output" = "gone" ]
}
