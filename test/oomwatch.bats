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

# Waits for the backgrounded watcher $1 to finish and asserts it stopped
# cleanly, tolerating one thing and one thing only: bash having already reaped
# it, which `wait` reports as 127.
#
# `run wait "$pid"` on its own is racy here -- measured at roughly one run in
# ten -- because whether the job is still in the table when bats gets to it
# depends on timing this test does not control. Tolerating 127 costs nothing:
# a trap that did not run leaves 143, and that still fails.
wg_assert_stopped_cleanly() {
  local pid="$1" rc=0
  wait "$pid" 2>/dev/null || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ]; then
    echo "watcher exited $rc, wanted a clean 0 (127 would mean already reaped)" >&2
    return 1
  fi
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
  wg_assert_stopped_cleanly "$watcher"

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
  wg_assert_stopped_cleanly "$watcher"
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
  # reboot, not the one this boot is running. Three columns now: the workspace
  # the session was on rides along so the restore can put it back there, and is
  # empty when no compositor answered for it.
  run wg_snapshot_previous_rows
  [[ "$output" == "$(printf 'sess-1\t%s' "$WG_TMP/projects/shop-web")"* ]]
  [ "$(printf '%s' "$output" | awk -F'\t' '{print NF}')" -eq 3 ]
}

# --- telling the user --------------------------------------------------------
#
# A red bar is only a signal to somebody looking at the bar. The crash this was
# written for happened at 23:58 and was read the next morning, off a button
# that had been red all night.

notifies() {
  wc -l <"$WG_NOTIFY_LOG"
}

# Column $2 of notification $1, both counted from one: 1 summary, 2 body,
# 3 urgency. The stub writes one tab-separated line per notification and
# nothing here puts a newline in a field, so a line is a notification.
notify_field() {
  sed -n "${1}p" "$WG_NOTIFY_LOG" | cut -f"$2"
}

notified()       { (( $(notifies) >= 1 )); }
notified_twice() { (( $(notifies) >= 2 )); }

@test "a filed crash sends exactly one notification, and it is critical" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_SCOPE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(notifies)" -eq 1 ]
  # A normal notification expires after a few seconds. The whole point of this
  # one is that it is still there when the user comes back to the machine.
  [ "$(notify_field 1 3)" = "critical" ]
}

# The scope is the join key and nothing else. Reading
# "app-Hyprland-xdg\x2dterminal\x2dexec-9029a872.scope" off a lock screen tells
# you nothing about what you just lost.
@test "the notification names the directory that was lost, not the scope" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_SCOPE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [[ "$(notify_field 1 1)" == *"shop-web"* ]]
  [[ "$(notify_field 1 1)" != *".scope"* ]]
  [[ "$(notify_field 1 1)" != *"x2dterminal"* ]]
  # And the full path in the body, because two projects can share a last
  # segment and the summary only carries that segment.
  [[ "$(notify_field 1 2)" == *"$WG_TMP/projects/shop-web"* ]]
}

# Whether the conversation comes back or only the directory does is what the
# user is deciding when they read this, so it is said in the same words the bar
# tooltip and the picker use.
@test "the notification says resumable when the hook recorded an id" {
  wg_sessions_record "$WG_SCOPE" "abc-123" "$WG_TMP/projects/shop-web" hook
  journal_kill "$WG_SCOPE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [[ "$(notify_field 1 2)" == *"resumable"* ]]
  [[ "$(notify_field 1 2)" != *"fresh claude"* ]]
}

@test "the notification says a fresh claude when no id was ever recorded" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_SCOPE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [[ "$(notify_field 1 2)" == *"no session id, a fresh claude"* ]]
}

# Knowing is no use without knowing what to do next, and the two ways back in
# are the bar's button and the CLI behind it.
@test "the notification says how to bring the session back" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_SCOPE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [[ "$(notify_field 1 2)" == *"⚠"* ]]
  [[ "$(notify_field 1 2)" == *"wingroup crashed --restore"* ]]
}

# Same guard as the bar redraw, for a worse reason: a redraw repeated is wasted
# work, but a critical notification repeated is another popup the user has to
# dismiss by hand for a session that only died once.
@test "a repeated kill line for a scope already filed notifies only once" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_SCOPE"
  journal_kill "$WG_SCOPE"
  journal_kill "$WG_SCOPE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(crashes)" -eq 1 ]
  [ "$(notifies)" -eq 1 ]
}

# The browser is what oomd kills most days, and the user needs no telling:
# they were watching it happen.
@test "a kill for a scope that was never a session notifies nothing" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_BROWSER_SCOPE"
  journal_kill "dev-sda1.device"
  journal_says 'systemd[1443]: Started Brave.'

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(notifies)" -eq 0 ]
}

