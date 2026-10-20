# shellcheck shell=bash
# Requires lib/hypr.sh and lib/state.sh to be sourced first.

: "${WG_PROJECTS_DIR:=$HOME/projects}"

# Glyphs Claude Code puts at the head of the window title.
# Verified empirically: a finishing session goes ◐ → ✳; a working one
# alternates ◐ ↔ ◑. Add newly observed glyphs to these arrays and nowhere else.
WG_GLYPHS_IDLE=("✳")
WG_GLYPHS_BUSY=("◐" "◑")

# /etc/shells, read once and kept for the life of the process. wg_window_cwd is
# called once per open window, and grepping the file each time is one fork per
# window for a file that does not change under us.
#
# Read with `read`, not `$(cat ...)`: wg_window_table calls wg_window_cwd inside
# a command substitution, so a lazy load there happened again in every window's
# subshell -- a cat per window. The table loads it up front instead, and the
# builtin read costs no fork for a caller that does not.
WG_SHELLS=""

wg_shells_load() {
  [[ -z $WG_SHELLS ]] || return 0
  local shells=""
  IFS= read -r -d '' shells </etc/shells 2>/dev/null || true
  # Wrapped in newlines so an unreadable or missing /etc/shells still leaves
  # $WG_SHELLS non-empty: it stays "read", and matches nothing.
  WG_SHELLS=$'\n'"$shells"$'\n'
}

wg_is_login_shell() {
  local shell="$1"
  [[ -n $shell ]] || return 1
  wg_shells_load
  [[ $WG_SHELLS == *"$shell"* ]]
}

# Parent pid -> its highest-numbered direct child, for every process on the
# machine, from a single `ps`.
#
# This replaces a `pgrep -P <pid> | tail -n1` per window. pgrep walks the whole
# process table on every call, so a 15-window table paid for fifteen full walks
# plus thirty forks -- a third of a second on this machine. One walk here
# answers for every window at once. The highest pid is the child
# `pgrep | tail -n1` picked, pgrep listing its matches in ascending pid order.
declare -gA WG_CHILDREN=()
WG_CHILDREN_LOADED=0

