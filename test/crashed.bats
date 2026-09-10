#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  WG_CRASH_N=0
}

teardown() { wg_teardown_tmp; }

wingroup() { "$WG_ROOT/bin/wingroup" "$@"; }

# Files one crash the way the machine does: record the live session first, then
# file the kill against its scope -- wg_crashed_add ignores a scope no session
# was ever recorded for, which is what keeps Brave's oom-kills out of the list.
#
# Through the library rather than by writing crashed.json by hand, so a record
# shape lib/sessions.sh would never produce is not a record these tests trust.
# The subshell keeps the libraries' defaults out of the test's own shell.
wg_crash() {
  local cwd="$1" session="${2:-}" at="${3:-2026-09-10T11:02:03+02:00}"
  WG_CRASH_N=$(( WG_CRASH_N + 1 ))
  # A scope of its own per crash: the list is deduped by scope, so two crashes
  # sharing one would silently become a single record.
  local scope
  scope="$(wg_fake_scope "c0ffee0$WG_CRASH_N")"
  (
    set -euo pipefail
    source "$WG_LIB_DIR/state.sh"
    source "$WG_LIB_DIR/sessions.sh"
    wg_sessions_record "$scope" "$session" "$cwd" hook
    wg_crashed_add "$scope" "$at"
  )
}

@test "crashed says plainly when nothing has been killed" {
  run wingroup crashed
  [ "$status" -eq 0 ]
  [[ "$output" == *"no crashed sessions"* ]]
}

@test "crashed lists the time, the directory and whether the session can be resumed" {
  wg_crash "$WG_TMP/shop-web" "sess-a1" "2026-09-10T11:02:03+02:00"
  wg_crash "$WG_TMP/shop-api" "" "2026-09-10T11:05:00+02:00"
  run wingroup crashed
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "2 session(s) killed by systemd-oomd:" ]]
  [[ "${lines[1]}" == *"2026-09-10T11:02:03+02:00"* ]]
  [[ "${lines[1]}" == *"$WG_TMP/shop-web"* ]]
  [[ "${lines[1]}" == *"resumable"* ]]
  [[ "${lines[2]}" == *"2026-09-10T11:05:00+02:00"* ]]
  [[ "${lines[2]}" == *"no session id"* ]]
}

@test "crashed launches nothing and clears nothing on its own" {
  wg_crash "$WG_TMP/shop-web" "sess-a1"
  run wingroup crashed
  [ ! -s "$WG_LAUNCH_LOG" ]
  run wingroup crashed
  [[ "${lines[0]}" == "1 session(s) killed by systemd-oomd:" ]]
}

@test "--restore launches one terminal per record, in its directory and on its session" {
  mkdir -p "$WG_TMP/shop-web" "$WG_TMP/shop-api"
  wg_crash "$WG_TMP/shop-web" "sess-a1"
  wg_crash "$WG_TMP/shop-api" "sess-b2"
  run wingroup crashed --restore
  [ "$status" -eq 0 ]

  # Counted rather than indexed: the launches are backgrounded, so two of them
  # can reach the log in either order.
  run bash -c "wc -l <'$WG_LAUNCH_LOG'"
  [ "$output" -eq 2 ]
  run bash -c "grep -cF -- '--dir=$WG_TMP/shop-web' '$WG_LAUNCH_LOG'"
  [ "$output" -eq 1 ]
  run bash -c "grep -F -- '--dir=$WG_TMP/shop-web' '$WG_LAUNCH_LOG'"
  [[ "$output" == *"xdg-terminal-exec"* ]]
  [[ "$output" == *"claude --resume"* ]]
  [[ "$output" == *"sess-a1"* ]]
  run bash -c "grep -F -- '--dir=$WG_TMP/shop-api' '$WG_LAUNCH_LOG'"
  [[ "$output" == *"sess-b2"* ]]
}

@test "--restore leaves the list empty and refreshes the bar" {
  mkdir -p "$WG_TMP/shop-web"
  wg_crash "$WG_TMP/shop-web" "sess-a1"
  run wingroup crashed --restore
  [[ "$output" == *"relaunched 1 session(s)"* ]]
  run wingroup crashed
  [[ "$output" == *"no crashed sessions"* ]]
  run bash -c "wc -l <'$WG_REFRESH_LOG'"
  [ "$output" -eq 1 ]
}