# oomd frees what it can and then looks again, so a bad minute takes several
# sessions. One notification each, because the alternative -- announce the
# first and stay quiet after it -- names one project and lets the user believe
# nothing else died. The running total is what stops any single one of them
# being read as the whole story.
@test "two sessions killed at once get one notification each, with the total" {
  wg_sessions_record "$WG_SCOPE" "abc-123" "$WG_TMP/projects/shop-web" hook
  wg_fake_proc 1002 claude "$WG_SCOPE_TWO" "$WG_TMP/projects/site-platform"
  journal_kill "$WG_SCOPE"
  journal_kill "$WG_SCOPE_TWO"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(crashes)" -eq 2 ]
  [ "$(notifies)" -eq 2 ]
  # Each names its own project, and each is accurate about that one.
  [[ "$(notify_field 1 1)" == *"shop-web"* ]]
  [[ "$(notify_field 1 2)" == *"resumable"* ]]
  [[ "$(notify_field 2 1)" == *"site-platform"* ]]
  [[ "$(notify_field 2 2)" == *"no session id, a fresh claude"* ]]
  # The first could not have known what was coming; the second says how many
  # are waiting on the button by then.
  [[ "$(notify_field 1 2)" != *"crashed sessions are waiting"* ]]
  [[ "$(notify_field 2 2)" == *"2 crashed sessions are waiting"* ]]
}

# The one that matters. There may be no notification daemon at all -- least of
# all at login, which is exactly when the watcher starts -- and a watcher that
# died of trying to say something would file no crash for the rest of the day.
@test "a notifier that fails does not stop the crash being recorded" {
  export WG_NOTIFY_CMD="$WG_TMP/failing-notifier"
  # It logs before it fails, so this test cannot pass against a watcher that
  # never notifies -- which is what it did before: it asserted only the crash
  # count, and stayed green with the whole feature deleted.
  printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\t%%s\\n" "$1" "$2" "$3" >>"$WG_NOTIFY_LOG"\nexit 1\n' >"$WG_NOTIFY_CMD"
  chmod +x "$WG_NOTIFY_CMD"
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  wg_fake_proc 1002 claude "$WG_SCOPE_TWO" "$WG_TMP/projects/site-platform"
  journal_kill "$WG_SCOPE"
  journal_kill "$WG_SCOPE_TWO"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  # Both of them: the watcher did not merely survive the first failure, it went
  # on reading the stream afterwards.
  [ "$(crashes)" -eq 2 ]
  [ "$(refreshes)" -eq 2 ]
  # and it really was asked to notify, twice, and failed twice
  [ "$(notifies)" -eq 2 ]
}

@test "a notifier that is not there at all does not stop the crash being recorded" {
  # A path with nothing on it, rather than unsetting WG_NOTIFY_CMD: unset, this
  # would fall through to the machine's real notify-send and put a test's
  # notification on the user's own desktop.
  export WG_NOTIFY_CMD="$WG_TMP/no-such-notifier"
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  journal_kill "$WG_SCOPE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(crashes)" -eq 1 ]
  [ "$(refreshes)" -eq 1 ]
}

# The live loop is where the watcher spends its life, and it is the process
# that has to be still running hours later. --once cannot show that: it exits
# either way.
@test "the live loop notifies off the follower and keeps running afterwards" {
  local watcher
  mkfifo "$WG_TMP/fifo"
  printf '#!/usr/bin/env bash\nexec cat %q\n' "$WG_TMP/fifo" >"$WG_TMP/journal"
  export WG_SCAN_INTERVAL=1

  "$WG_ROOT/bin/wingroup-oomwatch" &
  watcher=$!
  # Read by teardown, so a failure below still takes the watcher down.
  WG_WATCHER_PID=$watcher
  exec 8>"$WG_TMP/fifo"

  wait_until follower_up
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  wait_until scope_known "$WG_SCOPE"

  journal_kill "$WG_SCOPE"
  cat "$WG_TMP/journal.txt" >&8
  wait_until notified
  [[ "$(notify_field 1 1)" == *"shop-web"* ]]
  [ "$(notify_field 1 3)" = "critical" ]

  # Still there and still reading, which is the half of this that --once cannot
  # test: a second session dies later in the same login.
  wg_fake_proc 1002 claude "$WG_SCOPE_TWO" "$WG_TMP/projects/site-platform"
  wait_until scope_known "$WG_SCOPE_TWO"
  : >"$WG_TMP/journal.txt"
  journal_kill "$WG_SCOPE_TWO"
  cat "$WG_TMP/journal.txt" >&8
  wait_until notified_twice
  [[ "$(notify_field 2 1)" == *"site-platform"* ]]

  kill -TERM "$watcher"
  wg_assert_stopped_cleanly "$watcher"
  exec 8>&-
}

