# shellcheck shell=bash
# Requires lib/state.sh to be sourced first (for the corrupt-file handling this
# mirrors) and, for wg_crashed_group, lib/resolve.sh.
#
# Two runtime files, both keyed by systemd scope.
#
# Omarchy launches every terminal through uwsm/xdg-terminal-exec, which puts it
# in a scope of its own -- "app-Hyprland-xdg\x2dterminal\x2dexec-<hash>.scope".
# That name is the one thing a live Claude session and the journal record of its
# death have in common: /proc/<pid>/cgroup ends in it while the session runs,
# and systemd-oomd names it when it kills the thing. So the scope is the join
# key, and everything here is a map keyed by it.
#
# sessions.json is what is alive: scope -> the session running in it. It has to
# be written while the process is still up, because none of it can be recovered
# afterwards -- /proc is gone, and the journal's launch line records the
# directory the terminal was *opened* in, which is not where the session ended
# up. crashed.json is what died: one record per scope systemd-oomd killed.
#
# Both live under $XDG_RUNTIME_DIR and are meant to die at reboot: they describe
# processes, and after a reboot there are no processes to describe.
#
# The snapshot is the exception, and lives in the state directory because its
# whole job is to outlive the boot. It is the same map, written out after every
# scan, so that after a reboot there is an exact record of what was open --
# which session, in which directory -- instead of the guess a restore otherwise
# has to make from file timestamps.

: "${WG_RUNTIME_DIR:=${XDG_RUNTIME_DIR:-/tmp}/wingroup}"
WG_SESSIONS_FILE="$WG_RUNTIME_DIR/sessions.json"
WG_CRASHED_FILE="$WG_RUNTIME_DIR/crashed.json"
WG_RUNTIME_LOCK="$WG_RUNTIME_DIR/.runtime.lock"
: "${WG_RUNTIME_LOCK_WAIT:=5}"

# Where the process table is read from. A test points this at a fixture tree of
# <pid>/comm, <pid>/cgroup and <pid>/cwd instead of stubbing a function, so the
# code under test is the code that ships.
: "${WG_PROC_DIR:=/proc}"

# An entry no process has refreshed for this long is dropped by the next scan.
# It only has to outlive the gap between a session dying and the journal line
# about it being handled, which is immediate; six hours is slack, not a
# requirement, and the file is a few hundred bytes either way.
: "${WG_SESSIONS_TTL:=21600}"

# The snapshot, and the copy kept of the one the previous boot left behind.
# In the state directory, not the runtime one: everything else here is about
# processes that exist, and this is the one thing that has to survive them.
: "${WG_STATE_DIR:=$HOME/.local/state/omarchy/wingroup}"
WG_SNAPSHOT_FILE="$WG_STATE_DIR/sessions-snapshot.json"
WG_SNAPSHOT_PREV="$WG_STATE_DIR/sessions-snapshot.prev.json"

# Which boot we are on. The kernel makes a fresh one at every boot, so comparing
# it against the one stamped on a snapshot answers the only question a restore
# has: were these sessions open *before* this machine came up?
: "${WG_BOOT_ID_FILE:=/proc/sys/kernel/random/boot_id}"

wg_sessions_default() { printf '%s\n' '{"sessions":{}}'; }
wg_crashed_default()  { printf '%s\n' '{"crashed":[]}'; }

# Reads $1, replacing it with $2 (a default document) if it is missing or is not
# JSON. Same bargain wg_state_read strikes: a file we cannot parse is worse than
# no file, because every writer after it would build on garbage.
wg_runtime_read() {
  local file="$1" default="$2"
  mkdir -p "$WG_RUNTIME_DIR" 2>/dev/null || true
  if [[ ! -f $file ]]; then
    printf '%s\n' "$default"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    mv -f "$file" "$file.corrupt" 2>/dev/null || true
    printf '%s\n' "$default"
    return 0
  fi
  cat "$file"
}

