#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  export WG_RESOLVE_RETRIES=1
  export WG_RESOLVE_DELAY=0
  export WG_DAEMON_NO_MAIN=1
  # The grace period is measured from when the daemon loads, so sourcing it here
  # would otherwise put every test inside it. Zero means "the login burst is
  # over"; the tests about the burst itself put it back.
  export WG_FOLLOW_GRACE=0
  source "$WG_ROOT/bin/wingroup-daemon"
  wg_stub_cwd
}

teardown() { wg_teardown_tmp; }

feed() {
  local line
  while IFS= read -r line; do
    wg_daemon_handle_line "$line"
  done <"$1"
}

@test "a project window is moved to its group exactly once" {
  export WG_REFRESH_DEBOUNCE_MS=5000
  feed "$WG_FIXTURES/events.txt"
  run bash -c "grep -c '^movetoworkspace name:shop,address:0xaaa1$' '$WG_DISPATCH_LOG'"
  [ "$output" -eq 1 ]
}

# The bug this answers: a terminal the user deliberately opened was filed onto
# its group's workspace with movetoworkspacesilent, leaving the user on the
# workspace they were already on -- so the window they had just asked for was
# simply gone from their screen. One dispatch moves it and takes them with it.
@test "a window the user just opened is moved and followed" {
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspace name:shop,address:0xaaa1" ]
}

# The seeded fixture has no "follow" key at all, which is what every state file
# written before this setting existed looks like. Absent has to mean on.
@test "a state file with no follow key follows" {
  run bash -c "jq -e 'has(\"follow\")' '$WG_STATE_DIR/state.json'"
  [ "$status" -ne 0 ]
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspace name:shop,address:0xaaa1" ]
}

@test "follow=false keeps the silent move" {
  wg_patch_state '.follow = false'
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspacesilent name:shop,address:0xaaa1" ]
}

# Login opens a dozen terminals at once. Following each of them would throw the
# user around the desktop before they have touched anything.
@test "a window filed during the startup grace period is filed silently" {
  export WG_FOLLOW_GRACE=10
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspacesilent name:shop,address:0xaaa1" ]
}

@test "the grace period ends and following resumes" {
  export WG_FOLLOW_GRACE=10
  WG_START_MS=$(( $(wg_now_ms) - 11000 ))
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspace name:shop,address:0xaaa1" ]
}

