# shellcheck shell=bash
# Putting a terminal back on the workspace its session was on.
#
# Requires lib/hypr.sh for the dispatch and the client query, and reads the
# process table from $WG_PROC_DIR, which lib/sessions.sh defines.
#
# Two callers, one rule. bin/wingroup-restore brings back everything that was
# open at the last shutdown; bin/wingroup relaunches the sessions systemd-oomd
# killed. Both end with a handful of terminals that have just appeared and a
# record of where each of them used to be, and "where it used to be" is the one
# thing the daemon's filing by project cannot work out: a session in a project
# no group claims sits somewhere all the same, and a session the user
# deliberately moved is not where its project says it should be.

# lib/sessions.sh sets the same default, and both shipping callers source it.
# Repeated here because this file reads the process table itself: sourced
# without it, `set -u` would abort on the glob rather than fall back to /proc,
# and a library should stand up on its own dependencies.
: "${WG_PROC_DIR:=/proc}"

# One row, peeled into the three facts it carries: session id, directory,
# workspace. The workspace is empty for a session no compositor answered for
# when the record was written.
#
# By parameter expansion, never `IFS=$'\t' read -r session cwd workspace`: the
# session id is empty for anything that predates the hook, tab is IFS
# whitespace, and read collapses a leading run of it -- so the directory would
# land in $session and every column after it would shift too. Exactly the trap
# wg_row_split exists for.
WG_PLACE_SESSION=""
WG_PLACE_CWD=""
WG_PLACE_WORKSPACE=""

wg_place_row_split() {
  local row="$1" rest
  WG_PLACE_SESSION="${row%%$'\t'*}"
  rest="${row#*$'\t'}"
  WG_PLACE_CWD="${rest%%$'\t'*}"
  # Only when a third column was actually there: ${rest#*<tab>} on a row without
  # one hands back the directory again, and a directory is not a workspace.
  WG_PLACE_WORKSPACE=""
  [[ $rest == *$'\t'* ]] && WG_PLACE_WORKSPACE="${rest#*$'\t'}"
  return 0
}

# The pids of every process's children, keyed by the parent's pid, from a
# single pass over the process table.
#
# A terminal has exactly one child, but the pass is a glob and a read per
# process and answers for every window at once, where asking per window would
# be a pgrep each -- a full walk of the table per terminal.
declare -A WG_PLACE_KIDS=()

wg_place_children() {
  local dir pid line rest ppid
  WG_PLACE_KIDS=()
  for dir in "$WG_PROC_DIR"/[0-9]*; do
    [[ -d $dir ]] || continue
    pid="${dir##*/}"
    read -r line < "$dir/stat" 2>/dev/null || continue
    # /proc/<pid>/stat is "<pid> (<comm>) <state> <ppid> ...", and comm can hold
    # spaces and parentheses of its own -- so cut at the last ") " rather than
    # counting words from the front.
    rest="${line##*) }"
    rest="${rest#* }"
    ppid="${rest%% *}"
    [[ -n $ppid ]] || continue
    # Read back unquoted and word split, so the leading space the first append
    # leaves on a parent costs nothing.
    WG_PLACE_KIDS[$ppid]+=" $pid"
  done
}

# How long to wait for a relaunched terminal's window to exist before placing
# it, and how often to look.
: "${WG_PLACE_WAIT:=5}"
: "${WG_PLACE_POLL:=0.2}"

