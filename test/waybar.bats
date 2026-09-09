#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
}

teardown() { wg_teardown_tmp; }

@test "slot 0 renders the first group with its idle count as a superscript" {
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' <<<"$output")" = "everest¹" ]
}

@test "slot 1 renders the second group" {
  run "$WG_ROOT/bin/wingroup-waybar" 1
  [ "$(jq -r '.text' <<<"$output")" = "plat¹" ]
}

# The superscript is the idle count, not the busy one: what the bar is for is
# spotting a session that has finished and can be given the next thing.
@test "a group whose sessions are all busy gets no superscript" {
  wg_patch_state '.groups[0].projects = ["everest-rs"]'
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.text' <<<"$output")" = "everest" ]
}

@test "a group with no windows at all gets no superscript" {
  run "$WG_ROOT/bin/wingroup-waybar" 2
  [ "$(jq -r '.text' <<<"$output")" = "drivora" ]
  [ "$(jq -r '.class' <<<"$output")" = "" ]
}

@test "an empty slot renders empty text so waybar hides it" {
  run "$WG_ROOT/bin/wingroup-waybar" 5
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' <<<"$output")" = "" ]
}

@test "a group with busy windows gets the busy class" {
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "busy" ]
}

@test "the group on the focused monitor gets the active class, which beats busy" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "active" ]
}

# The bug: `hyprctl activeworkspace` answers for the focused monitor only, so
# focusing the laptop screen made the group still filling the other monitor
# look like it was nowhere at all.
@test "a group on screen on an unfocused monitor is visible, not inactive" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-laptop-focused.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "visible" ]
}

@test "a group on no monitor at all is not visible" {
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-laptop-focused.json"
  run "$WG_ROOT/bin/wingroup-waybar" 2
  [ "$(jq -r '.class' <<<"$output")" = "" ]
}

# The bug: both bars asked which monitor had *focus*, so a group active on the
# external screen was drawn as active on the laptop bar too. Waybar names the
# monitor a bar is drawn on in WAYBAR_OUTPUT_NAME.
@test "with WAYBAR_OUTPUT_NAME a group is active only on its own screen" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WAYBAR_OUTPUT_NAME=DP-1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "active" ]
}

@test "with WAYBAR_OUTPUT_NAME the other screen's bar calls it visible, not active" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WAYBAR_OUTPUT_NAME=eDP-2
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "visible" ]
}

@test "with WAYBAR_OUTPUT_NAME a group on no screen at all still has no class" {
  export WAYBAR_OUTPUT_NAME=eDP-2
  run "$WG_ROOT/bin/wingroup-waybar" 2
  [ "$(jq -r '.class' <<<"$output")" = "" ]
}

# It has not been confirmed that every waybar build and config exports the
# variable, so the path without it has to stay exactly as it was: the reference
# monitor is the focused one, wherever this copy of the module is drawn.
@test "without WAYBAR_OUTPUT_NAME the focused monitor still decides" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  unset WAYBAR_OUTPUT_NAME
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "active" ]
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-laptop-focused.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "visible" ]
}

# A bar on an output the compositor does not list -- a monitor unplugged between
# the two questions -- must still say something sensible rather than nothing.
@test "an unknown WAYBAR_OUTPUT_NAME falls back to on-screen-somewhere" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WAYBAR_OUTPUT_NAME=HDMI-A-9
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  [ "$(jq -r '.class' <<<"$output")" = "visible" ]
}

@test "on a single monitor the focused group is still active" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-single.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "active" ]
}

@test "the tooltip breaks the windows down into idle and busy, and lists the projects" {
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"2 windows · 1 idle · 1 busy"* ]]
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"everest-web, everest-rs, everest-api"* ]]
}

# A plain terminal is a window of the group, but it is not a session waiting.
@test "a window with no Claude session counts as neither idle nor busy" {
  wg_patch_state '.overrides["0xaaa6"] = "everest"'
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"3 windows · 1 idle · 1 busy"* ]]
  [ "$(jq -r '.text' <<<"$output")" = "everest¹" ]
}

@test "slot 7 lists overflow groups in its tooltip" {
  cp "$WG_FIXTURES/state-many.json" "$WG_STATE_DIR/state.json"
  run "$WG_ROOT/bin/wingroup-waybar" 7
  [ "$(jq -r '.text' <<<"$output")" = "g7" ]
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"2 more: g8, g9"* ]]
}

@test "slot 7 has no overflow line when there are exactly eight groups or fewer" {
  run "$WG_ROOT/bin/wingroup-waybar" 7
  [[ "$(jq -r '.tooltip' <<<"$output")" != *"more:"* ]]
}

@test "the module output is valid JSON even when the state file is corrupt" {
  printf 'garbage' >"$WG_STATE_DIR/state.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  run bash -c "'$WG_ROOT/bin/wingroup-waybar' 0 | jq -e . >/dev/null"
  [ "$status" -eq 0 ]
}
