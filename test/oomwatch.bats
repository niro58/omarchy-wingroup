#!/usr/bin/env bats
#
# The watcher reads two things it does not control: the user journal, which is
# mostly other people's noise, and /proc. Both are faked here -- the journal by
# a script that prints fixture lines and exits, /proc by the fixture tree in
# $WG_PROC_DIR -- so what runs is the code that ships, line parsing and all.
#
# The line that matters, verbatim from a real journal:
#
#   2026-09-10T09:14:02+0200 niro systemd[1443]: app-Hyprland-xdg\x2dterminal\x2dexec-9029a872.scope: Failed with result 'oom-kill'.
#
# Those backslashes are literal, which is why every scope in these tests comes
# from wg_fake_scope or a single-quoted string, and never from an echo -e.

load helper

setup() {
  wg_setup_tmp
  # The libraries, for reading back what the watcher wrote and for seeding the
  # map. The watcher itself is always run as the executable it ships as --
  # sourcing it would drag its `set -euo pipefail` into the test shell.
  # shellcheck source=lib/state.sh
  source "$WG_LIB_DIR/state.sh"
  # shellcheck source=lib/sessions.sh
  source "$WG_LIB_DIR/sessions.sh"

  WG_SCOPE="$(wg_fake_scope 9029a872)"
  WG_SCOPE_TWO="$(wg_fake_scope 5c14ff03)"
  # Every app on the desktop gets a scope; the browser is the one oomd actually
  # picks most days.
  WG_BROWSER_SCOPE='app-Hyprland-brave\x2dbrowser-2f31c0de.scope'
  WG_KILLED_AT="2026-09-10T09:14:02+0200"

  # The journal, faked: a script that prints whatever a test has put in
  # journal.txt and then ends. Ending is what makes --once return -- the real
  # journalctl is a follower and never does.
  printf '#!/usr/bin/env bash\ncat %q\n' "$WG_TMP/journal.txt" >"$WG_TMP/journal"
  chmod +x "$WG_TMP/journal"
  : >"$WG_TMP/journal.txt"
  export WG_JOURNAL_CMD="$WG_TMP/journal"

  # The kernel's boot id, faked. Every scan stamps the snapshot with it, and
  # the tests below need to be able to say "some other boot" -- which nothing
  # reading the machine's real boot id can.
  WG_BOOT_NOW="4f8e2c10-boot-now"
  WG_BOOT_BEFORE="1a77bd93-boot-before"
  export WG_BOOT_ID_FILE="$WG_TMP/boot-id"
  printf '%s\n' "$WG_BOOT_NOW" >"$WG_BOOT_ID_FILE"
}

teardown() {
  # The live-loop test runs a real watcher in the background. An assertion
  # failing in the middle of it never reaches that test's own kill, and a
  # journal follower left behind would outlive the suite.
  if [[ -n ${WG_WATCHER_PID:-} ]]; then
    kill -TERM "$WG_WATCHER_PID" 2>/dev/null || true
  fi
  wg_teardown_tmp
}

journal_kill() {
  printf "%s niro systemd[1443]: %s: Failed with result 'oom-kill'.\n" \
    "${2:-$WG_KILLED_AT}" "$1" >>"$WG_TMP/journal.txt"
}

journal_says() {
  printf '%s niro %s\n' "$WG_KILLED_AT" "$1" >>"$WG_TMP/journal.txt"
}

crashes() {
  jq '.crashed | length' <<<"$(wg_crashed_read)"
}

crash_field() {
  jq -r --arg f "$1" '.crashed[0][$f] // ""' <<<"$(wg_crashed_read)"
}

refreshes() {
  wc -l <"$WG_REFRESH_LOG"
}

# Waits for a predicate to hold, ten seconds at the outside. The live-loop test
# waits on a background process doing real work on a real timer, so every wait
# in it is bounded polling rather than a sleep long enough to pass on this
# machine -- a fixed sleep is either slower than it needs to be or flaky
# somewhere else, and usually both.
wait_until() {
  local i=0
  while (( i++ < 100 )); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

follower_up() { pgrep -f "cat $WG_TMP/fifo" >/dev/null; }

scope_known() {
  jq -e --arg s "$1" '.sessions | has($s)' <<<"$(wg_sessions_read)" >/dev/null
}

# The refresh is the last thing wg_oomwatch_handle_line does, so waiting on it
# means the crash record it was refreshing for is already on disk.
bar_refreshed() { (( $(refreshes) >= 1 )); }

@test "one Claude kill in a noisy stream files exactly one crash" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_says 'systemd[1443]: Started Brave.'
  journal_kill "$WG_BROWSER_SCOPE"
  journal_says "kernel: oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null)"
  journal_kill "$WG_SCOPE"
  journal_says 'systemd[1443]: Stopped Waybar.'

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(crashes)" -eq 1 ]
  [ "$(crash_field scope)" = "$WG_SCOPE" ]
  [ "$(crash_field cwd)" = "$WG_TMP/projects/shop-web" ]
  [ "$(crash_field killed_at)" = "$WG_KILLED_AT" ]
}

