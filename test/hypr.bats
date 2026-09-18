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

# --- naming a workspace to the compositor ------------------------------------

# "name:5" is not workspace 5. Hyprland keeps named workspaces apart from
# numbered ones, so dispatching at "name:5" makes a second workspace also called
# 5, on whatever monitor has focus. Found on a live desktop with two of them:
# one holding a session, one being looked at and empty.
@test "a numbered workspace is addressed as the number it is" {
  [ "$(wg_ws_selector 5)" = "5" ]
  [ "$(wg_ws_selector 42)" = "42" ]
}

@test "a group is a named workspace and says so" {
  [ "$(wg_ws_selector plat)" = "name:plat" ]
  [ "$(wg_ws_selector 3dprint)" = "name:3dprint" ]
}

# A scratchpad names itself: "name:special:magic" would make an ordinary
# workspace called "special:magic", which is the trap this whole function is
# about, one level further in.
@test "a scratchpad is passed through as it is" {
  [ "$(wg_ws_selector special:magic)" = "special:magic" ]
}

@test "nothing in, nothing out" {
  [ -z "$(wg_ws_selector "")" ]
}

# --- speaking to a compositor that has moved on -----------------------------
#
# Hyprland 0.56 replaced the dispatch string with a Lua API. "hyprctl dispatch
# movetoworkspacesilent name:plat,address:0x..." is read as Lua source there and
# fails to parse, so every move wingroup makes stopped working the day Omarchy 4
# landed: the terminals came back from the snapshot and piled up wherever they
# opened, because nothing could place them.
#
# The old spelling stays the one written in this codebase, and is translated on
# the way out. These check the translation itself; whether the compositor wants
# it is a separate question, probed once.

@test "a silent move becomes a window move that does not follow" {
  run wg_hypr_lua_form movetoworkspacesilent "name:plat,address:0xaaa1"
  [ "$status" -eq 0 ]
  [ "$output" = 'hl.dsp.window.move({ workspace = "name:plat", window = "address:0xaaa1", follow = false })' ]
}

# The workspace keeps its old selector, and that is not a guess: "plat" on its
# own is accepted and silently moves nothing.
@test "a move to a numbered workspace keeps the bare number" {
  run wg_hypr_lua_form movetoworkspacesilent "5,address:0xaaa1"
  [ "$status" -eq 0 ]
  [[ "$output" == *'workspace = "5"'* ]]
}

@test "a following move follows" {
  run wg_hypr_lua_form movetoworkspace "name:plat,address:0xaaa1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"follow = true"* ]]
}

@test "switching workspace becomes a focus" {
  run wg_hypr_lua_form workspace "name:plat"
  [ "$output" = 'hl.dsp.focus({ workspace = "name:plat" })' ]
}

@test "focusing a window becomes a focus with a window" {
  run wg_hypr_lua_form focuswindow "address:0xaaa1"
  [ "$output" = 'hl.dsp.focus({ window = "address:0xaaa1" })' ]
}

@test "moving a workspace to a monitor names both" {
  run wg_hypr_lua_form moveworkspacetomonitor "name:plat DP-1"
  [ "$output" = 'hl.dsp.workspace.move({ workspace = "name:plat", monitor = "DP-1" })' ]
}

# swapwindow swapped the focused window with the named one; window.swap takes
# that one as its target.
@test "swapping names the other window as the target" {
  run wg_hypr_lua_form swapwindow "address:0xaaa2"
  [ "$output" = 'hl.dsp.window.swap({ target = "address:0xaaa2" })' ]
}

@test "an exact resize is pulled apart into x, y and the window" {
  run wg_hypr_lua_form resizewindowpixel "exact 1000 900,address:0xaaa1"
  [ "$output" = 'hl.dsp.window.resize({ x = "1000", y = "900", window = "address:0xaaa1", exact = true })' ]
}

# Guessing a translation for a dispatcher nobody here calls would be inventing
# an API by extrapolation.
@test "a dispatcher wingroup does not use is not translated" {
  run wg_hypr_lua_form togglefloating "address:0xaaa1"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "on a compositor that does not take Lua, the old spelling goes out as it is" {
  WG_HYPR_LUA=0 wg_hypr_dispatch movetoworkspacesilent "name:plat,address:0xaaa1"
  [ "$(dispatches)" = "movetoworkspacesilent name:plat,address:0xaaa1" ]
}

@test "and on one that does, the Lua goes out instead" {
  WG_HYPR_LUA=1 wg_hypr_dispatch movetoworkspacesilent "name:plat,address:0xaaa1"
  [ "$(dispatches)" = 'hl.dsp.window.move({ workspace = "name:plat", window = "address:0xaaa1", follow = false })' ]
}

# The probe, on its own stub: a compositor that answers the new API's no-op with
# "ok" takes Lua, and one that does not, does not.
@test "a compositor that answers hl.dsp.no_op takes Lua" {
  printf '#!/usr/bin/env bash\nprintf "ok\\n"\n' >"$WG_TMP/hyprctl-new"
  chmod +x "$WG_TMP/hyprctl-new"
  WG_HYPRCTL="$WG_TMP/hyprctl-new" WG_HYPR_LUA="" run wg_hypr_lua
  [ "$status" -eq 0 ]
}

@test "one that refuses it does not" {
  printf '#!/usr/bin/env bash\nprintf "Invalid dispatcher\\n" >&2\nexit 1\n' >"$WG_TMP/hyprctl-old"
  chmod +x "$WG_TMP/hyprctl-old"
  WG_HYPRCTL="$WG_TMP/hyprctl-old" WG_HYPR_LUA="" run wg_hypr_lua
  [ "$status" -ne 0 ]
}

# Asked once, not once per dispatch: this runs on every window that opens.
@test "the compositor is asked which language it speaks only once" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$WG_TMP/probes"\nprintf "ok\\n"\n' >"$WG_TMP/hyprctl-count"
  chmod +x "$WG_TMP/hyprctl-count"
  : >"$WG_TMP/probes"
  export WG_HYPRCTL="$WG_TMP/hyprctl-count" WG_HYPR_LUA=""
  wg_hypr_dispatch focuswindow "address:0xaaa1" >/dev/null
  wg_hypr_dispatch focuswindow "address:0xaaa2" >/dev/null
  wg_hypr_dispatch focuswindow "address:0xaaa3" >/dev/null
  run grep -c 'no_op' "$WG_TMP/probes"
  [ "$output" -eq 1 ]
}

# --- asking Omarchy 4's shell to redraw --------------------------------------

@test "the shell is asked to redraw wingroup's groups" {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$WG_TMP/shell-calls" >"$WG_TMP/shell-stub"
  chmod +x "$WG_TMP/shell-stub"
  WG_SHELL_CMD="$WG_TMP/shell-stub" wg_signal_shell
  [ "$(cat "$WG_TMP/shell-calls")" = "-q wingroup.groups refresh" ]
}

# A machine on waybar has no such shell, and that is not an error.
@test "with no shell to ask, asking is not an error" {
  WG_SHELL_CMD=wg-no-such-shell run wg_signal_shell
  [ "$status" -eq 0 ]
}
