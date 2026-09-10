#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  WG_CRASH_N=0
  # --menu puts a picker on the screen, so every run in this file gets the stub
  # one -- including the runs that must not open a picker at all, which is only
  # a claim worth making when a real walker was reachable.
  export WG_WALKER="$WG_ROOT/test/bin/walker-stub"
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

# --- the picker behind the bar's ⚠ button ----------------------------------

# Two crashes, both with a directory that still exists: the setup nearly every
# picker test wants.
wg_crash_pair() {
  mkdir -p "$WG_TMP/shop-web" "$WG_TMP/shop-api"
  wg_crash "$WG_TMP/shop-web" "sess-a1" "2026-09-10T11:02:03+02:00"
  wg_crash "$WG_TMP/shop-api" "" "2026-09-10T11:05:00+02:00"
}

# The index walker hands back is a position in this list, so the order is a
# contract: restore-all at 0, the records after it in file order, dismiss-all
# last.
@test "the picker offers restore-all first, then one entry per session, then dismiss-all" {
  wg_crash_pair
  export WG_WALKER_STDIN_LOG="$WG_TMP/walker-stdin"
  export WG_WALKER_PICK=""
  run wingroup crashed --menu
  [ "$status" -eq 0 ]
  run cat "$WG_WALKER_STDIN_LOG"
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == *"Restore all (2)"* ]]
  [[ "${lines[1]}" == *"$WG_TMP/shop-web"* ]]
  [[ "${lines[2]}" == *"$WG_TMP/shop-api"* ]]
  [[ "${lines[3]}" == *"Dismiss all"* ]]
}

# Resumable or not is the difference between getting the conversation back and
# getting only the directory back, and it has to be visible before the pick.
@test "a picker entry says when the session died and whether it can be resumed" {
  wg_crash_pair
  export WG_WALKER_STDIN_LOG="$WG_TMP/walker-stdin"
  export WG_WALKER_PICK=""
  run wingroup crashed --menu
  run cat "$WG_WALKER_STDIN_LOG"
  [[ "${lines[1]}" == *"2026-09-10T11:02:03+02:00"* ]]
  [[ "${lines[1]}" == *"resumable"* ]]
  [[ "${lines[2]}" == *"2026-09-10T11:05:00+02:00"* ]]
  [[ "${lines[2]}" == *"no session id"* ]]
}

@test "picking one session relaunches that one and leaves the others on the bar" {
  wg_crash_pair
  export WG_WALKER_PICK=1
  run wingroup crashed --menu
  [ "$status" -eq 0 ]
  run bash -c "wc -l <'$WG_LAUNCH_LOG'"
  [ "$output" -eq 1 ]
  run cat "$WG_LAUNCH_LOG"
  [[ "$output" == *"--dir=$WG_TMP/shop-web"* ]]
  [[ "$output" == *"claude --resume"* ]]
  [[ "$output" == *"sess-a1"* ]]
  # Only its own record is gone; the other is still on file, session id and all.
  run jq -r '[.crashed[].cwd] | join(",")' "$WG_RUNTIME_DIR/crashed.json"
  [ "$output" = "$WG_TMP/shop-api" ]
  run bash -c "wc -l <'$WG_REFRESH_LOG'"
  [ "$output" -eq 1 ]
}

# The record with no session id is the one the list must not lie about: picking
# it opens a plain claude, and never `claude --resume <directory>`.
@test "picking a session with no session id starts a plain claude in its directory" {
  wg_crash_pair
  export WG_WALKER_PICK=2
  run wingroup crashed --menu
  [ "$status" -eq 0 ]
  run cat "$WG_LAUNCH_LOG"
  [[ "$output" == *"--dir=$WG_TMP/shop-api"* ]]
  [[ "$output" != *"--resume"* ]]
  run jq -r '[.crashed[].session] | join(",")' "$WG_RUNTIME_DIR/crashed.json"
  [ "$output" = "sess-a1" ]
}

# The same trade --restore makes, made one record at a time: crashed.json is the
# only surviving copy of the session id, so a launcher that could not start a
# terminal must not take the record with it.
@test "a single restore that fails keeps its record" {
  wg_crash_pair
  export WG_LAUNCH_CMD="$WG_ROOT/test/bin/launch-fail-stub"
  export WG_WALKER_PICK=1
  run wingroup crashed --menu
  [ "$status" -ne 0 ]
  run jq -r '[.crashed[].session] | sort | join(",")' "$WG_RUNTIME_DIR/crashed.json"
  [ "$output" = ",sess-a1" ]
}