# The session id only ever comes from the hook. This is the end the user sees:
# a crash record they can hand straight to `claude --resume`.
@test "a crash carries the session id the hook recorded" {
  wg_sessions_record "$WG_SCOPE" "abc-123" "$WG_TMP/projects/shop-web" hook
  journal_kill "$WG_SCOPE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$(crashes)" -eq 1 ]
  [ "$(crash_field session)" = "abc-123" ]
}

# A session with no hook behind it -- started before the hook was installed --
# still gets a record, because which project was lost is most of the answer.
@test "a crash with no session id still names the directory" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_SCOPE"

  # --once scans before it reads the stream, which is the same order the
  # watcher runs in: the scope is known by the time its kill line arrives.
  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$(crashes)" -eq 1 ]
  [ "$(crash_field session)" = "" ]
  [ "$(crash_field cwd)" = "$WG_TMP/projects/shop-web" ]
}

# systemd logs the same failure more than once often enough, and a watcher
# restarted against a journal it has already seen would read it again.
@test "a repeated kill line for the same scope does not double-record" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_SCOPE"
  journal_kill "$WG_SCOPE" "2026-09-10T09:14:09+0200"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$(crashes)" -eq 1 ]
  # The first sighting is the kill; the second is systemd saying so again.
  [ "$(crash_field killed_at)" = "$WG_KILLED_AT" ]
}

# The record count above cannot see the cost of a repeat, which is why this
# test is about the refresh count instead. wg_crashed_add *succeeds* on a scope
# it has already filed -- the list is correct either way -- so a watcher that
# took its word for it would redraw the whole bar again for every line systemd
# repeated, and a redraw is a pkill plus a full waybar re-render for every slot.
# Three identical lines is not a contrived number: the scope logs its own
# failure, and oomd logs one per process it killed in that unit.
@test "repeated kill lines for one scope redraw the bar only once" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_SCOPE"
  journal_kill "$WG_SCOPE"
  journal_kill "$WG_SCOPE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(crashes)" -eq 1 ]
  [ "$(refreshes)" -eq 1 ]
}

# oomd kills whatever cgroup is biggest, which is usually the browser. Without
# this the crash list would be a log of everything the machine ever killed.
@test "a kill for a scope that was never a session is ignored" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_BROWSER_SCOPE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(crashes)" -eq 0 ]
}

# systemd reports the same failure for units that are not scopes at all, and
# there is no scope name to be had from those lines.
@test "a kill for a unit that is not a scope is ignored" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "dev-sda1.device"
  journal_kill "some-service.service"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(crashes)" -eq 0 ]
}

@test "--once scans the fake process table into the session map" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  wg_fake_proc 1002 claude "$WG_SCOPE_TWO" "$WG_TMP/projects/site-platform"
  wg_fake_proc 1003 brave "$WG_BROWSER_SCOPE" "$WG_TMP"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  local sessions
  sessions="$(wg_sessions_read)"
  [ "$(jq '.sessions | length' <<<"$sessions")" -eq 2 ]
  [ "$(jq -r --arg s "$WG_SCOPE" '.sessions[$s].cwd' <<<"$sessions")" = "$WG_TMP/projects/shop-web" ]
  [ "$(jq -r --arg s "$WG_SCOPE_TWO" '.sessions[$s].source' <<<"$sessions")" = "scan" ]
}

# Redrawing the bar is a signal to the user that something happened. A kill
# that changed nothing they can see must not send it.
@test "the bar is refreshed once, for the crash that was actually recorded" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_BROWSER_SCOPE"
  journal_says 'systemd[1443]: Started Brave.'
  journal_kill "$WG_SCOPE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$(refreshes)" -eq 1 ]
}

@test "a stream with nothing in it for us refreshes nothing" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_BROWSER_SCOPE"
  journal_says 'systemd[1443]: Started Brave.'

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$(refreshes)" -eq 0 ]
}

@test "an ordinary journal line is not mistaken for a kill" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_says "systemd[1443]: $WG_SCOPE: Consumed 4min 2s CPU time."
  journal_says "systemd[1443]: $WG_SCOPE: Deactivated successfully."

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$(crashes)" -eq 0 ]
  [ "$(refreshes)" -eq 0 ]
}