# wingroup-restore respawns fourteen terminals; the flag is how it says so. The
# path is spelled out rather than taken from the daemon, so that the two sides
# agreeing on it is what the test checks.
#
# It used to file them silently, and the two passes raced: restore puts a window
# back on the workspace its session was recorded on, by address, while the
# daemon files the same window by its project. Whichever dispatched last won.
# Seen on a real desktop -- a session recorded on workspace 2 was put back
# there, then dragged into the group that owns its directory, which left that
# group holding a window its saved layout knew nothing about and every tile in
# it wrong.
#
# So during a restore the daemon holds off entirely and files nothing.
@test "a window that opens while a restore is running is not filed yet" {
  : >"$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# Held off, not dropped. The window is looked at again when the restore is over,
# and by then restore has had its say -- so a window it placed into a group is
# already in a group and nothing more is done to it.
@test "a window the restore placed into a group is left alone afterwards" {
  : >"$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  wg_place_windows 1001:shop
  rm -f "$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_flush_deferred
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# And the other half of holding off: a window the restore had no workspace for
# is still filed by its project, just afterwards instead of underneath it.
@test "a window the restore left outside every group is filed once it ends" {
  : >"$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  rm -f "$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_flush_deferred
  run dispatches
  [ "$output" = "movetoworkspace name:shop,address:0xaaa1" ]
}

@test "nothing is filed while the restore is still running" {
  : >"$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  wg_daemon_flush_deferred
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "a window held over a restore is filed once, not on every tick" {
  : >"$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  rm -f "$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_flush_deferred
  wg_daemon_flush_deferred
  run bash -c "wc -l <'$WG_DISPATCH_LOG'"
  [ "$output" -eq 1 ]
}

# A terminal that dies during the restore -- a resume that fails, an oom kill --
# must not be filed by its ghost afterwards.
@test "a window that closes during the restore is not filed afterwards" {
  : >"$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  wg_daemon_handle_line "closewindow>>aaa1"
  rm -f "$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_flush_deferred
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "following resumes once the restore flag is cleared" {
  : >"$XDG_RUNTIME_DIR/wingroup-restoring"
  rm -f "$XDG_RUNTIME_DIR/wingroup-restoring"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspace name:shop,address:0xaaa1" ]
}

@test "no other window is moved" {
  export WG_REFRESH_DEBOUNCE_MS=5000
  feed "$WG_FIXTURES/events.txt"
  run bash -c "wc -l <'$WG_DISPATCH_LOG'"
  [ "$output" -eq 1 ]
}

# Following changes how a window is moved, never whether it is: a floating
# window is still not touched at all, follow or no follow.
@test "a floating window is never moved" {
  wg_daemon_handle_line "openwindow>>aaa7,1,org.gnome.Nautilus,Home"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "a window with no project is left alone under the default catchall" {
  wg_daemon_handle_line "openwindow>>aaa6,1,Alacritty,dev@host:~"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "auto=false disables all moves" {
  wg_state_write "$(jq '.auto = false' "$WG_STATE_DIR/state.json")"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# Same for a window that is already where it belongs: no dispatch, so no
# workspace switch either -- following must not become a reason to visit it.
@test "a window already on its group workspace is not moved again" {
  wg_state_write "$(jq '.groups[0].name = "1" | .groups[0].label = "one"' "$WG_STATE_DIR/state.json")"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# Opening a terminal on a group's workspace is how a user says which group they
# want it in. Filing it by its project took it off the screen they were looking
# at and put it on one they were not -- for a window they had opened a second
# earlier, deliberately, while standing in the group it was supposed to join.
#
# The fixture's 0xaaa1 belongs to shop by project and sits on workspace 1, so
# naming a *different* group "1" makes it a window opened inside a group that
# does not own it -- exactly the case that used to be dragged away.
@test "a window opened on another group's workspace is left where it is" {
  wg_state_write "$(jq '.groups[1].name = "1" | .groups[1].label = "one"' "$WG_STATE_DIR/state.json")"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# And the catchall does not get to overrule it either: a window already in a
# group is not homeless, whatever its project says.
@test "a window opened in a group is not sent to the catchall" {
  wg_state_write "$(jq '.groups[1].name = "1" | .catchall = "fleet"' "$WG_STATE_DIR/state.json")"
  wg_daemon_handle_line "openwindow>>aaa6,1,Alacritty,dev@host:~"
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# The window that still needs filing is the one that opened somewhere that is
# not a group at all, which is the case this whole path exists for.
@test "a window opened outside every group is still filed" {
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run dispatches
  [ "$output" = "movetoworkspace name:shop,address:0xaaa1" ]
}

@test "a burst of title events collapses to one refresh" {
  export WG_REFRESH_DEBOUNCE_MS=5000
  wg_daemon_handle_line "windowtitle>>aaa1"
  wg_daemon_handle_line "windowtitle>>aaa2"
  wg_daemon_handle_line "windowtitle>>aaa3"
  run bash -c "wc -l <'$WG_REFRESH_LOG'"
  [ "$output" -eq 1 ]
}

@test "with debouncing off every title event refreshes" {
  export WG_REFRESH_DEBOUNCE_MS=0
  wg_daemon_handle_line "windowtitle>>aaa1"
  wg_daemon_handle_line "windowtitle>>aaa2"
  wg_daemon_handle_line "windowtitle>>aaa3"
  run bash -c "wc -l <'$WG_REFRESH_LOG'"
  [ "$output" -eq 3 ]
}

@test "an unrecognised event line is ignored without error" {
  run wg_daemon_handle_line "somefutureevent>>whatever,1,2,3"
  [ "$status" -eq 0 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# Resolving one window used to build the whole table and throw all but one row
# away, once for floating/workspace and again for every retry -- up to eleven
# full builds per window opened. On a login burst that puts the daemon tens of
# seconds behind, moving windows after the user has already started typing.
@test "opening a window resolves only that window's cwd" {
  export WG_RESOLVE_RETRIES=10
  export WG_CWD_LOG="$WG_TMP/cwd.log"
  : >"$WG_CWD_LOG"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  # Seven clients in the fixture; the old code looked up 14 cwds (two builds).
  run bash -c "wc -l <'$WG_CWD_LOG'"
  [ "$output" -eq 1 ]
  run bash -c "sort -u '$WG_CWD_LOG'"
  [ "$output" = "1001" ]
}

@test "opening a window queries the compositor once" {
  export WG_RESOLVE_RETRIES=10
  export WG_HYPRCTL_LOG="$WG_TMP/hyprctl.log"
  : >"$WG_HYPRCTL_LOG"
  wg_daemon_handle_line "openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign"
  run bash -c "grep -c '^-j clients$' '$WG_HYPRCTL_LOG'"
  [ "$output" -eq 1 ]
}

@test "an unresolvable window still retries the configured number of times" {
  export WG_RESOLVE_RETRIES=3
  export WG_HYPRCTL_LOG="$WG_TMP/hyprctl.log"
  : >"$WG_HYPRCTL_LOG"
  wg_daemon_handle_line "openwindow>>aaa6,1,Alacritty,dev@host:~"
  # One fetch for floating/workspace/group, then WG_RESOLVE_RETRIES more.
  run bash -c "grep -c '^-j clients$' '$WG_HYPRCTL_LOG'"
  [ "$output" -eq 4 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "closewindow prunes the override for that window" {
  local before
  before="$(stat -c '%i %y' "$WG_STATE_DIR/state.json")"
  wg_daemon_handle_line "closewindow>>aaa3"
  run bash -c "jq -r '.overrides[\"0xaaa3\"] // \"gone\"' '$WG_STATE_DIR/state.json'"
  [ "$output" = "gone" ]
  # this one really is a rewrite
  [ "$(stat -c '%i %y' "$WG_STATE_DIR/state.json")" != "$before" ]
}

# Every daemon write is a lost-update opportunity against the CLI -- there is no
# lock between them -- and a window with no override is the common case.
@test "closewindow does not rewrite the state file when there is no override" {
  local before after
  before="$(stat -c '%i %y' "$WG_STATE_DIR/state.json")"
  wg_daemon_handle_line "closewindow>>aaa1"
  wg_daemon_handle_line "closewindow>>aaa2"
  wg_daemon_handle_line "closewindow>>aaa6"
  after="$(stat -c '%i %y' "$WG_STATE_DIR/state.json")"
  [ "$before" = "$after" ]
  [ "$(jq -r '.overrides["0xaaa3"]' "$WG_STATE_DIR/state.json")" = "site" ]
}

# The event a debounce turns down still has to be answered.
#
# Dropping one is only safe while another is sure to follow, and that is not how
# Claude's glyph behaves: it changes when the session's state changes and then
# sits still -- a session was observed holding ◐ for forty-five seconds without
# a single title event. So the transition that matters, ✳ to ◐ when work starts,
# is often one lone event. Turned down with nothing behind it, the bar keeps the
# old answer: a group reading "two idle" while one of the two is working.
@test "an event turned down by the debounce is still owed a refresh" {
  export WG_REFRESH_DEBOUNCE_MS=5000
  wg_daemon_handle_line "windowtitle>>aaa1"     # the first one goes through
  wg_daemon_handle_line "windowtitle>>aaa2"     # this one is inside the window
  run bash -c "wc -l <'$WG_REFRESH_LOG'"
  [ "$output" -eq 1 ]
  [ "$WG_REFRESH_PENDING" -eq 1 ]
}

# ...and paid off once the window has passed, by the loop's own idle tick rather
# than by an event that may never arrive.
@test "the owed refresh is paid off when the debounce window passes" {
  export WG_REFRESH_DEBOUNCE_MS=100
  wg_daemon_handle_line "windowtitle>>aaa1"
  wg_daemon_handle_line "windowtitle>>aaa2"
  [ "$(wc -l <"$WG_REFRESH_LOG")" -eq 1 ]

  sleep 0.3
  wg_daemon_flush_refresh
  [ "$(wc -l <"$WG_REFRESH_LOG")" -eq 2 ]
  [ "$WG_REFRESH_PENDING" -eq 0 ]
}

# A tick with nothing owed must not redraw the bar. The loop takes one of these
# several times a second on a desktop that is doing nothing at all.
@test "an idle tick with nothing pending refreshes nothing" {
  export WG_REFRESH_DEBOUNCE_MS=0
  wg_daemon_handle_line "windowtitle>>aaa1"
  [ "$(wc -l <"$WG_REFRESH_LOG")" -eq 1 ]
  wg_daemon_flush_refresh
  wg_daemon_flush_refresh
  [ "$(wc -l <"$WG_REFRESH_LOG")" -eq 1 ]
}

# Paying one off must not pay off two: the trailing edge answers the events that
# were turned down, it does not add redraws of its own.
@test "the trailing refresh fires once however many events were turned down" {
  export WG_REFRESH_DEBOUNCE_MS=100
  wg_daemon_handle_line "windowtitle>>aaa1"
  wg_daemon_handle_line "windowtitle>>aaa2"
  wg_daemon_handle_line "windowtitle>>aaa3"
  wg_daemon_handle_line "windowtitle>>aaa4"
  sleep 0.3
  wg_daemon_flush_refresh
  wg_daemon_flush_refresh
  [ "$(wc -l <"$WG_REFRESH_LOG")" -eq 2 ]
}

# The loop itself, which nothing else in this file runs.
#
# Every other test calls wg_daemon_handle_line directly, so the read loop around
# it was never exercised -- and a bug that killed the daemon on its first idle
# tick shipped with the suite green. `if read; then ... fi` followed by `rc=$?`
# reads 0, because an if whose condition failed and which has no else leaves $?
# at zero; every timeout then looked like end of stream, the loop broke, and the
# daemon was gone a fifth of a second after starting.
#
# Two things this needs that the other tests do not: a real socket, because the
# daemon refuses to start without one, and a read-write open of the fifo, because
# a write-only open blocks until something opens the far end -- which is a
# deadlock the moment the daemon declines to start.
@test "the daemon survives a quiet stretch and keeps reading afterwards" {
  local sig=testsig
  export HYPRLAND_INSTANCE_SIGNATURE="$sig"
  mkdir -p "$XDG_RUNTIME_DIR/hypr/$sig"
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' \
    "$XDG_RUNTIME_DIR/hypr/$sig/.socket2.sock"

  local fifo="$WG_TMP/events"
  mkfifo "$fifo"
  printf '#!/usr/bin/env bash\nexec cat %q\n' "$fifo" >"$WG_TMP/socat"
  chmod +x "$WG_TMP/socat"

  # Read-write, so this never blocks waiting for a reader.
  exec 9<>"$fifo"

  # env -u WG_DAEMON_NO_MAIN: setup() sets it so the rest of this file can source
  # the daemon and call its handlers without the read loop ever starting. This
  # test wants the opposite -- the loop is the thing under test -- and with the
  # variable still set the script would simply fall off the end and exit, which
  # looks exactly like the crash being investigated.
  PATH="$WG_TMP:$PATH" WG_REFRESH_POLL=0.1 \
    env -u WG_DAEMON_NO_MAIN "$WG_ROOT/bin/wingroup-daemon" \
    >"$WG_TMP/daemon.out" 2>&1 &
  local daemon=$!

  # Long enough that several read timeouts have come and gone -- the exact
  # stretch the old loop did not survive.
  sleep 1
  if ! kill -0 "$daemon" 2>/dev/null; then
    exec 9>&-
    echo "daemon exited during the quiet stretch; it said:" >&2
    tail -25 "$WG_TMP/daemon.out" | sed 's/^/    /' >&2
    return 1
  fi

  # And it is still listening afterwards.
  printf 'windowtitle>>aaa1\n' >&9
  local i=0
  while (( i++ < 50 )) && [ ! -s "$WG_REFRESH_LOG" ]; do sleep 0.1; done
  local seen=0
  [ -s "$WG_REFRESH_LOG" ] && seen=1

  kill "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  exec 9>&-
  [ "$seen" -eq 1 ]
}

# The idle tick is the only thing that can notice a restore has finished: the
# flag is a file, nobody announces its removal, and the window that was held
# back will not open a second time. So the wiring is tested through the read
# loop rather than by calling the flush directly, the way the tests above do --
# a flush that is never called from the loop leaves the window stranded on
# whatever workspace it opened on, and every test above it would still pass.
@test "the read loop files what a finished restore left behind" {
  local sig=deferredsig
  export HYPRLAND_INSTANCE_SIGNATURE="$sig"
  mkdir -p "$XDG_RUNTIME_DIR/hypr/$sig"
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' \
    "$XDG_RUNTIME_DIR/hypr/$sig/.socket2.sock"

  local fifo="$WG_TMP/events"
  mkfifo "$fifo"
  printf '#!/usr/bin/env bash\nexec cat %q\n' "$fifo" >"$WG_TMP/socat"
  chmod +x "$WG_TMP/socat"
  exec 9<>"$fifo"

  : >"$XDG_RUNTIME_DIR/wingroup-restoring"
  PATH="$WG_TMP:$PATH" WG_REFRESH_POLL=0.1 \
    env -u WG_DAEMON_NO_MAIN "$WG_ROOT/bin/wingroup-daemon" \
    >"$WG_TMP/daemon.out" 2>&1 &
  local daemon=$!

  printf 'openwindow>>aaa1,1,Alacritty,✳ Everest-web full redesign\n' >&9
  sleep 0.5
  local during=0
  [ -s "$WG_DISPATCH_LOG" ] && during=1

  # The restore ends, and nothing arrives to say so.
  rm -f "$XDG_RUNTIME_DIR/wingroup-restoring"
  local i=0
  while (( i++ < 50 )) && [ ! -s "$WG_DISPATCH_LOG" ]; do sleep 0.1; done
  local after=0
  [ -s "$WG_DISPATCH_LOG" ] && after=1

  kill "$daemon" 2>/dev/null || true
  wait "$daemon" 2>/dev/null || true
  exec 9>&-

  [ "$during" -eq 0 ]
  [ "$after" -eq 1 ]
}

# Killing the daemon has to actually free the lock.
#
# The single-instance lock is held on file descriptor 9, and an fd survives fork
# and exec -- so the journal follower inherited it. Kill the daemon and the
# follower is orphaned still holding the lock, and every later start says
# "already running" and exits. The daemon then cannot be restarted at all until
# somebody notices a stray socat is the reason. Seen for real, on this machine,
# while deploying the fix above.
@test "killing the daemon frees its lock for the next one" {
  local sig=testsig
  export HYPRLAND_INSTANCE_SIGNATURE="$sig"
  mkdir -p "$XDG_RUNTIME_DIR/hypr/$sig"
  python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])' \
    "$XDG_RUNTIME_DIR/hypr/$sig/.socket2.sock"

  local fifo="$WG_TMP/events"
  mkfifo "$fifo"
  # A follower that outlives its parent, which is what socat does.
  printf '#!/usr/bin/env bash\nexec cat %q\n' "$fifo" >"$WG_TMP/socat"
  chmod +x "$WG_TMP/socat"
  exec 9<>"$fifo"

  PATH="$WG_TMP:$PATH" WG_REFRESH_POLL=0.1 \
    env -u WG_DAEMON_NO_MAIN "$WG_ROOT/bin/wingroup-daemon" \
    >"$WG_TMP/first.out" 2>&1 &
  local first=$!
  local i=0
  while (( i++ < 50 )) && ! pgrep -f "cat $fifo" >/dev/null; do sleep 0.1; done

  kill "$first" 2>/dev/null || true
  wait "$first" 2>/dev/null || true

  # The follower is still around -- that is the point, it is what used to keep
  # the lock -- so a second daemon must still be able to start.
  PATH="$WG_TMP:$PATH" WG_REFRESH_POLL=0.1 \
    env -u WG_DAEMON_NO_MAIN "$WG_ROOT/bin/wingroup-daemon" \
    >"$WG_TMP/second.out" 2>&1 &
  local second=$!
  sleep 1
  local alive=0
  kill -0 "$second" 2>/dev/null && alive=1

  kill "$second" 2>/dev/null || true
  wait "$second" 2>/dev/null || true
  for p in $(pgrep -f "cat $fifo" 2>/dev/null); do kill "$p" 2>/dev/null || true; done
  exec 9>&-

  [[ "$(cat "$WG_TMP/second.out")" != *"already running"* ]]
  [ "$alive" -eq 1 ]
}

# A redraw runs every wingroup module in the bar, which measured 1.74s on a
# desktop with eight groups. Asking faster than that does not make the bar
# quicker, it makes a queue: waybar was found holding twelve to sixteen queued
# refresh signals, drawing the desktop as it had been twenty seconds earlier.
#
# So the floor is the cost of a redraw. The exact number is a judgement, but a
# default below a second is the mistake this is here to prevent.
@test "the daemon does not ask for redraws faster than the bar can draw one" {
  local default
  default="$(env -u WG_REFRESH_DEBOUNCE_MS bash -c \
    "WG_DAEMON_NO_MAIN=1 source '$WG_ROOT/bin/wingroup-daemon'; printf '%s' \"\$WG_REFRESH_DEBOUNCE_MS\"")"
  [ "$default" -ge 1000 ]
}