# Waits until every session id in $@ can be found in a window's child shell, or
# until WG_PLACE_WAIT seconds have passed. Always returns 0: a session that
# never appears is one wg_place_rows will simply not match.
#
# This exists because "the launcher took" and "the window is there" are
# different events, and only the first one has been waited for. wg_crash_settle
# gives a launch 0.4s -- enough to tell a launcher that died from one that
# became a terminal, nowhere near enough for that terminal to map a window and
# fork the shell the session id lives on. Placing at that moment mostly matches
# nothing, and says nothing when it doesn't.
#
# Worse on a crash restore than at login, because the daemon is running: it
# files a new window by project within about a second, with the *non-silent*
# dispatch. Place too early and the daemon's move lands afterwards and undoes
# it -- yanking the view along with it. Waiting for the window means the
# placement is the last word, which is what the boot restore already arranges
# for itself by placing after its own settle and after tidy.
wg_place_wait() {
  local id found waited=0
  local -a args=()
  (( $# )) || return 0
  while :; do
    wg_place_children
    found=1
    for id in "$@"; do
      [[ -n $id ]] || continue
      if ! wg_place_seen "$id"; then found=0; break; fi
    done
    (( ! found )) || return 0
    # Bounded, and deliberately not fatal: a terminal that never opens is a
    # launch that failed, which the caller has already reported on.
    awk -v w="$waited" -v p="$WG_PLACE_POLL" -v m="$WG_PLACE_WAIT" \
      'BEGIN { exit !(w + p <= m) }' || return 0
    sleep "$WG_PLACE_POLL"
    waited="$(awk -v w="$waited" -v p="$WG_PLACE_POLL" 'BEGIN { print w + p }')"
  done
}

# True when session id $1 appears in the command line of some window's child.
wg_place_seen() {
  local id="$1" pid kid
  local -a args=()
  while IFS=$'\t' read -r pid; do
    [[ -n $pid ]] || continue
    for kid in ${WG_PLACE_KIDS[$pid]:-}; do
      mapfile -d '' -t args < "$WG_PROC_DIR/$kid/cmdline" 2>/dev/null || continue
      for arg in ${args[@]+"${args[@]}"}; do
        [[ $arg == "$id" ]] && return 0
      done
    done
  done < <(wg_hypr_query clients 2>/dev/null \
           | jq -r '.[] | select(.pid != null) | (.pid | tostring)' 2>/dev/null)
  return 1
}

# Puts each freshly opened terminal back on the workspace its session was
# recorded on. $1 is a dry run flag, $2 the rows.
#
# Matching a new window to the session it is showing goes through the command
# line the relaunch used: the terminal runs `bash -c '...' <session id>`, so the
# id is one of the arguments of the window's child shell. Nothing else would do
# -- the address is new at every launch, and the title belongs to Claude.
#
# A row with no workspace is left exactly as it is. No compositor answered for
# that session when the record was written, so there is nothing to put it back
# to, and filing by project is the right fallback.
wg_place_rows() {
  local dry="$1" rows="$2" row addr pid ws want dir kid arg kidcwd
  local -a args=()
  local -A ws_by_id=() dir_by_id=() ws_by_dir=()
  [[ -n $rows ]] || return 0
  while IFS= read -r row; do
    wg_place_row_split "$row"
    [[ -n $WG_PLACE_CWD && -n $WG_PLACE_WORKSPACE ]] || continue
    # A scratchpad is not an arrangement. Hyprland reports those workspaces as
    # "special:<name>" -- Omarchy ships special:magic as the default -- and
    # "movetoworkspacesilent name:special:magic" does not mean what it looks
    # like: it makes an ordinary workspace whose name happens to be
    # "special:magic" and leaves the terminal somewhere the user can only reach
    # by typing that. A session that was tucked away on the scratchpad is left
    # to be filed by project, which is the sane place for it to land.
    [[ $WG_PLACE_WORKSPACE != special:* ]] || continue
    if [[ -n $WG_PLACE_SESSION ]]; then
      ws_by_id[$WG_PLACE_SESSION]="$WG_PLACE_WORKSPACE"
      dir_by_id[$WG_PLACE_SESSION]="$WG_PLACE_CWD"
    else
      # Weaker, and only for a row that has nothing better: a session from
      # before the hook has no id to match on, so the directory is all there is.
      #
      # Be honest about how blunt that is. It matches *any* window whose shell
      # sits in that directory -- not only a session this run launched, but a
      # terminal the user opened there by hand, and one that was never in the
      # record at all. Two such rows for one directory keep only the last, so
      # one of the two arrangements is silently lost.
      #
      # Kept anyway, because the alternative is leaving a pre-hook session
      # wherever it happens to land, and these rows disappear on their own as
      # sessions are restarted under the hook.
      ws_by_dir[$WG_PLACE_CWD]="$WG_PLACE_WORKSPACE"
    fi
  done <<<"$rows"
  (( ${#ws_by_id[@]} + ${#ws_by_dir[@]} )) || return 0

  wg_place_children
  # The workspace name is the only column that can be empty, and it is last, so
  # nothing can shift into it: an address and a pid are what makes a window a
  # window, and jq drops any client without them.
  while IFS=$'\t' read -r addr pid ws; do
    [[ -n $addr && -n $pid ]] || continue
    want=""
    dir=""
    for kid in ${WG_PLACE_KIDS[$pid]:-}; do
      # cmdline is NUL separated; mapfile -d '' gives one argument per element
      # and forks nothing.
      mapfile -d '' -t args < "$WG_PROC_DIR/$kid/cmdline" 2>/dev/null || continue
      for arg in ${args[@]+"${args[@]}"}; do
        [[ -n ${ws_by_id[$arg]:-} ]] || continue
        want="${ws_by_id[$arg]}"
        dir="${dir_by_id[$arg]}"
        break
      done
      [[ -z $want ]] || break
      kidcwd="$(readlink "$WG_PROC_DIR/$kid/cwd" 2>/dev/null)" || kidcwd=""
      if [[ -n $kidcwd && -n ${ws_by_dir[$kidcwd]:-} ]]; then
        want="${ws_by_dir[$kidcwd]}"
        dir="$kidcwd"
        break
      fi
    done
    # Some window that was already open, or one whose session was never
    # recorded. Not this run's to move.
    [[ -n $want ]] || continue
    # Already where it belongs. Dispatching anyway would be a no-op to the
    # compositor and a lie to anyone reading the output.
    [[ $want != "$ws" ]] || continue
    printf 'place  %s  %s\n' "$dir" "$want"
    (( ! dry )) || continue
    # Silently, for the same reason a login restore holds WG_RESTORE_FLAG: a
    # placement pass must not drag the desktop from workspace to workspace
    # while the user is watching.
    wg_hypr_dispatch movetoworkspacesilent "name:$want,address:$addr"
  done < <(wg_hypr_query clients 2>/dev/null \
           | jq -r '.[] | select(.pid != null and .address != null)
                    | [.address, (.pid | tostring), (.workspace.name // "")] | @tsv' 2>/dev/null)
}