# The scope name is the join key, backslashes and all. Reading it back off the
# journal line as a field is what keeps it byte-identical to what the hook and
# the scan wrote; anything that unescaped it would match nothing.
@test "the scope is taken off the line intact" {
  wg_sessions_record "$WG_SCOPE" "abc-123" "$WG_TMP/projects/shop-web" hook
  journal_kill "$WG_SCOPE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  # Spelled out rather than compared against $WG_SCOPE: the bytes that came off
  # the journal line have to be the bytes systemd printed, backslashes included.
  [ "$(crash_field scope)" = 'app-Hyprland-xdg\x2dterminal\x2dexec-9029a872.scope' ]
}

@test "an unknown argument is refused rather than followed" {
  run "$WG_ROOT/bin/wingroup-oomwatch" --twice
  [ "$status" -eq 2 ]
}

# Started from Hyprland's autostart, which on a re-exec of the compositor runs
# the whole list again. Two followers would file every kill twice over.
@test "a second watcher refuses to start while one holds the lock" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  # Held by this shell rather than by a first watcher, so the test does not have
  # to wait for one to come up. The lock is on the open file, so the child's own
  # open of the same path is a different one and cannot take it.
  exec 8>"$XDG_RUNTIME_DIR/wingroup-oomwatch.lock"
  flock -n 8

  run "$WG_ROOT/bin/wingroup-oomwatch"
  exec 8>&-

  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  # It gave up before doing any of its work, scan included.
  [ "$(jq '.sessions | length' <<<"$(wg_sessions_read)")" -eq 0 ]
}

# The watcher is killed at logout with the rest of the session. journalctl -f
# notices we are gone only when it next tries to write, which on a quiet
# journal is hours away, so it has to be taken down deliberately -- otherwise
# every login leaves another follower behind.
@test "SIGTERM stops the watcher and takes the journal follower with it" {
  local watcher child i=0
  # A journal that behaves like the real one: it stays open until it is killed.
  mkfifo "$WG_TMP/fifo"
  printf '#!/usr/bin/env bash\nexec cat %q\n' "$WG_TMP/fifo" >"$WG_TMP/journal"

  "$WG_ROOT/bin/wingroup-oomwatch" &
  watcher=$!
  # Holds the writing end open, so the follower does not read EOF and exit on
  # its own -- which would prove nothing about the trap.
  exec 8>"$WG_TMP/fifo"
  # The follower itself, found by what it is reading rather than by being the
  # watcher's child: the bug this guards against is a journalctl left one
  # generation further down, where killing the watcher's own child misses it.
  while (( i++ < 50 )) && ! pgrep -f "cat $WG_TMP/fifo" >/dev/null; do sleep 0.1; done
  child="$(pgrep -f "cat $WG_TMP/fifo")"
  [ -n "$child" ]

  kill -TERM "$watcher"
  run wait "$watcher"
  [ "$status" -eq 0 ]

  i=0
  while (( i++ < 50 )) && kill -0 "$child" 2>/dev/null; do sleep 0.1; done
  run kill -0 "$child"
  [ "$status" -ne 0 ]
  exec 8>&-
}

# Every other test here drives --once, which scans, drains a finite stream and
# returns. The loop that runs at login does neither: it follows a stream that
# never ends, and rescans on a timer. The header comment's whole claim is that
# one loop can do both without either job starving the other, and until this
# test nothing checked the second job ran at all.
#
# So it runs the real thing. The session appears *after* startup, which is the
# case the periodic rescan exists for -- a terminal opened at any point during
# the login -- and only then does its kill line arrive, on the live follower,
# to be filed off the map that rescan built.
@test "the live loop rescans on its timer and files a kill off the follower" {
  local watcher
  # A journal that behaves like the real one: it stays open until it is killed,
  # so the loop keeps looping instead of falling out the bottom on EOF.
  mkfifo "$WG_TMP/fifo"
  printf '#!/usr/bin/env bash\nexec cat %q\n' "$WG_TMP/fifo" >"$WG_TMP/journal"
  # Also the read timeout, so it bounds both how long the rescan waits and how
  # long a line pushed into the fifo can sit unnoticed.
  export WG_SCAN_INTERVAL=1

  "$WG_ROOT/bin/wingroup-oomwatch" &
  watcher=$!
  # Read by teardown, so a failure below still takes the watcher down.
  WG_WATCHER_PID=$watcher
  exec 8>"$WG_TMP/fifo"

  # The follower being up means the startup scan has already finished: the
  # watcher scans before it opens the journal. Without that ordering the
  # process created next could be picked up by the startup scan, and the test
  # would prove nothing about the timer.
  wait_until follower_up
  [ "$(jq '.sessions | length' <<<"$(wg_sessions_read)")" -eq 0 ]

  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  wait_until scope_known "$WG_SCOPE"
  [ "$(jq -r --arg s "$WG_SCOPE" '.sessions[$s].cwd' <<<"$(wg_sessions_read)")" = "$WG_TMP/projects/shop-web" ]

  # Built by the same helper the --once tests use, so the bytes on the fifo are
  # the bytes those tests hand to the parser, then pushed down the live stream.
  journal_kill "$WG_SCOPE"
  cat "$WG_TMP/journal.txt" >&8

  wait_until bar_refreshed
  [ "$(crashes)" -eq 1 ]
  [ "$(crash_field scope)" = "$WG_SCOPE" ]
  [ "$(crash_field cwd)" = "$WG_TMP/projects/shop-web" ]
  [ "$(refreshes)" -eq 1 ]

  kill -TERM "$watcher"
  run wait "$watcher"
  [ "$status" -eq 0 ]
  exec 8>&-
}