# Read-modify-write of $1 under an exclusive lock, applying jq filter $3 with
# $2 as the fallback document. Anything after $3 goes to jq ahead of the filter.
#
# One lock file for both documents rather than one each: the writers are the
# watcher and the CLI, they write rarely, and a single lock cannot be taken in
# two orders and so cannot deadlock.
wg_runtime_update() {
  local file="$1" default="$2" filter="$3"; shift 3
  local fd doc updated tmp rc=0

  mkdir -p "$WG_RUNTIME_DIR" || return 1
  exec {fd}>>"$WG_RUNTIME_LOCK" || return 1
  if ! flock -w "$WG_RUNTIME_LOCK_WAIT" "$fd"; then
    printf 'wingroup: timed out waiting for %s; %s left unchanged\n' \
      "$WG_RUNTIME_LOCK" "$file" >&2
    exec {fd}>&-
    return 1
  fi

  doc="$(wg_runtime_read "$file" "$default")"
  if ! updated="$(jq "$@" "$filter" <<<"$doc")"; then
    exec {fd}>&-
    return 1
  fi
  # Written through a temporary and renamed, so a reader taking no lock -- the
  # bar, on every title change -- never sees a half-written document.
  if ! tmp="$(mktemp "$WG_RUNTIME_DIR/.rt.XXXXXX")"; then
    exec {fd}>&-
    return 1
  fi
  if printf '%s\n' "$updated" >"$tmp" && mv -f "$tmp" "$file"; then
    :
  else
    rm -f "$tmp"
    rc=1
  fi
  exec {fd}>&-
  return "$rc"
}

wg_sessions_read() { wg_runtime_read "$WG_SESSIONS_FILE" "$(wg_sessions_default)"; }
wg_crashed_read()  { wg_runtime_read "$WG_CRASHED_FILE" "$(wg_crashed_default)"; }

# The scope a pid is in: the last path segment of its cgroup line.
#
# The whole unit name is the key, not the hex tail of it. The journal prints the
# same string, escapes and all, so keying on it needs no parsing on either side
# and keeps working for a terminal launched into a scope of some other shape.
wg_proc_scope() {
  local pid="$1" line=""
  read -r line < "$WG_PROC_DIR/$pid/cgroup" 2>/dev/null || return 0
  line="${line##*/}"
  [[ $line == *.scope ]] || return 0
  printf '%s\n' "$line"
}

