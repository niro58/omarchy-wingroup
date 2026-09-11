# shellcheck shell=bash
# Telling the user something when there may be no terminal to tell them in.
#
# Lives in lib/ rather than in bin/wingroup because the watcher needs it too,
# and the watcher is the one place that never has a terminal: it is started by
# Hyprland's autostart and runs for the whole session. Anything it prints goes
# to a journal nobody is reading.

# Sends a desktop notification. $1 summary, $2 body, $3 urgency (low, normal or
# critical -- default normal).
#
# Critical is not decoration. A notification daemon expires a normal one after a
# few seconds; a critical one stays until it is dismissed. A session dying at
# 23:58 while you are looking at something else is exactly the case where a
# notification that has already faded is the same as no notification at all.
#
# Every failure is swallowed, and every call is bounded. There may be no
# notification daemon, or none yet at login, and neither is a reason to take
# down the caller -- least of all the watcher, whose job is to still be running
# hours later.
#
# The timeout is the half that is easy to leave out, and leaving it out is worse
# than not notifying at all. `|| true` guards the exit status; it has no answer
# for a notifier that never exits, and notify-send is a blocking D-Bus call. The
# watcher runs it in the single loop that also reads the journal and rescans
# /proc, so one stuck call stops all three: every later kill is missed for good
# (the journal is followed with -n0, so nothing re-reads it), the snapshot a
# restore needs stops being written, and SIGTERM is deferred until the call
# returns, so logout leaks the journal follower.
#
# Not hypothetical. GDBus' default method timeout is 25 seconds, so a daemon
# that has stopped servicing its bus name costs 25 seconds of deafness per
# notification -- and the moment this fires is the moment the machine is out of
# memory, which is exactly when that daemon is swapped out. Four kills in two
# minutes, which is the burst this feature was written from, would be a hundred
# seconds of a watcher that is recording nothing.
#
# Bounding rather than detaching, because `timeout` is what the rest of this
# repo already does with a wait that could hang (flock -w). The cost is that
# SIGTERM can still be up to WG_NOTIFY_TIMEOUT late.
: "${WG_NOTIFY_TIMEOUT:=5}"

wg_notify() {
  local summary="$1" body="${2:-}" urgency="${3:-normal}"
  if [[ -n ${WG_NOTIFY_CMD:-} ]]; then
    timeout "$WG_NOTIFY_TIMEOUT" "$WG_NOTIFY_CMD" "$summary" "$body" "$urgency" || true
    return 0
  fi
  command -v notify-send >/dev/null 2>&1 || return 0
  timeout "$WG_NOTIFY_TIMEOUT" notify-send -u "$urgency" -a wingroup "$summary" "$body" || true
}