@test "picking restore-all relaunches every session and empties the list" {
  wg_crash_pair
  export WG_WALKER_PICK=0
  run wingroup crashed --menu
  [ "$status" -eq 0 ]
  [[ "$output" == *"relaunched 2 session(s)"* ]]
  run bash -c "wc -l <'$WG_LAUNCH_LOG'"
  [ "$output" -eq 2 ]
  run wingroup crashed
  [[ "$output" == *"no crashed sessions"* ]]
}

@test "picking dismiss-all launches nothing and empties the list" {
  wg_crash_pair
  export WG_WALKER_PICK=3
  run wingroup crashed --menu
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleared 2 crashed session(s)"* ]]
  [ ! -s "$WG_LAUNCH_LOG" ]
  run wingroup crashed
  [[ "$output" == *"no crashed sessions"* ]]
}

# Walking away from the picker is not an instruction to do anything.
@test "cancelling the picker launches nothing and changes no record" {
  wg_crash_pair
  export WG_WALKER_PICK=""
  run wingroup crashed --menu
  [ "$status" -eq 0 ]
  [ ! -s "$WG_LAUNCH_LOG" ]
  [ ! -s "$WG_REFRESH_LOG" ]
  run jq -r '.crashed | length' "$WG_RUNTIME_DIR/crashed.json"
  [ "$output" -eq 2 ]
}

@test "--menu with nothing crashed says so and opens no picker" {
  export WG_WALKER_ARGS_LOG="$WG_TMP/walker-args"
  run wingroup crashed --menu
  [ "$status" -eq 0 ]
  [[ "$output" == *"no crashed sessions"* ]]
  [ ! -f "$WG_WALKER_ARGS_LOG" ]
}

# The menu path skips a vanished directory for the reason --restore does: there
# is nowhere to put the terminal. It keeps the record, because the user aimed at
# one entry and nothing happened -- and it says so on the desktop, since a
# picker opened from the bar has no terminal to print into.
@test "picking a session whose directory is gone launches nothing and keeps the record" {
  mkdir -p "$WG_TMP/shop-web"
  wg_crash "$WG_TMP/vanished" "sess-x"
  wg_crash "$WG_TMP/shop-web" "sess-a1"
  export WG_WALKER_PICK=1
  run wingroup crashed --menu
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped $WG_TMP/vanished"* ]]
  [[ "$output" == *"the directory is gone"* ]]
  [ ! -s "$WG_LAUNCH_LOG" ]
  [ ! -s "$WG_REFRESH_LOG" ]
  run jq -r '[.crashed[].session] | sort | join(",")' "$WG_RUNTIME_DIR/crashed.json"
  [ "$output" = "sess-a1,sess-x" ]
  run cat "$WG_NOTIFY_LOG"
  [[ "$output" == *"$WG_TMP/vanished"* ]]
}

@test "crashed rejects an unknown flag" {
  run wingroup crashed --burn-it-down
  [ "$status" -ne 0 ]
  [ ! -s "$WG_LAUNCH_LOG" ]
}

# Every way of reaching the crashed command comes from a bar with no terminal
# behind it, so a message on stderr reaches nobody: the terminals would fail to
# appear, the count would not go down, and nothing would say why.
@test "a launch failure is notified, not just printed, when there is no terminal" {
  local shop="$WG_TMP/projects/shop-web"
  mkdir -p "$shop"
  wg_crash "$shop" "sess-1"
  export WG_LAUNCH_CMD="$WG_ROOT/test/bin/launch-fail-stub"

  # setsid, so the command really has no controlling terminal -- the same
  # condition a waybar click runs under. Asserting through wg_has_tty's own
  # branch rather than mocking it is the point.
  run bash -c "setsid '$WG_ROOT/bin/wingroup' crashed --restore </dev/null >/dev/null 2>&1 || true"
  run notifications
  [[ "$output" == *"launch(es) failed"* ]]
}

@test "a vanished directory is notified too" {
  wg_crash "$WG_TMP/projects/gone-for-good" "sess-1"
  run bash -c "setsid '$WG_ROOT/bin/wingroup' crashed --restore </dev/null >/dev/null 2>&1 || true"
  run notifications
  [[ "$output" == *"directory is gone"* ]]
}

# The usage line offers these as alternatives; the parser used to accept any
# combination and quietly honour --menu, dropping the rest without a word.
@test "combining crashed flags is refused rather than half-honoured" {
  local shop="$WG_TMP/projects/shop-web"
  mkdir -p "$shop"
  wg_crash "$shop" "sess-1"

  run wingroup crashed --menu --restore
  [ "$status" -ne 0 ]
  [ ! -s "$WG_LAUNCH_LOG" ]
  run bash -c "jq '.crashed | length' '$WG_RUNTIME_DIR/crashed.json'"
  [ "$output" -eq 1 ]
}