# --- the snapshot ------------------------------------------------------------
#
# The map lives in the runtime directory and dies with the boot, which is right
# for everything else it is used for and useless to a restore. So every scan
# also writes it out to the state directory, stamped with the boot it describes.

# A snapshot as the watcher on some other boot left it behind.
wg_snapshot_from_boot() {
  local boot="$1" scope="$2" session="$3" cwd="$4"
  mkdir -p "$WG_STATE_DIR"
  jq -n --arg boot "$boot" --arg scope "$scope" --arg session "$session" --arg cwd "$cwd" \
     '{boot: $boot, sessions: {($scope): {session: $session, cwd: $cwd, source: "scan", seen: 0}}}' \
     >"$WG_SNAPSHOT_FILE"
}

# There is no shutdown hook to be had -- a machine can lose power, and a session
# oomd kills never says goodbye either -- so the snapshot is only ever as good
# as the last scan, and the last scan has to leave it correct.
@test "a scan writes the session map out to the snapshot, stamped with this boot" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  # And one the hook told us about, because the id is the half of the record a
  # restore actually resumes from.
  wg_sessions_record "$WG_SCOPE_TWO" "abc-123" "$WG_TMP/projects/site-platform" hook

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ -f "$WG_SNAPSHOT_FILE" ]
  [ "$(jq -r '.boot' "$WG_SNAPSHOT_FILE")" = "$WG_BOOT_NOW" ]
  [ "$(jq '.sessions | length' "$WG_SNAPSHOT_FILE")" -eq 2 ]
  [ "$(jq -r --arg s "$WG_SCOPE" '.sessions[$s].cwd' "$WG_SNAPSHOT_FILE")" = "$WG_TMP/projects/shop-web" ]
  [ "$(jq -r --arg s "$WG_SCOPE_TWO" '.sessions[$s].session' "$WG_SNAPSHOT_FILE")" = "abc-123" ]
}

# The ordering guard between the watcher and the restore, and the one thing in
# this file that loses every session on the machine if it breaks. Both start at
# login; if the watcher gets there first and simply overwrote the file, the
# record of what was open would be gone before the restore ever read it. So the
# first write of a new boot moves the old file aside instead, and the restore
# finds it either way.
@test "the first scan of a new boot keeps the previous boot's snapshot" {
  wg_snapshot_from_boot "$WG_BOOT_BEFORE" "$WG_SCOPE" "sess-1" "$WG_TMP/projects/shop-web"
  # This boot is running something else entirely.
  wg_fake_proc 1002 claude "$WG_SCOPE_TWO" "$WG_TMP/projects/site-platform"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(jq -r '.boot' "$WG_SNAPSHOT_PREV")" = "$WG_BOOT_BEFORE" ]
  [ "$(jq -r '.boot' "$WG_SNAPSHOT_FILE")" = "$WG_BOOT_NOW" ]

  # Every scan after the first is on a boot the snapshot already carries, so it
  # overwrites and moves nothing: pushing this boot's file onto .prev would
  # throw away the very record the move was made to protect.
  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(jq -r '.boot' "$WG_SNAPSHOT_PREV")" = "$WG_BOOT_BEFORE" ]

  # And what the restore will ask for is still the sessions from before the
  # reboot, not the one this boot is running.
  run wg_snapshot_previous_rows
  [ "$output" = "$(printf 'sess-1\t%s' "$WG_TMP/projects/shop-web")" ]
}