# The failure mode that is worse than not notifying at all.
#
# wg_notify swallows a non-zero exit, but an exit status says nothing about a
# notifier that never returns -- and notify-send is a blocking dbus call. The
# watcher runs it in the one loop that also reads the journal and rescans
# /proc, so a stuck call stops all three at once: every later kill is missed
# for good (the journal is followed with -n0, so nothing re-reads it), the
# snapshot a restore needs stops being written, and SIGTERM is deferred so
# logout leaks the follower.
#
# The realistic version is not a notifier that hangs forever but a daemon that
# has stopped answering its bus name, which costs GDBus' 25 second timeout per
# notification -- at the exact moment the machine is out of memory and that
# daemon is most likely to be swapped out.
@test "a notifier that hangs does not stop the watcher reading the journal" {
  export WG_NOTIFY_CMD="$WG_TMP/hanging-notifier"
  printf '#!/usr/bin/env bash\nexec sleep 600\n' >"$WG_NOTIFY_CMD"
  chmod +x "$WG_NOTIFY_CMD"
  # Short enough to keep the suite quick; the point is that it is bounded at all.
  export WG_NOTIFY_TIMEOUT=1
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  wg_fake_proc 1002 claude "$WG_SCOPE_TWO" "$WG_TMP/projects/site-platform"
  journal_kill "$WG_SCOPE"
  journal_kill "$WG_SCOPE_TWO"

  # timeout, not patience: an unbounded notify call is exactly what this pins,
  # so the test has to fail by giving up rather than by hanging the suite.
  run timeout 20 "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -ne 124 ]
  [ "$status" -eq 0 ]
  # The second kill is the one that proves it: the watcher came back from the
  # first stuck notification and went on reading.
  [ "$(crashes)" -eq 2 ]
}

# What was open, not what has been open.
#
# The map deliberately keeps an entry for WG_SESSIONS_TTL -- six hours -- after
# its process is gone, so that a kill can still be matched to a session. Writing
# that whole history into the snapshot is what made a restore open sessions
# twice. Measured on the snapshot that drove one real reboot: fifteen entries
# the last scan had seen, and nine between three and six hours stale.
@test "the snapshot leaves out sessions the last scan did not see" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  # A scope whose process died hours ago: still in the map, not open any more.
  wg_sessions_record "$WG_SCOPE_TWO" "long-gone" "$WG_TMP/projects/site-platform" hook
  local stale=$(( $(date +%s) - 4000 ))
  jq --arg s "$WG_SCOPE_TWO" --arg t "$stale" \
     '.sessions[$s].seen = ($t | tonumber)' "$WG_SESSIONS_FILE" >"$WG_TMP/patched"
  mv -f "$WG_TMP/patched" "$WG_SESSIONS_FILE"

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(jq '.sessions | length' "$WG_SNAPSHOT_FILE")" -eq 1 ]
  [ "$(jq -r --arg s "$WG_SCOPE_TWO" '.sessions | has($s)' "$WG_SNAPSHOT_FILE")" = "false" ]
  # and the map itself still remembers it, because a crash still has to match
  [ "$(jq -r --arg s "$WG_SCOPE_TWO" '.sessions | has($s)' "$WG_SESSIONS_FILE")" = "true" ]
}

# Resuming a session gives it a new terminal and a new scope, and the old entry
# lingers until the TTL. Both carry the same conversation, so a snapshot holding
# both opens it twice -- which is exactly what happened: two conversations came
# back as four terminals.
@test "one conversation under two scopes is one entry in the snapshot" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  wg_fake_proc 1002 claude "$WG_SCOPE_TWO" "$WG_TMP/projects/shop-web"
  wg_sessions_record "$WG_SCOPE" "same-session" "$WG_TMP/projects/shop-web" hook
  wg_sessions_record "$WG_SCOPE_TWO" "same-session" "$WG_TMP/projects/shop-web" hook

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(jq '.sessions | length' "$WG_SNAPSHOT_FILE")" -eq 1 ]
  [ "$(jq -r '.sessions | to_entries[0].value.session' "$WG_SNAPSHOT_FILE")" = "same-session" ]
}

# A restore hands a session back by opening a terminal, so a session that was
# not in one has no business in the snapshot. Claude in the browser and Claude
# inside another app both report no controlling terminal; on the reboot that
# prompted this, three browser sessions were restored as terminals.
@test "a session with no controlling terminal is left out of the snapshot" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  wg_fake_proc 1002 claude "$WG_SCOPE_TWO" "$WG_TMP/projects/in-a-browser" 0

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(jq '.sessions | length' "$WG_SNAPSHOT_FILE")" -eq 1 ]
  [ "$(jq -r --arg s "$WG_SCOPE" '.sessions | has($s)' "$WG_SNAPSHOT_FILE")" = "true" ]
  [ "$(jq -r --arg s "$WG_SCOPE_TWO" '.sessions | has($s)' "$WG_SNAPSHOT_FILE")" = "false" ]
}

