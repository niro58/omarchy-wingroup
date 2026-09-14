#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  source "$WG_ROOT/lib/hypr.sh"
}

teardown() { wg_teardown_tmp; }

@test "wg_hypr_query returns the clients fixture as JSON" {
  run wg_hypr_query clients
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" -eq 7 ]
}

@test "wg_hypr_query reads the active workspace" {
  run wg_hypr_query activeworkspace
  [ "$status" -eq 0 ]
  [ "$(jq -r '.name' <<<"$output")" = "1" ]
}

@test "wg_hypr_dispatch records the dispatch instead of running it" {
  wg_hypr_dispatch movetoworkspacesilent "name:shop,address:0xaaa1"
  [ "$(dispatches)" = "movetoworkspacesilent name:shop,address:0xaaa1" ]
}

@test "wg_hypr_query lists every monitor and the workspace on it" {
  run wg_hypr_query monitors
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" -eq 2 ]
  [ "$(jq -r 'map(.activeWorkspace.name) | join(",")' <<<"$output")" = "3,template" ]
  [ "$(jq -r 'first(.[] | select(.focused) | .name)' <<<"$output")" = "DP-1" ]
}

@test "wg_hypr_query fails loudly on an unhandled query" {
  run wg_hypr_query devices
  [ "$status" -ne 0 ]
}

# --- asking the bar to redraw without killing it ---

# A process standing in for waybar: a copy of bash under a name of its own, so
# pgrep -x finds it and nothing else. $1 is the script it runs.
wg_fake_bar() {
  cp "$(command -v bash)" "$WG_TMP/wgfakebar"
  export WG_WAYBAR_PROC=wgfakebar
  "$WG_TMP/wgfakebar" -c "$1" &
  FAKE_BAR=$!
}

# Polls until $FAKE_BAR has a handler for RTMIN+11, so a test about a ready bar
# is not racing the trap it just set.
wg_fake_bar_ready() {
  local i=0 mask bit=$(( $(kill -l RTMIN) + 11 - 1 ))
  while (( i++ < 100 )); do
    mask="$(awk '/^SigCgt:/ { print $2 }' "/proc/$FAKE_BAR/status" 2>/dev/null)"
    [[ -n $mask ]] && (( (16#$mask >> bit) & 1 )) && return 0
    sleep 0.05
  done
  return 1
}

# The premise, stated as a test so nobody has to take it on trust: RTMIN+11 sent
# to a process with no handler for it does not get ignored, it ends the process.
# That is what happened to the bar at login.
@test "an unhandled RTMIN+11 terminates the process it is sent to" {
  wg_fake_bar 'while :; do sleep 0.05; done'
  sleep 0.2
  kill -s RTMIN+11 "$FAKE_BAR"
  local status=0
  wait "$FAKE_BAR" || status=$?
  [ "$status" -eq $(( 128 + $(kill -l RTMIN) + 11 )) ]
}

# waybar has no handler until its modules are built, and login is when every
# wingroup process asks for a redraw at once. A bar still starting must be left
# alone -- it reads the state fresh the moment it finishes anyway.
@test "a bar that is still starting is not signalled, and survives" {
  wg_fake_bar 'while :; do sleep 0.05; done'
  sleep 0.2
  wg_signal_waybar 11
  sleep 0.3
  local alive=0
  kill -0 "$FAKE_BAR" 2>/dev/null && alive=1
  kill "$FAKE_BAR" 2>/dev/null || true
  wait "$FAKE_BAR" 2>/dev/null || true
  [ "$alive" -eq 1 ]
}

# And a bar that is ready still gets its redraw, or the guard has just switched
# the refresh off.
@test "a bar that is ready is asked to redraw" {
  wg_fake_bar "trap 'touch \"$WG_TMP/redrawn\"' RTMIN+11; while :; do sleep 0.05; done"
  wg_fake_bar_ready
  wg_signal_waybar 11
  local i=0
  while (( i++ < 40 )) && [[ ! -e $WG_TMP/redrawn ]]; do sleep 0.05; done
  kill "$FAKE_BAR" 2>/dev/null || true
  wait "$FAKE_BAR" 2>/dev/null || true
  [ -e "$WG_TMP/redrawn" ]
}

@test "with no bar running at all, asking for a redraw is not an error" {
  export WG_WAYBAR_PROC=wgnosuchbar
  run wg_signal_waybar 11
  [ "$status" -eq 0 ]
}
