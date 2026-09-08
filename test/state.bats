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

# wg_state_read treats an unparseable state file as corrupt and replaces it with
# the empty default, so committing invalid JSON silently destroys every group.
@test "wg_state_write refuses invalid JSON and leaves the previous state intact" {
  wg_seed_state
  local before
  before="$(cat "$WG_STATE_DIR/state.json")"
  run wg_state_write 'not json at all'
  [ "$status" -ne 0 ]
  [[ "$output" == *"not valid JSON"* ]]
  [ "$(cat "$WG_STATE_DIR/state.json")" = "$before" ]
  [ ! -f "$WG_STATE_DIR/state.json.corrupt" ]
}

@test "wg_state_write refuses truncated JSON" {
  wg_seed_state
  local before
  before="$(cat "$WG_STATE_DIR/state.json")"
  run wg_state_write '{"auto":true,"groups":['
  [ "$status" -ne 0 ]
  [ "$(cat "$WG_STATE_DIR/state.json")" = "$before" ]
}

@test "wg_state_write leaves the state alone and fails when the temp write fails" {
  wg_seed_state
  local before
  before="$(cat "$WG_STATE_DIR/state.json")"
  # A temp file that exists but cannot be written: the redirection fails while
  # the file is still there for mv to commit, which is what a full disk or an
  # exceeded quota looks like from here. The daemon runs its handlers under
  # `|| true`, so errexit does not stop the mv -- the write itself has to.
  mktemp() {
    local t="$WG_STATE_DIR/.state.stubbed"
    printf 'garbage, not the state\n' >"$t"
    chmod 400 "$t"
    printf '%s\n' "$t"
  }
  run wg_state_write '{"auto":false,"catchall":null,"groups":[],"overrides":{}}'
  unset -f mktemp
  [ "$status" -ne 0 ]
  [ "$(cat "$WG_STATE_DIR/state.json")" = "$before" ]
  # and the failed temp file is not left behind
  [ ! -e "$WG_STATE_DIR/.state.stubbed" ]
}

@test "wg_state_write commits a valid write" {
  wg_seed_state
  run wg_state_write '{"auto":false,"catchall":null,"groups":[],"overrides":{}}'
  [ "$status" -eq 0 ]
  [ "$(jq -r '.auto' "$WG_STATE_DIR/state.json")" = "false" ]
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