# A session the hook has recorded but no scan has classified yet has no tty
# field at all. Dropping it would lose a session over a field that is merely
# late; keeping it costs at worst one spare window.
@test "a session no scan has classified yet is kept in the snapshot" {
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  wg_sessions_record "$WG_SCOPE_TWO" "just-hooked" "$WG_TMP/projects/site-platform" hook

  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(jq -r --arg s "$WG_SCOPE_TWO" '.sessions[$s].session' "$WG_SNAPSHOT_FILE")" = "just-hooked" ]
}

# The regression that lost a whole desktop.
#
# At shutdown Hyprland kills the terminals first and the watcher gets one more
# scan. Once the snapshot held only live sessions, that scan wrote "nothing is
# open" over the record the next boot was about to restore from. Observed: a
# snapshot written at 20:38:21 with zero sessions, nine seconds before the boot
# ended, after a session with fourteen terminals open. The restore obeyed it and
# opened nothing.
#
# An empty answer now has to hold still before it is believed.
@test "the last scan before shutdown does not wipe the snapshot" {
  export WG_SNAPSHOT_FRESH=1
  export WG_SNAPSHOT_EMPTY_GRACE=30
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  wg_sessions_record "$WG_SCOPE" "sess-a" "$WG_TMP/projects/shop-web" hook
  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$(jq '.sessions | length' "$WG_SNAPSHOT_FILE")" -eq 1 ]

  # The terminals are gone and the entry has aged past the freshness window,
  # which is exactly the state the dying machine is in.
  rm -rf "${WG_PROC_DIR:?}/1001"
  sleep 2
  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(jq '.sessions | length' "$WG_SNAPSHOT_FILE")" -eq 1 ]
  # and it has started counting, so the wait survives the watcher restarting
  [ "$(jq -r '.empty_since // "unset"' "$WG_SNAPSHOT_FILE")" != "unset" ]
}

# The half that makes the guard worth having: a reboot landing in the middle of
# the wait still hands the restore a record of what was open.
@test "a reboot during the wait still archives the sessions" {
  export WG_SNAPSHOT_FRESH=1
  export WG_SNAPSHOT_EMPTY_GRACE=30
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  wg_sessions_record "$WG_SCOPE" "sess-a" "$WG_TMP/projects/shop-web" hook
  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  rm -rf "${WG_PROC_DIR:?}/1001"
  sleep 2
  run "$WG_ROOT/bin/wingroup-oomwatch" --once

  printf 'a-brand-new-boot\n' >"$WG_BOOT_ID_FILE"
  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$status" -eq 0 ]
  [ "$(jq '.sessions | length' "$WG_SNAPSHOT_PREV")" -eq 1 ]
  [ "$(jq -r '.sessions | to_entries[0].value.session' "$WG_SNAPSHOT_PREV")" = "sess-a" ]
}

# And the guard must not become a permanent refusal to empty: a user who really
# has closed everything and carried on working gets an empty snapshot, so the
# next boot opens nothing rather than resurrecting what they shut.
@test "closing everything does empty the snapshot once the wait is over" {
  export WG_SNAPSHOT_FRESH=1
  export WG_SNAPSHOT_EMPTY_GRACE=2
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  wg_sessions_record "$WG_SCOPE" "sess-a" "$WG_TMP/projects/shop-web" hook
  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  rm -rf "${WG_PROC_DIR:?}/1001"
  sleep 2
  run "$WG_ROOT/bin/wingroup-oomwatch" --once   # starts the wait, keeps the record
  sleep 3
  run "$WG_ROOT/bin/wingroup-oomwatch" --once   # wait is over
  [ "$status" -eq 0 ]
  [ "$(jq '.sessions | length' "$WG_SNAPSHOT_FILE")" -eq 0 ]
}

# A session appearing again cancels the wait outright, rather than leaving a
# stale stamp that would empty the snapshot the moment it expired.
@test "a session coming back clears the pending wait" {
  export WG_SNAPSHOT_FRESH=1
  export WG_SNAPSHOT_EMPTY_GRACE=30
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web"
  wg_sessions_record "$WG_SCOPE" "sess-a" "$WG_TMP/projects/shop-web" hook
  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  rm -rf "${WG_PROC_DIR:?}/1001"
  sleep 2
  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$(jq -r '.empty_since // "unset"' "$WG_SNAPSHOT_FILE")" != "unset" ]

  wg_fake_proc 1002 claude "$WG_SCOPE_TWO" "$WG_TMP/projects/site-platform"
  run "$WG_ROOT/bin/wingroup-oomwatch" --once
  [ "$(jq '.sessions | length' "$WG_SNAPSHOT_FILE")" -eq 1 ]
  [ "$(jq -r '.empty_since // "unset"' "$WG_SNAPSHOT_FILE")" = "unset" ]
}
