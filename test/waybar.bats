#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
}

teardown() { wg_teardown_tmp; }

# The module's "class" is a plain string when it carries one class and a JSON
# array when it carries several -- waybar takes either, and only the array form
# puts more than one class on the widget. Read whichever it is as one
# space-separated list, so a single assertion covers the whole set.
wg_class_list() {
  jq -r 'if (.class | type) == "array" then (.class | join(" ")) else .class end'
}

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
  # The group also has one idle session, so the heat class rides along: the
  # state and the heat are two facts about the same group, not one field
  # fighting over itself.
  [ "$(wg_class_list <<<"$output")" = "busy idle1" ]
}

@test "the group on the focused monitor gets the active class, which beats busy" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "active idle1" ]
}

# The bug: `hyprctl activeworkspace` answers for the focused monitor only, so
# focusing the laptop screen made the group still filling the other monitor
# look like it was nowhere at all.
@test "a group on screen on an unfocused monitor is visible, not inactive" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-laptop-focused.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "visible idle1" ]
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
  [ "$(wg_class_list <<<"$output")" = "active idle1" ]
}

@test "with WAYBAR_OUTPUT_NAME the other screen's bar calls it visible, not active" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WAYBAR_OUTPUT_NAME=eDP-2
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "visible idle1" ]
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
  [ "$(wg_class_list <<<"$output")" = "active idle1" ]
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-laptop-focused.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "visible idle1" ]
}

# A bar on an output the compositor does not list -- a monitor unplugged between
# the two questions -- must still say something sensible rather than nothing.
@test "an unknown WAYBAR_OUTPUT_NAME falls back to on-screen-somewhere" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WAYBAR_OUTPUT_NAME=HDMI-A-9
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  [ "$(wg_class_list <<<"$output")" = "visible idle1" ]
}

@test "on a single monitor the focused group is still active" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-single.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "active idle1" ]
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

# --- idle heat -------------------------------------------------------------
#
# An idle session is unused capacity: something finished, sitting there waiting
# to be given the next thing. The more of them a group is holding, the harder
# the button should pull the eye, so the module emits the count as a class --
# idle1..idle4 -- and style.css ramps it from warm to red. The count is capped:
# past a handful the exact number stops changing what you do about it.

# A client list of $2 idle and $3 busy Claude windows, all of them sent to
# group $1 by an override. An override owns a window outright, which saves
# inventing a project and a fixture cwd for every window just to get a count up.
wg_group_windows() {
  local group="$1" idle="$2" busy="${3:-0}"
  jq -n --argjson i "$idle" --argjson b "$busy" '
    [ range(0; $i) | {address: "0xbb\(.)", title: "✳ waiting for the next thing"} ]
    + [ range(0; $b) | {address: "0xcc\(.)", title: "◐ working on it"} ]
    | map(. + {pid: 9000, class: "Alacritty", floating: false,
               workspace: {id: 1, name: "1"}})' >"$WG_TMP/clients-heat.json"
  export WG_FIXTURE_CLIENTS="$WG_TMP/clients-heat.json"
  jq --arg g "$group" --argjson i "$idle" --argjson b "$busy" '
    .overrides = (reduce range(0; $i) as $n ({}; .["0xbb\($n)"] = $g)
                  | reduce range(0; $b) as $n (.; .["0xcc\($n)"] = $g))' \
    "$WG_STATE_DIR/state.json" >"$WG_TMP/state.heat"
  mv -f "$WG_TMP/state.heat" "$WG_STATE_DIR/state.json"
}

# Nothing waiting on you is the common case and has to look exactly as it
# always did: no heat class, nothing for the ramp to style.
@test "a group with no idle sessions emits no idle class at all" {
  wg_group_windows everest 0 0
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "" ]
}

@test "one idle session warms the group to the first step of the ramp" {
  wg_group_windows everest 1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "idle1" ]
}

@test "two idle sessions step the ramp up" {
  wg_group_windows everest 2
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "idle2" ]
}

@test "three idle sessions step the ramp up again" {
  wg_group_windows everest 3
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "idle3" ]
}

# The ceiling is the class, not the count: the superscript still says five.
@test "five idle sessions cap at the top step of the ramp" {
  wg_group_windows everest 5
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "idle4" ]
  [ "$(jq -r '.text' <<<"$output")" = "everest⁵" ]
}

@test "a wildly idle group still caps at the top step" {
  wg_group_windows everest 12
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "idle4" ]
  [ "$(jq -r '.text' <<<"$output")" = "everest¹²" ]
}

# The heat is a second class beside the state, never instead of it -- waybar
# puts both on the widget, so #custom-wingroup0.busy.idle4 is a live selector.
@test "the idle class rides alongside busy" {
  wg_group_windows everest 5 1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "busy idle4" ]
}

@test "the idle class rides alongside active" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  wg_group_windows template 3
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "active idle3" ]
}

@test "the idle class rides alongside visible" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  wg_group_windows template 2
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-laptop-focused.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "visible idle2" ]
}

# waybar-custom(5): "The class parameter also accepts an array of strings."
# That array is the only thing that puts two classes on one widget -- a string
# with a space in it becomes a single GTK class named "busy idle4", which no
# selector matches. One class stays the string the module always emitted.
@test "one class goes out as a string and several as the array waybar needs" {
  wg_group_windows everest 1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class | type' <<<"$output")" = "string" ]
  wg_group_windows everest 5 1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class | type' <<<"$output")" = "array" ]
  [ "$(jq -r '.class | length' <<<"$output")" = "2" ]
}
