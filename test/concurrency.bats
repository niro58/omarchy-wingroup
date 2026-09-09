#!/usr/bin/env bats
#
# The lost update, reproduced.
#
# wg_state_write is atomic -- temp file plus rename -- so a reader never sees
# half a document. That was never the problem. The problem is that both
# bin/wingroup and bin/wingroup-daemon *read* the state, change it and write it
# back, and with no lock across those three steps the second writer commits a
# document built from a copy taken before the first writer's change. The first
# change is gone, with no error printed anywhere: `wingroup new` reports success
# and the group is not there.
#
# Each test below runs two writers at once, each making a change the other does
# not touch, and asserts that both survive.

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
}

teardown() { wg_teardown_tmp; }

# A jq that takes 100ms before doing its job, ahead of the real one on PATH.
#
# The race is real without it but narrow -- microseconds between a writer's read
# and its write -- so a test that just launched two writers would pass most of
# the time whether the bug is there or not. jq is what every step of a
# read-modify-write goes through, so slowing it widens the window each writer
# leaves open to something a scheduler cannot miss. It slows nothing else: only
# the racing processes get this PATH.
wg_slow_jq() {
  local real
  real="$(command -v jq)"
  mkdir -p "$WG_TMP/slow"
  cat >"$WG_TMP/slow/jq" <<EOF
#!/usr/bin/env bash
sleep 0.1
exec "$real" "\$@"
EOF
  chmod +x "$WG_TMP/slow/jq"
  export WG_SLOW_PATH="$WG_TMP/slow:$PATH"
}

# The exact case the original review found: a `wingroup new` landing inside the
# daemon's closewindow handler. The daemon deletes one override; the CLI appends
# one group. Neither cares about the other's half of the document, and both
# halves have to be there afterwards.
@test "a group created while a window closes is not lost" {
  wg_slow_jq

  PATH="$WG_SLOW_PATH" "$WG_ROOT/bin/wingroup" new alpha >/dev/null 2>&1 &
  local cli=$!
  PATH="$WG_SLOW_PATH" WG_DAEMON_NO_MAIN=1 bash -c \
    "source '$WG_ROOT/bin/wingroup-daemon'; wg_daemon_handle_line 'closewindow>>aaa3'" \
    >/dev/null 2>&1 &
  local daemon=$!
  wait "$cli"
  wait "$daemon"

  # The CLI's change: the new group is there.
  [ "$(jq -r '[.groups[].name] | index("alpha") // "missing"' "$WG_STATE_DIR/state.json")" != "missing" ]
  # The daemon's change: the closed window's override is gone.
  [ "$(jq -r '.overrides["0xaaa3"] // "gone"' "$WG_STATE_DIR/state.json")" = "gone" ]
  # And nothing that was there before was dropped on the way.
  [ "$(jq '.groups | length' "$WG_STATE_DIR/state.json")" -eq 4 ]
}

# The same race between two CLI invocations, which is what a keybind and a
# terminal are: auto-assignment toggled from the picker while a group is being
# created in a terminal.
#
# The short quarter-second is what makes this one an actual race rather than two
# commands that happen to run at once: `wingroup new` does more work before it
# writes than `toggle-auto` does in total, so started together the toggle simply
# finishes first and the new group is built on top of it. Started a moment
# later, the toggle reads and writes entirely inside the window `new` leaves
# open -- and unlocked, `new` then commits a document that never had the toggle
# in it.
@test "two CLI writers each making a different change both survive" {
  wg_slow_jq

  PATH="$WG_SLOW_PATH" "$WG_ROOT/bin/wingroup" new alpha >/dev/null 2>&1 &
  local a=$!
  sleep 0.25
  PATH="$WG_SLOW_PATH" "$WG_ROOT/bin/wingroup" toggle-auto >/dev/null 2>&1 &
  local b=$!
  wait "$a"
  wait "$b"

  [ "$(jq -r '[.groups[].name] | index("alpha") // "missing"' "$WG_STATE_DIR/state.json")" != "missing" ]
  [ "$(jq -r '.auto' "$WG_STATE_DIR/state.json")" = "false" ]
}

# Enough writers that a single unlucky interleaving is not what is being
# measured: every one of them has to be in the file at the end.
@test "a crowd of writers all land" {
  wg_slow_jq

  local i pids=()
  for i in 0 1 2 3 4; do
    PATH="$WG_SLOW_PATH" "$WG_ROOT/bin/wingroup" new "g$i" >/dev/null 2>&1 &
    pids+=($!)
  done
  for i in "${pids[@]}"; do wait "$i"; done

  run jq -r '[.groups[].name] | sort | join(",")' "$WG_STATE_DIR/state.json"
  [ "$output" = "drivora,everest,g0,g1,g2,g3,g4,plat" ]
}
