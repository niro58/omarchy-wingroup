#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  source "$WG_ROOT/lib/state.sh"
}

teardown() { wg_teardown_tmp; }

@test "wg_state_read seeds the default when no state file exists" {
  run wg_state_read
  [ "$status" -eq 0 ]
  [ "$(jq -r '.auto' <<<"$output")" = "true" ]
  [ "$(jq -r '.catchall' <<<"$output")" = "null" ]
  [ "$(jq '.groups | length' <<<"$output")" -eq 0 ]
  [ -f "$WG_STATE_DIR/state.json" ]
}

@test "wg_state_read returns the seeded fixture" {
  wg_seed_state
  run wg_state_read
  [ "$(jq -r '.groups[0].name' <<<"$output")" = "everest" ]
  [ "$(jq -r '.overrides["0xaaa3"]' <<<"$output")" = "plat" ]
}

@test "wg_state_read recovers from a corrupt file and preserves it" {
  mkdir -p "$WG_STATE_DIR"
  printf 'not json at all' >"$WG_STATE_DIR/state.json"
  run wg_state_read
  [ "$status" -eq 0 ]
  [ "$(jq '.groups | length' <<<"$output")" -eq 0 ]
  [ -f "$WG_STATE_DIR/state.json.corrupt" ]
  [ "$(cat "$WG_STATE_DIR/state.json.corrupt")" = "not json at all" ]
}

@test "wg_state_write replaces the file atomically and leaves no temp files" {
  wg_seed_state
  wg_state_write "$(jq '.auto = false' "$WG_STATE_DIR/state.json")"
  [ "$(jq -r '.auto' "$WG_STATE_DIR/state.json")" = "false" ]
  run bash -c "ls $WG_STATE_DIR | grep -c . "
  [ "$output" -eq 1 ]
}

@test "wg_state_group_names lists groups in order" {
  wg_seed_state
  run wg_state_group_names
  [ "${lines[0]}" = "everest" ]
  [ "${lines[1]}" = "plat" ]
}

@test "wg_state_group_field reads a scalar and a missing group" {
  wg_seed_state
  run wg_state_group_field everest label
  [ "$output" = "everest" ]
  run wg_state_group_field nosuch label
  [ "$output" = "" ]
}

@test "wg_state_prune_overrides drops addresses that are gone" {
  wg_seed_state
  run bash -c "printf '0xaaa1\n0xaaa2\n' | { source '$WG_ROOT/lib/state.sh'; wg_state_prune_overrides; }"
  [ "$(jq '.overrides | length' <<<"$output")" -eq 0 ]
}

@test "wg_state_prune_overrides keeps addresses that are still live" {
  wg_seed_state
  run bash -c "printf '0xaaa3\n' | { source '$WG_ROOT/lib/state.sh'; wg_state_prune_overrides; }"
  [ "$(jq -r '.overrides["0xaaa3"]' <<<"$output")" = "plat" ]
}