#
# The highest child is picked in awk, not here: a desktop with a thousand
# processes made this a thousand-turn bash loop, a third of the window table's
# cost, and the bar builds that table on every title change. awk hands back one
# line per parent instead.
wg_children_load() {
  local ppid pid
  WG_CHILDREN=()
  while read -r ppid pid; do
    [[ -n $ppid && -n $pid ]] || continue
    WG_CHILDREN[$ppid]="$pid"
  done < <(ps -eo ppid=,pid= 2>/dev/null \
    | awk 'NF == 2 && (!($1 in top) || $2 + 0 > top[$1] + 0) { top[$1] = $2 }
           END { for (p in top) print p, top[p] }' || true)
  WG_CHILDREN_LOADED=1
}

# bash's loadable realpath, when the system ships it: it resolves /proc links
# into an array without a fork. wg_window_cwd runs once per open window, and a
# readlink there was a process plus a process substitution for every one of
# them. Tried once per process; where the loadable is missing, readlink it is.
WG_REALPATH=""

wg_realpath_load() {
  [[ -z $WG_REALPATH ]] || return 0
  WG_REALPATH=readlink
  local lib
  for lib in /usr/lib/bash/realpath /usr/local/lib/bash/realpath /usr/lib/x86_64-linux-gnu/bash/realpath; do
    if [[ -f $lib ]] && enable -f "$lib" realpath 2>/dev/null; then
      WG_REALPATH=builtin
      return 0
    fi
  done
}

# Mirrors omarchy-cmd-terminal-cwd: the window's pid is the terminal, its
# last child is the shell, and the shell's cwd is what we want.
wg_window_cwd() {
  local pid="$1" shell_pid
  local -a link=()
  # wg_window_table loads the map for the whole build before it starts; this is
  # only for a caller that asks for one window on its own.
  (( WG_CHILDREN_LOADED )) || wg_children_load
  shell_pid="${WG_CHILDREN[$pid]:-}"
  [[ -n $shell_pid ]] || return 0
  # Both links in one call rather than one each: whatever makes one of them
  # unreadable -- the process exited, or it is not ours -- makes both, so a
  # result that is not exactly two entries is the same "give up" the two
  # separate failures used to reach.
  wg_realpath_load
  if [[ $WG_REALPATH == builtin ]]; then
    realpath -q -a link "/proc/$shell_pid/cwd" "/proc/$shell_pid/exe" 2>/dev/null || true
  else
    mapfile -t link < <(readlink -f "/proc/$shell_pid/cwd" "/proc/$shell_pid/exe" 2>/dev/null)
  fi
  (( ${#link[@]} == 2 )) || return 0
  if wg_is_login_shell "${link[1]}" && [[ -d ${link[0]} ]]; then
    printf '%s\n' "${link[0]}"
  fi
}

# The project and the Claude worktree a cwd is in, left in WG_PROJECT and
# WG_WORKTREE rather than printed -- the same reason as WG_WHERE in lib/menu.sh:
# the table asks this once per window, and a command substitution is a fork.
# Either is empty when the cwd is not in one.
WG_PROJECT=""
WG_WORKTREE=""

wg_cwd_split() {
  local cwd="$1" rest
  WG_PROJECT=""
  WG_WORKTREE=""
  [[ -n $cwd ]] || return 0
  if [[ $cwd == "$WG_PROJECTS_DIR"/* ]]; then
    rest="${cwd#"$WG_PROJECTS_DIR"/}"
    WG_PROJECT="${rest%%/*}"
  fi
  if [[ $cwd == *"/.claude/worktrees/"* ]]; then
    rest="${cwd#*/.claude/worktrees/}"
    WG_WORKTREE="${rest%%/*}"
  fi
}

wg_cwd_project() {
  wg_cwd_split "$1"
  [[ -z $WG_PROJECT ]] || printf '%s\n' "$WG_PROJECT"
}

wg_cwd_worktree() {
  wg_cwd_split "$1"
  [[ -z $WG_WORKTREE ]] || printf '%s\n' "$WG_WORKTREE"
}

wg_project_group() {
  local project="$1" state="${2:-$(wg_state_read)}"
  [[ -n $project ]] || return 0
  jq -r --arg p "$project" \
    'first(.groups[] | select(.projects | index($p)) | .name) // empty' <<<"$state"
}

wg_window_group() {
  local address="$1" project="$2" state="${3:-$(wg_state_read)}" override
  override="$(jq -r --arg a "$address" '.overrides[$a] // empty' <<<"$state")"
  if [[ -n $override ]]; then
    printf '%s\n' "$override"
    return 0
  fi
  wg_project_group "$project" "$state"
}

# A title's status (idle, busy or plain) and its text with the status glyph
# taken off, left in WG_STATUS and WG_TEXT. Not printed, for the same reason as
# wg_cwd_split: both are asked once per window on every menu build.
WG_STATUS=""
WG_TEXT=""

wg_title_parse() {
  local title="$1" glyph
  WG_STATUS=plain
  WG_TEXT="$title"
  for glyph in "${WG_GLYPHS_IDLE[@]}"; do
    [[ $title == "$glyph"* ]] || continue
    WG_STATUS=idle
    title="${title#"$glyph"}"
    WG_TEXT="${title# }"
    return 0
  done
  for glyph in "${WG_GLYPHS_BUSY[@]}"; do
    [[ $title == "$glyph"* ]] || continue
    WG_STATUS=busy
    title="${title#"$glyph"}"
    WG_TEXT="${title# }"
    return 0
  done
}

wg_title_status() {
  wg_title_parse "$1"
  printf '%s\n' "$WG_STATUS"
}

wg_title_text() {
  wg_title_parse "$1"
  printf '%s\n' "$WG_TEXT"
}

# Both of the state's window->group lookups, flattened into one associative
# array: "o:<address>" -> the group an override sends that window to, and
# "p:<project>" -> the group that owns that project.
#
# The "o:"/"p:" prefixes are not decoration. An associative-array subscript of
# exactly @ or * means something else to bash, and a project is a directory name
# the user chose -- the prefix keeps every subscript a literal key.
declare -gA WG_STATE_MAP=()

# Fills WG_STATE_MAP from $1 (a state document) with a single jq.
#
# wg_window_table used to answer both questions per window through
# wg_window_group, which is two jq processes for every window on screen -- some
# thirty of them on a working desktop, and most of the second and a half the
# picker took to appear.
wg_state_map_load() {
  local state="$1" key value
  WG_STATE_MAP=()
  # NUL-delimited: group names, project names and override keys are all
  # arbitrary strings, and a tab or a newline in any of them would otherwise
  # read as a field separator.
  while IFS= read -r -d '' key && IFS= read -r -d '' value; do
    # First writer wins, mirroring the first(...) the per-window jq used: when
    # two groups list the same project, the earlier group in state order owns it.
    [[ -n ${WG_STATE_MAP[$key]+set} ]] || WG_STATE_MAP[$key]="$value"
  done < <(jq -j '
    ( (.overrides // {}) | to_entries[]
      | select(.value != null and .value != false and .value != "")
      | ("o:" + .key), "\u0000", (.value | tostring), "\u0000" ),
    ( .groups[]?
      | select(.name != null and .name != false and .name != "")
      | (.name | tostring) as $g
      | .projects[]?
      | ("p:" + tostring), "\u0000", $g, "\u0000" )
  ' <<<"$state")
}

wg_window_table() {
  local clients="${1:-}" state
  [[ -n $clients ]] || clients="$(wg_hypr_query clients)"
  state="$(wg_state_read)"
  wg_state_map_load "$state"
  # Once, here, and not lazily from wg_window_cwd: that runs inside a command
  # substitution, so the map it built would die with the subshell and every
  # window would pay for its own scan. Rebuilt on every build rather than
  # cached, because the daemon asks for a row again and again while a
  # terminal's shell is still spawning -- an answer from a scan taken before
  # that shell existed is exactly the answer it must not get.
  wg_children_load
  # These two as well, for the same reason: loaded inside the substitution,
  # every window would load them again.
  wg_realpath_load
  wg_shells_load

  local address pid workspace floating title
  local cwd project worktree group status
  while IFS=$'\t' read -r address pid workspace floating title; do
    # Still a command substitution, and the only one left per window: this is
    # the seam the tests replace with a fixture, and they replace it with a
    # function that prints.
    cwd="$(wg_window_cwd "$pid")"
    wg_cwd_split "$cwd"
    project="$WG_PROJECT"
    worktree="$WG_WORKTREE"
    # Same precedence wg_window_group applies -- an override beats the project
    # -- resolved out of the map instead of out of two jq processes.
    group="${WG_STATE_MAP[o:$address]:-}"
    if [[ -z $group && -n $project ]]; then
      group="${WG_STATE_MAP[p:$project]:-}"
    fi
    wg_title_parse "$title"
    status="$WG_STATUS"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$address" "$pid" "$workspace" "$floating" \
      "$group" "$status" "$project" "$worktree" "$title"
  done < <(jq -r '.[] | [.address, (.pid|tostring), .workspace.name, (.floating|tostring), .title] | @tsv' <<<"$clients")
}

# Splits one wg_window_table row into WG_ROW[1..9] -- the array index is the
# column number -- using nothing but parameter expansion.
#
# Callers used to reach for `cut -f5` or an awk per column, which is a process
# per column per window. What they cannot use instead is a multi-variable
# `IFS=$'\t' read -r a b c ...`: tab is IFS whitespace, so bash collapses runs
# of tabs, and the group and worktree columns are routinely empty -- one empty
# interior column shifts every column after it. Peeling a column at a time does
# not collapse anything.
declare -ga WG_ROW=()

wg_row_split() {
  local rest="$1" i
  WG_ROW=("")
  for (( i = 1; i < 9; i++ )); do
    WG_ROW+=("${rest%%$'\t'*}")
    rest="${rest#*$'\t'}"
  done
  WG_ROW+=("$rest")
}

# One row, for one address. Filters the client list down to that address
# *before* building the table rather than building every row and throwing all
# but one away: each row costs a process-table walk and a /proc readlink, and
# the daemon asks for a single row up to WG_RESOLVE_RETRIES + 1 times per
# window it opens.
wg_window_row() {
  local address="$1" clients="${2:-}"
  [[ -n $clients ]] || clients="$(wg_hypr_query clients)"
  wg_window_table "$(jq --arg a "$address" '[.[] | select(.address == $a)]' <<<"$clients")"
}
