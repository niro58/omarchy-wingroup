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
  [ "$(jq -r '.follow' <<<"$output")" = "true" ]
  [ -f "$WG_STATE_DIR/state.json" ]
}

# Following a window onto its group's workspace is what makes a terminal the
# user just opened a terminal the user can see, so it is on unless they say
# otherwise -- both in a fresh state file and in one recovered from corruption.
@test "the default state follows new windows" {
  run wg_state_read
  [ "$(jq -r '.follow' <<<"$output")" = "true" ]
  [ "$(jq -r '[keys_unsorted[]] | join(",")' <<<"$output")" = "auto,follow,catchall,groups,overrides" ]
}

@test "wg_state_read returns the seeded fixture" {
  wg_seed_state
  run wg_state_read
  [ "$(jq -r '.groups[0].name' <<<"$output")" = "shop" ]
  [ "$(jq -r '.overrides["0xaaa3"]' <<<"$output")" = "site" ]
}

@test "wg_state_read recovers from a corrupt file and preserves it" {
  mkdir -p "$WG_STATE_DIR"
  printf 'not json at all' >"$WG_STATE_DIR/state.json"
  run wg_state_read
  [ "$status" -eq 0 ]
  [ "$(jq '.groups | length' <<<"$output")" -eq 0 ]
  [ "$(jq -r '.follow' <<<"$output")" = "true" ]
  [ -f "$WG_STATE_DIR/state.json.corrupt" ]
  [ "$(cat "$WG_STATE_DIR/state.json.corrupt")" = "not json at all" ]
}

