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

# One row, peeled into the facts it carries: session id, directory, workspace,
# the tile's x and y, and the monitor. Rows from a crash carry only the first
# three, and anything recorded before positions were carries empty ones.
#
# By parameter expansion, never `IFS=$'\t' read -r session cwd workspace ...`:
# the session id is empty for anything that predates the hook, tab is IFS
# whitespace, and read collapses a run of it -- so the directory would land in
# $session and every column after it would shift too. Exactly the trap
# wg_row_split exists for. And now that the position and monitor can be empty
# in the middle of a row as well, every column is peeled the same way.
WG_PLACE_SESSION=""
WG_PLACE_CWD=""
WG_PLACE_WORKSPACE=""
WG_PLACE_X=""
WG_PLACE_Y=""
WG_PLACE_MONITOR=""

wg_place_row_split() {
  local row="$1"
  local -a col=()
  while [[ $row == *$'\t'* ]]; do
    col+=("${row%%$'\t'*}")
    row="${row#*$'\t'}"
  done
  col+=("$row")
  WG_PLACE_SESSION="${col[0]:-}"
  WG_PLACE_CWD="${col[1]:-}"
  WG_PLACE_WORKSPACE="${col[2]:-}"
  WG_PLACE_X="${col[3]:-}"
  WG_PLACE_Y="${col[4]:-}"
  WG_PLACE_MONITOR="${col[5]:-}"
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
      # A queue, not a slot. One conversation can be open in two terminals, and
      # the snapshot keeps both; a plain assignment here kept whichever row came
      # last and sent both windows to it. Each matching window takes the next.
      ws_by_id[$WG_PLACE_SESSION]+="$WG_PLACE_WORKSPACE"$'\n'
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
        want="${ws_by_id[$arg]%%$'\n'*}"
        # The last one stays: a third terminal on the same conversation than
        # the record knew of goes where the others did, not nowhere.
        [[ ${ws_by_id[$arg]#*$'\n'} == "" ]] || ws_by_id[$arg]="${ws_by_id[$arg]#*$'\n'}"
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

# What a window is showing, as the key a record row is matched on: "i:<id>" for
# a session relaunched by id, "d:<dir>" for one matched only by its directory,
# nothing for a window no row knows. $1 is the window's pid; WG_PLACE_KIDS must
# be loaded, and WG_PLACE_KNOWN holds the keys worth answering with.
#
# The same matching wg_place_rows does inline -- the id among the child shell's
# arguments, else the child's directory -- so that "this window is that
# session" means one thing in every pass.
declare -A WG_PLACE_KNOWN=()

wg_place_key_of() {
  local pid="$1" kid arg kidcwd
  local -a args=()
  for kid in ${WG_PLACE_KIDS[$pid]:-}; do
    mapfile -d '' -t args < "$WG_PROC_DIR/$kid/cmdline" 2>/dev/null || continue
    for arg in ${args[@]+"${args[@]}"}; do
      [[ -n ${WG_PLACE_KNOWN[i:$arg]:-} ]] || continue
      printf 'i:%s\n' "$arg"
      return 0
    done
    kidcwd="$(readlink "$WG_PROC_DIR/$kid/cwd" 2>/dev/null)" || kidcwd=""
    if [[ -n $kidcwd && -n ${WG_PLACE_KNOWN[d:$kidcwd]:-} ]]; then
      printf 'd:%s\n' "$kidcwd"
      return 0
    fi
  done
  return 0
}

# Puts each recorded workspace back on the monitor it was on. $1 is a dry run
# flag, $2 the rows.
#
# A workspace is created on whichever monitor has focus when it is first used,
# and at login that is the same monitor for every one of them: the groups that
# lived on the second screen all came back on the first. This moves them back.
#
# Left alone: a workspace the record has no monitor for, a monitor that is not
# plugged in any more -- moving a group onto a screen that is not there would
# lose it -- and a workspace that is already where it belongs.
wg_place_monitors() {
  local dry="$1" rows="$2" row ws mon want
  local -A mon_of=() present=()
  [[ -n $rows ]] || return 0
  while IFS= read -r row; do
    wg_place_row_split "$row"
    [[ -n $WG_PLACE_WORKSPACE && -n $WG_PLACE_MONITOR ]] || continue
    [[ $WG_PLACE_WORKSPACE != special:* ]] || continue
    [[ -n ${mon_of[$WG_PLACE_WORKSPACE]:-} ]] || mon_of[$WG_PLACE_WORKSPACE]="$WG_PLACE_MONITOR"
  done <<<"$rows"
  (( ${#mon_of[@]} )) || return 0

  while IFS= read -r mon; do
    [[ -z $mon ]] || present[$mon]=1
  done < <(wg_hypr_query monitors 2>/dev/null | jq -r '.[].name' 2>/dev/null)

  # The monitor is last so that an empty one cannot pull the name into it.
  while IFS=$'\t' read -r ws mon; do
    [[ -n $ws ]] || continue
    want="${mon_of[$ws]:-}"
    [[ -n $want && -n ${present[$want]:-} ]] || continue
    [[ $mon != "$want" ]] || continue
    printf 'monitor  %s  %s\n' "$ws" "$want"
    (( ! dry )) || continue
    wg_hypr_dispatch moveworkspacetomonitor "name:$ws $want"
  done < <(wg_hypr_query workspaces 2>/dev/null \
           | jq -r '.[] | [.name, (.monitor // "")] | @tsv' 2>/dev/null)
}

# Puts the restored terminals on each workspace back in the tiles they were in.
# $1 is a dry run flag, $2 the rows.
#
# Hyprland tiles a window where it arrives, and a restore cannot make them
# arrive in the original order -- the tree dwindle builds depends on which
# window had focus at each arrival, which is not something a record of the
# finished desktop can replay. So the tiles are taken as they come, and the
# contents are swapped until each session sits where it was: the recorded
# sessions in reading order, left to right and then top to bottom, go into the
# current tiles in that same order.
#
# Only windows the record knows take part. A terminal the user opened by hand
# keeps its tile, and a session that did not come back simply leaves one fewer
# to arrange -- the rest still go in their order around it.
#
# The swaps are planned from a single look at the desktop, and the plan's own
# model is updated as each swap is made, rather than asking the compositor where
# everything went after each one. swapwindow acts on the focused window, so
# focus moves while this runs; whatever had it before is given it back.
wg_place_order() {
  local dry="$1" rows="$2" row key ws addr pid x y active i j n swaps=0
  local -A want_of=() have_of=()
  [[ -n $rows ]] || return 0
  WG_PLACE_KNOWN=()
  while IFS= read -r row; do
    wg_place_row_split "$row"
    [[ -n $WG_PLACE_CWD && -n $WG_PLACE_WORKSPACE ]] || continue
    [[ $WG_PLACE_WORKSPACE != special:* ]] || continue
    [[ $WG_PLACE_X =~ ^-?[0-9]+$ && $WG_PLACE_Y =~ ^-?[0-9]+$ ]] || continue
    if [[ -n $WG_PLACE_SESSION ]]; then key="i:$WG_PLACE_SESSION"; else key="d:$WG_PLACE_CWD"; fi
    WG_PLACE_KNOWN[$key]=1
    want_of[$WG_PLACE_WORKSPACE]+="$WG_PLACE_X"$'\t'"$WG_PLACE_Y"$'\t'"$key"$'\n'
  done <<<"$rows"
  (( ${#want_of[@]} )) || return 0

  wg_place_children
  while IFS=$'\t' read -r addr pid ws x y; do
    [[ -n $addr && -n $pid && -n ${want_of[$ws]:-} ]] || continue
    key="$(wg_place_key_of "$pid")"
    [[ -n $key ]] || continue
    have_of[$ws]+="$x"$'\t'"$y"$'\t'"$key"$'\t'"$addr"$'\n'
  done < <(wg_hypr_query clients 2>/dev/null \
           | jq -r '.[] | select(.pid != null and .address != null and (.floating | not))
                    | [.address, (.pid | tostring), (.workspace.name // ""),
                       ((.at // [0, 0])[0] | tostring), ((.at // [0, 0])[1] | tostring)]
                    | @tsv' 2>/dev/null)

  active="$(wg_hypr_query activewindow 2>/dev/null | jq -r '.address // empty' 2>/dev/null || true)"

  for ws in "${!have_of[@]}"; do
    local -a want=() keys=() addrs=() have_rows=()
    local -A left=()
    mapfile -t have_rows < <(printf '%s' "${have_of[$ws]}" | sort -t$'\t' -k1,1n -k2,2n)
    for row in "${have_rows[@]}"; do
      IFS=$'\t' read -r x y key addr <<<"$row"
      keys+=("$key")
      addrs+=("$addr")
      left[$key]=$(( ${left[$key]:-0} + 1 ))
    done
    # The recorded order, keeping only as many of each session as there are
    # windows showing it -- a session that did not come back is skipped over.
    while IFS=$'\t' read -r x y key; do
      [[ -n $key ]] || continue
      (( ${left[$key]:-0} > 0 )) || continue
      left[$key]=$(( ${left[$key]:-0} - 1 ))
      want+=("$key")
    done < <(printf '%s' "${want_of[$ws]}" | sort -t$'\t' -k1,1n -k2,2n)

    n=${#want[@]}
    for (( i = 0; i < n; i++ )); do
      [[ ${keys[i]} != "${want[i]}" ]] || continue
      for (( j = i + 1; j < ${#keys[@]}; j++ )); do
        [[ ${keys[j]} == "${want[i]}" ]] && break
      done
      (( j < ${#keys[@]} )) || continue
      printf 'order  %s  %s <-> %s\n' "$ws" "${keys[i]#?:}" "${keys[j]#?:}"
      if (( ! dry )); then
        wg_hypr_dispatch focuswindow "address:${addrs[i]}"
        wg_hypr_dispatch swapwindow "address:${addrs[j]}"
      fi
      # The model follows the swap: the window that was in tile j is in tile i
      # now, and the other way round.
      key="${keys[i]}"; keys[i]="${keys[j]}"; keys[j]="$key"
      addr="${addrs[i]}"; addrs[i]="${addrs[j]}"; addrs[j]="$addr"
      swaps=$(( swaps + 1 ))
    done
    unset want keys addrs have_rows left
  done

  if (( swaps && ! dry )) && [[ -n $active ]]; then
    wg_hypr_dispatch focuswindow "address:$active"
  fi
  return 0
}