# Records the session running in $1. $2 is its id (empty when the caller cannot
# know it), $3 its directory, $4 how we found out -- "hook" or "scan".
#
# A scan must not blank the id a hook wrote: the hook is told the session id by
# Claude itself, and the scan has no way to work it out. So an empty id leaves
# whatever is already there alone, and "hook" wins the source field only when it
# actually supplies one.
wg_sessions_record() {
  local scope="$1" session="$2" cwd="$3" source="${4:-scan}" now
  [[ -n $scope ]] || return 0
  now="$(date +%s)"
  # Read the merge left to right: the empty defaults a brand-new entry needs,
  # then whatever is already recorded (so a hook's id survives a scan), then the
  # two facts every caller knows, then -- only for a caller that has an id --
  # the id and the source it came from.
  # shellcheck disable=SC2016  # these are jq variables, not shell ones
  wg_runtime_update "$WG_SESSIONS_FILE" "$(wg_sessions_default)" '
    .sessions[$scope] =
        {session: "", source: $source}
      + (.sessions[$scope] // {})
      + {cwd: $cwd, seen: ($now | tonumber)}
      + (if $session == "" then {} else {session: $session, source: $source} end)
  ' --arg scope "$scope" --arg session "$session" --arg cwd "$cwd" \
    --arg source "$source" --arg now "$now"
}

# Refreshes the map from every live claude process.
#
# Reads $WG_PROC_DIR directly rather than forking a ps: the pid list is a glob
# and each of the three facts is one builtin read, so a pass over a few hundred
# processes costs no processes at all. It runs every WG_SCAN_INTERVAL seconds,
# so paying a fork for it would be paying it forever.
#
# Sessions that were started before the hook was installed are the reason this
# exists at all: it cannot learn their session id, but it can still learn that
# *something* was running in that scope, and in which directory -- enough to
# tell you which project you lost.
wg_sessions_scan() {
  local dir pid comm scope cwd found=0
  for dir in "$WG_PROC_DIR"/[0-9]*; do
    [[ -d $dir ]] || continue
    pid="${dir##*/}"
    read -r comm < "$dir/comm" 2>/dev/null || continue
    [[ $comm == "claude" ]] || continue
    scope="$(wg_proc_scope "$pid")"
    [[ -n $scope ]] || continue
    cwd="$(readlink "$dir/cwd" 2>/dev/null)" || continue
    [[ -n $cwd ]] || continue
    wg_sessions_record "$scope" "" "$cwd" scan
    found=$(( found + 1 ))
  done
  wg_sessions_expire
  printf '%s\n' "$found"
}

# Drops entries nothing has refreshed for WG_SESSIONS_TTL seconds.
wg_sessions_expire() {
  local now
  now="$(date +%s)"
  # shellcheck disable=SC2016  # jq variables
  wg_runtime_update "$WG_SESSIONS_FILE" "$(wg_sessions_default)" '
    .sessions |= with_entries(select(
      (($now | tonumber) - (.value.seen // 0)) < ($ttl | tonumber)))
  ' --arg now "$now" --arg ttl "$WG_SESSIONS_TTL"
}

# Files a crash for scope $1, killed at $2 (an ISO timestamp from the journal).
#
# Only a scope we have a session for is recorded. Every app on the desktop gets
# a scope of its own, and oomd kills whichever cgroup is biggest -- the browser,
# most days. Filtering on the map is what keeps this a list of lost Claude
# sessions rather than a log of everything the machine has ever killed.
#
# Returns 1 when the scope is unknown, so a caller can tell "ignored" from
# "recorded" without re-reading the file.
wg_crashed_add() {
  local scope="$1" killed_at="$2" entry session cwd
  [[ -n $scope ]] || return 1
  entry="$(jq -c --arg s "$scope" '.sessions[$s] // empty' <<<"$(wg_sessions_read)")"
  [[ -n $entry ]] || return 1
  session="$(jq -r '.session // ""' <<<"$entry")"
  cwd="$(jq -r '.cwd // ""' <<<"$entry")"
  # shellcheck disable=SC2016  # jq variables
  wg_runtime_update "$WG_CRASHED_FILE" "$(wg_crashed_default)" '
    if any(.crashed[]; .scope == $scope) then .
    else .crashed += [{scope: $scope, session: $session, cwd: $cwd, killed_at: $at}]
    end
  ' --arg scope "$scope" --arg session "$session" --arg cwd "$cwd" --arg at "$killed_at"
}

# Empties the crash list by removing the file, not by writing an empty document.
#
# The bar reads this on every window-title change, and Claude's spinner glyph
# changes several times a second. "No file" is a test the bar can answer with a
# single [[ -f ]] and no processes at all; an empty document costs it a mkdir
# and a jq, forever, on a machine where nothing is wrong. Since the two states
# mean the same thing to every reader -- wg_runtime_read turns a missing file
# into the empty document -- the cheaper one is the one to leave behind.
#
# Still taken under the lock: a reader must never catch the file mid-removal.
wg_crashed_clear() {
  local fd
  mkdir -p "$WG_RUNTIME_DIR" || return 1
  exec {fd}>>"$WG_RUNTIME_LOCK" || return 1
  if ! flock -w "$WG_RUNTIME_LOCK_WAIT" "$fd"; then
    printf 'wingroup: timed out waiting for %s; %s left unchanged\n' \
      "$WG_RUNTIME_LOCK" "$WG_CRASHED_FILE" >&2
    exec {fd}>&-
    return 1
  fi
  rm -f "$WG_CRASHED_FILE"
  exec {fd}>&-
}

# One crash per line: session id, cwd, killed_at, tab separated.
#
# The scope stays in the file and out of the rows on purpose. It is the join key
# and the dedupe key, but it is also the one field full of backslashes -- @tsv
# escapes them, so a scope read back out of a row is not the string that was
# written, and would match nothing. Nothing downstream needs it: the bar counts
# and describes crashes, and the CLI relaunches the lot and clears the file.
wg_crashed_rows() {
  jq -r '.crashed[] | [.session, .cwd, .killed_at] | @tsv' <<<"$(wg_crashed_read)"
}

wg_boot_id() {
  local id=""
  read -r id < "$WG_BOOT_ID_FILE" 2>/dev/null || true
  printf '%s\n' "$id"
}

# Writes the live map out to the state directory, stamped with this boot.
#
# Called after every scan, so the file on disk is never more than one scan
# interval behind what is actually open. There is no shutdown hook to be had
# here -- a machine can lose power, and a session killed by oomd never gets to
# say goodbye either -- so "recent enough" is the whole design, and a scan
# interval of seconds makes it accurate enough to restore from.
#
# The first write of a new boot moves the file the previous boot left behind out
# of the way instead of overwriting it, because that file is exactly what a
# restore is about to want. Doing it here rather than in the restore removes the
# ordering problem between the two: whichever of them runs first, the previous
# boot's record survives -- as .prev if the watcher got there, and as the
# snapshot itself if it did not.
wg_snapshot_write() {
  local boot existing tmp
  boot="$(wg_boot_id)"
  [[ -n $boot ]] || return 0

  mkdir -p "$WG_STATE_DIR" || return 1
  if [[ -f $WG_SNAPSHOT_FILE ]]; then
    existing="$(jq -r '.boot // ""' "$WG_SNAPSHOT_FILE" 2>/dev/null || true)"
    if [[ $existing != "$boot" ]]; then
      mv -f "$WG_SNAPSHOT_FILE" "$WG_SNAPSHOT_PREV" 2>/dev/null || true
    fi
  fi

  tmp="$(mktemp "$WG_STATE_DIR/.snap.XXXXXX")" || return 1
  if jq --arg boot "$boot" '{boot: $boot, sessions: .sessions}' \
       <<<"$(wg_sessions_read)" >"$tmp" 2>/dev/null && mv -f "$tmp" "$WG_SNAPSHOT_FILE"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# The sessions that were open when this machine last went down, one per line:
# session id, cwd, tab separated. Empty when there is no such record.
#
# Both files are considered, and only a boot id that is not this one counts. A
# snapshot stamped with the current boot describes what is open *now*, which is
# the one thing a restore must not act on -- it would open a second terminal for
# every session already on screen.
#
# The main file is tried first, and the order is load-bearing. Which of the two
# holds the last boot's record depends on whether the watcher has written yet:
#
#   watcher first  snapshot = this boot, prev = last boot  -> prev is the answer
#   restore first  snapshot = last boot, prev = the boot before it
#
# In the second case .prev is a boot old and would restore a set of terminals
# that has been wrong for a whole session. Taking the main file when it is not
# this boot's, and only then falling back to .prev, is right in both orders --
# the current-boot test above is what makes trying it first safe.
#
# Returns 0 when a previous boot's record was found and 1 when there is none,
# and the distinction is the whole point: "the last boot recorded no open
# sessions" is an answer, and it is not the same answer as "there is no record".
# A caller that told them apart by counting rows would fall back to guessing
# every time you shut down with no sessions open -- and the guess reopens
# whatever was last written to, which is the behaviour this replaces.
wg_snapshot_previous_rows() {
  local file boot current
  current="$(wg_boot_id)"
  # No boot id, no comparison, and without one every stamped snapshot looks like
  # somebody else's -- including this boot's own, whose sessions are on screen
  # right now. Refusing to answer is the only safe way to be wrong here.
  [[ -n $current ]] || return 1
  for file in "$WG_SNAPSHOT_FILE" "$WG_SNAPSHOT_PREV"; do
    [[ -f $file ]] || continue
    boot="$(jq -r '.boot // ""' "$file" 2>/dev/null || true)"
    [[ -n $boot && $boot != "$current" ]] || continue
    jq -r '.sessions | to_entries[]
           | select((.value.cwd // "") != "")
           | [.value.session // "", .value.cwd] | @tsv' "$file" 2>/dev/null || true
    return 0
  done
  return 1
}

# The group a crashed session's directory belongs to, resolved the same way a
# live window's is -- through the project the directory sits in, and the group
# that owns that project. Needs WG_STATE_MAP loaded by wg_state_map_load.
#
# Resolved at display time rather than stored on the record: a project can be
# moved between groups while a crash is still sitting unread, and the answer
# that matters is the one that is true when you look at the bar.
wg_crashed_group() {
  local cwd="$1" project
  project="$(wg_cwd_project "$cwd")"
  [[ -n $project ]] || return 0
  printf '%s\n' "${WG_STATE_MAP[p:$project]:-}"
}