@test "wg_state_write replaces the file atomically and leaves no temp files" {
  wg_seed_state
  wg_state_write "$(jq '.auto = false' "$WG_STATE_DIR/state.json")"
  [ "$(jq -r '.auto' "$WG_STATE_DIR/state.json")" = "false" ]
  # -A, not a bare ls: the temp files this is looking for are named
  # .state.XXXXXX, and a bare ls never lists them.
  run bash -c "ls -A $WG_STATE_DIR | grep -c . "
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

# --- the lock -------------------------------------------------------------
#
# wg_state_write is atomic in the sense that a reader never sees half a file,
# but read-modify-write is three steps and both bin/wingroup and
# bin/wingroup-daemon do it. wg_state_update takes a lock across all three.

@test "wg_state_update applies its filter and commits the result" {
  wg_seed_state
  # shellcheck disable=SC2016
  wg_state_update '.overrides[$a] = $g' --arg a 0xbeef --arg g shop
  [ "$(jq -r '.overrides["0xbeef"]' "$WG_STATE_DIR/state.json")" = "shop" ]
  [ "$(jq -r '.overrides["0xaaa3"]' "$WG_STATE_DIR/state.json")" = "site" ]
}

@test "wg_state_update leaves the state alone when the filter fails" {
  wg_seed_state
  local before
  before="$(cat "$WG_STATE_DIR/state.json")"
  run wg_state_update 'this is not a filter'
  [ "$status" -ne 0 ]
  [ "$(cat "$WG_STATE_DIR/state.json")" = "$before" ]
}

@test "wg_state_update seeds the default state like a plain read does" {
  wg_state_update '.auto = false'
  [ "$(jq -r '.auto' "$WG_STATE_DIR/state.json")" = "false" ]
  [ "$(jq -r '.follow' "$WG_STATE_DIR/state.json")" = "true" ]
}

@test "wg_state_update recovers a corrupt state file rather than writing over it" {
  mkdir -p "$WG_STATE_DIR"
  printf 'not json at all' >"$WG_STATE_DIR/state.json"
  wg_state_update '.auto = false'
  [ "$(cat "$WG_STATE_DIR/state.json.corrupt")" = "not json at all" ]
  [ "$(jq '.groups | length' "$WG_STATE_DIR/state.json")" -eq 0 ]
}

@test "wg_state_update releases the lock, so the next one is not left waiting" {
  wg_seed_state
  export WG_STATE_LOCK_WAIT=2
  wg_state_update '.auto = false'
  wg_state_update '.catchall = "shop"'
  [ "$(jq -r '.catchall' "$WG_STATE_DIR/state.json")" = "shop" ]
}

# Holds the lock in a background process until wg_release_lock, leaving its pid
# in WG_LOCK_HOLDER. It `exec`s the sleep so the process holding the descriptor
# is the process whose pid this is -- a shell that forked a sleep would hand the
# inherited descriptor to a child that killing the shell does not reach. Its
# standard streams go to /dev/null: a background job holding the test's stdout
# open is a hang, not a failure.
WG_LOCK_HOLDER=""

wg_hold_lock() {
  mkdir -p "$WG_STATE_DIR"
  rm -f "$WG_TMP/held"
  bash -c "exec 9>>'$WG_STATE_DIR/.state.lock'; flock 9; : >'$WG_TMP/held'; exec sleep 30" \
    </dev/null >/dev/null 2>&1 &
  WG_LOCK_HOLDER=$!
  local i
  for (( i = 0; i < 100; i++ )); do
    [[ -e "$WG_TMP/held" ]] && return 0
    sleep 0.05
  done
  return 1
}

wg_release_lock() {
  [[ -n $WG_LOCK_HOLDER ]] || return 0
  kill -9 "$WG_LOCK_HOLDER" 2>/dev/null || true
  local i
  for (( i = 0; i < 100; i++ )); do
    kill -0 "$WG_LOCK_HOLDER" 2>/dev/null || break
    sleep 0.05
  done
  WG_LOCK_HOLDER=""
}

# The bar, the picker and every resolve read the state and change nothing. They
# must not queue behind a writer for a document they are about to re-read.
@test "wg_state_read does not wait for the lock" {
  wg_seed_state
  wg_hold_lock
  run timeout 3 bash -c "source '$WG_ROOT/lib/state.sh'; wg_state_read"
  wg_release_lock
  [ "$status" -eq 0 ]
  [ "$(jq -r '.groups[0].name' <<<"$output")" = "shop" ]
}

@test "wg_state_update waits for a held lock and gives up rather than hanging" {
  wg_seed_state
  local before
  before="$(cat "$WG_STATE_DIR/state.json")"
  wg_hold_lock
  run timeout 10 env WG_STATE_LOCK_WAIT=1 \
    bash -c "source '$WG_ROOT/lib/state.sh'; wg_state_update '.auto = false'"
  wg_release_lock
  [ "$status" -eq 1 ]
  [[ "$output" == *"timed out"* ]]
  [ "$(cat "$WG_STATE_DIR/state.json")" = "$before" ]
}

# The lock is an flock on an open descriptor, so a process that dies holding it
# releases it: a killed picker or a crashed daemon must not wedge the CLI.
@test "a caller killed while holding the lock does not wedge the next writer" {
  wg_seed_state
  wg_hold_lock
  wg_release_lock
  run timeout 5 env WG_STATE_LOCK_WAIT=3 \
    bash -c "source '$WG_ROOT/lib/state.sh'; wg_state_update '.auto = false'"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.auto' "$WG_STATE_DIR/state.json")" = "false" ]
}

@test "wg_state_group_names lists groups in order" {
  wg_seed_state
  run wg_state_group_names
  [ "${lines[0]}" = "shop" ]
  [ "${lines[1]}" = "site" ]
}

@test "wg_state_group_field reads a scalar and a missing group" {
  wg_seed_state
  run wg_state_group_field shop label
  [ "$output" = "shop" ]
  run wg_state_group_field nosuch label
  [ "$output" = "" ]
}

# The prune is a read-modify-write like every other, so it goes through
# wg_state_update and lands in the file rather than on stdout.
@test "wg_state_prune_overrides drops addresses that are gone" {
  wg_seed_state
  printf '0xaaa1\n0xaaa2\n' | wg_state_prune_overrides
  [ "$(jq '.overrides | length' "$WG_STATE_DIR/state.json")" -eq 0 ]
}

@test "wg_state_prune_overrides keeps addresses that are still live" {
  wg_seed_state
  printf '0xaaa3\n' | wg_state_prune_overrides
  [ "$(jq -r '.overrides["0xaaa3"]' "$WG_STATE_DIR/state.json")" = "site" ]
}