# crashed.json is the only surviving record of a session id -- /proc is gone by
# the time anyone looks, and the journal line reporting the kill never knew it --
# so a launcher that could not start a terminal has to leave the list alone.
# Clearing it on a failed relaunch throws away the one thing the user came back
# for, and nothing anywhere can hand it back.
@test "a launcher that fails leaves the crash list intact, session id and all" {
  mkdir -p "$WG_TMP/shop-web"
  wg_crash "$WG_TMP/shop-web" "sess-a1"
  export WG_LAUNCH_CMD="$WG_ROOT/test/bin/launch-fail-stub"
  run wingroup crashed --restore
  # Asserted first, so that what follows is known to be about a launch that was
  # attempted and failed, not one that never reached the launcher at all.
  run bash -c "wc -l <'$WG_LAUNCH_LOG'"
  [ "$output" -eq 1 ]
  run jq -r '.crashed[0].session' "$WG_RUNTIME_DIR/crashed.json"
  [ "$output" = "sess-a1" ]
  run wingroup crashed
  [[ "${lines[0]}" == "1 session(s) killed by systemd-oomd:" ]]
}

# The launcher's own complaint goes to a terminal that never opened, so this is
# the only place the user can learn that the relaunch did not happen.
@test "a failed relaunch says so rather than passing for a clean one" {
  mkdir -p "$WG_TMP/shop-web"
  wg_crash "$WG_TMP/shop-web" "sess-a1"
  export WG_LAUNCH_CMD="$WG_ROOT/test/bin/launch-fail-stub"
  run wingroup crashed --restore
  [[ "$output" == *"1 launch(es) failed"* ]]
  [[ "$output" == *"keeping the list so the session ids are not lost"* ]]
}

# The whole list survives, not only the record that failed: the library has no
# per-record delete, and the trade is not close. Flagging a session that did come
# back costs the user one --clear; dropping the record of one that did not costs
# them its id for good.
@test "a partial failure keeps the whole list, including the session that came back" {
  mkdir -p "$WG_TMP/shop-web" "$WG_TMP/shop-api"
  wg_crash "$WG_TMP/shop-web" "sess-a1"
  wg_crash "$WG_TMP/shop-api" "sess-b2"
  export WG_LAUNCH_CMD="$WG_ROOT/test/bin/launch-fail-stub"
  export WG_LAUNCH_FAIL_MATCH="--dir=$WG_TMP/shop-api"
  run wingroup crashed --restore
  [[ "$output" == *"1 launch(es) failed"* ]]
  run bash -c "wc -l <'$WG_LAUNCH_LOG'"
  [ "$output" -eq 2 ]
  # Sorted rather than indexed, for the reason the launch log is counted: the
  # launches are backgrounded, so the two records can be written in either order.
  run jq -r '[.crashed[].session] | sort | join(",")' "$WG_RUNTIME_DIR/crashed.json"
  [ "$output" = "sess-a1,sess-b2" ]
}

# The session id cannot be recovered after the process is gone, so a session
# that was running before the hook was installed has none. Its directory is
# still worth reopening; the conversation is simply not coming back.
@test "a record with no session id starts a plain claude and says so" {
  mkdir -p "$WG_TMP/shop-web"
  wg_crash "$WG_TMP/shop-web" ""
  run wingroup crashed --restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"no session id for $WG_TMP/shop-web"* ]]
  run cat "$WG_LAUNCH_LOG"
  [[ "$output" == *"--dir=$WG_TMP/shop-web"* ]]
  [[ "$output" == *"claude"* ]]
  [[ "$output" != *"--resume"* ]]
}

@test "a record whose directory is gone is skipped with a message and launches nothing" {
  mkdir -p "$WG_TMP/shop-web"
  wg_crash "$WG_TMP/vanished" "sess-x"
  wg_crash "$WG_TMP/shop-web" "sess-a1"
  run wingroup crashed --restore
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped $WG_TMP/vanished"* ]]
  [[ "$output" == *"the directory is gone"* ]]
  [[ "$output" == *"relaunched 1 session(s), skipped 1"* ]]
  run bash -c "wc -l <'$WG_LAUNCH_LOG'"
  [ "$output" -eq 1 ]
  run bash -c "grep -cF -- '--dir=$WG_TMP/vanished' '$WG_LAUNCH_LOG' || true"
  [ "$output" -eq 0 ]
}

@test "--clear empties the list without launching anything" {
  mkdir -p "$WG_TMP/shop-web"
  wg_crash "$WG_TMP/shop-web" "sess-a1"
  run wingroup crashed --clear
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared 1 crashed session(s)"* ]]
  [ ! -s "$WG_LAUNCH_LOG" ]
  run wingroup crashed
  [[ "$output" == *"no crashed sessions"* ]]
}

@test "crashed rejects an unknown flag" {
  run wingroup crashed --burn-it-down
  [ "$status" -ne 0 ]
  [ ! -s "$WG_LAUNCH_LOG" ]
}
