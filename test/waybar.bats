#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
}

teardown() { wg_teardown_tmp; }

@test "slot 0 renders the first group with its busy count as a superscript" {
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' <<<"$output")" = "everest¹" ]
}

@test "slot 1 renders the second group" {
  run "$WG_ROOT/bin/wingroup-waybar" 1
  [ "$(jq -r '.text' <<<"$output")" = "plat²" ]
}

@test "a group with no busy windows gets no superscript" {
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

@test "the focused group gets the active class, which beats busy" {
  export WG_FIXTURE_ACTIVEWS="$WG_FIXTURES/activeworkspace-everest.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "active" ]
}

@test "the tooltip reports counts and the group's projects" {
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"2 windows, 1 busy"* ]]
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"everest-web, everest-rs, everest-api"* ]]
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
