#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  export WG_RESOLVE_RETRIES=1
  export WG_RESOLVE_DELAY=0
  export WG_DAEMON_NO_MAIN=1
  # The grace period is measured from when the daemon loads, so sourcing it here
  # would otherwise put every test inside it. Zero means "the login burst is
  # over"; the tests about the burst itself put it back.
  export WG_FOLLOW_GRACE=0
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
  run bash -c "grep -c '^movetoworkspace name:shop,address:0xaaa1$' '$WG_DISPATCH_LOG'"
  [ "$output" -eq 1 ]
}

# The bug this answers: a terminal the user deliberately opened was filed onto
# its group's workspace with movetoworkspacesilent, leaving the user on the
# workspace they were already on -- so the window they had just asked for was
# simply gone from their screen. One dispatch moves it and takes them with it.
@test "a window the user just opened is moved and followed" {
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspace name:shop,address:0xaaa1" ]
}

# The seeded fixture has no "follow" key at all, which is what every state file
# written before this setting existed looks like. Absent has to mean on.
@test "a state file with no follow key follows" {
  run bash -c "jq -e 'has(\"follow\")' '$WG_STATE_DIR/state.json'"
  [ "$status" -ne 0 ]
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspace name:shop,address:0xaaa1" ]
}

@test "follow=false keeps the silent move" {
  wg_patch_state '.follow = false'
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspacesilent name:shop,address:0xaaa1" ]
}

# Login opens a dozen terminals at once. Following each of them would throw the
# user around the desktop before they have touched anything.
@test "a window filed during the startup grace period is filed silently" {
  export WG_FOLLOW_GRACE=10
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspacesilent name:shop,address:0xaaa1" ]
}

@test "the grace period ends and following resumes" {
  export WG_FOLLOW_GRACE=10
  WG_START_MS=$(( $(wg_now_ms) - 11000 ))
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspace name:shop,address:0xaaa1" ]
}

# wingroup-restore respawns fourteen terminals; the flag is how it says so. The
# path is spelled out rather than taken from the daemon, so that the two sides
# agreeing on it is what the test checks.
@test "a window filed while a restore is running is filed silently" {
  : >"$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspacesilent name:shop,address:0xaaa1" ]
}

@test "following resumes once the restore flag is cleared" {
  : >"$XDG_RUNTIME_DIR/wingroup-restoring"
  rm -f "$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspace name:shop,address:0xaaa1" ]
}

@test "no other window is moved" {
  export WG_REFRESH_DEBOUNCE_MS=5000
  feed "$WG_FIXTURES/events.txt"
  run bash -c "wc -l <'$WG_DISPATCH_LOG'"
  [ "$output" -eq 1 ]
}

# Following changes how a window is moved, never whether it is: a floating
# window is still not touched at all, follow or no follow.
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

# Same for a window that is already where it belongs: no dispatch, so no
# workspace switch either -- following must not become a reason to visit it.
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
  local before
  before="$(stat -c '%i %y' "$WG_STATE_DIR/state.json")"
  wg_daemon_handle_line "closewindow>>aaa3"
  run bash -c "jq -r '.overrides[\"0xaaa3\"] // \"gone\"' '$WG_STATE_DIR/state.json'"
  [ "$output" = "gone" ]
  # this one really is a rewrite
  [ "$(stat -c '%i %y' "$WG_STATE_DIR/state.json")" != "$before" ]
}

# Every daemon write is a lost-update opportunity against the CLI -- there is no
# lock between them -- and a window with no override is the common case.
@test "closewindow does not rewrite the state file when there is no override" {
  local before after
  before="$(stat -c '%i %y' "$WG_STATE_DIR/state.json")"
  wg_daemon_handle_line "closewindow>>aaa1"
  wg_daemon_handle_line "closewindow>>aaa2"
  wg_daemon_handle_line "closewindow>>aaa6"
  after="$(stat -c '%i %y' "$WG_STATE_DIR/state.json")"
  [ "$before" = "$after" ]
  [ "$(jq -r '.overrides["0xaaa3"]' "$WG_STATE_DIR/state.json")" = "site" ]
}
