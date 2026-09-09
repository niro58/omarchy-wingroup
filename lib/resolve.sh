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
WG_SHELLS=""

wg_is_login_shell() {
  local shell="$1"
  [[ -n $shell ]] || return 1
  if [[ -z $WG_SHELLS ]]; then
    # Wrapped in newlines so an unreadable or missing /etc/shells still leaves
    # $WG_SHELLS non-empty: it stays "read", and matches nothing.
    WG_SHELLS=$'\n'"$(cat /etc/shells 2>/dev/null || true)"$'\n'
  fi
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

wg_children_load() {
  local ppid pid
  WG_CHILDREN=()
  while read -r ppid pid; do
    [[ -n $ppid && -n $pid ]] || continue
    if [[ -z ${WG_CHILDREN[$ppid]:-} ]] || (( pid > WG_CHILDREN[$ppid] )); then
      WG_CHILDREN[$ppid]="$pid"
    fi
  done < <(ps -eo ppid=,pid= 2>/dev/null || true)
  WG_CHILDREN_LOADED=1
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
  # Both links in one readlink rather than one each: whatever makes one of them
  # unreadable -- the process exited, or it is not ours -- makes both, so a
  # result that is not exactly two lines is the same "give up" the two separate
  # failures used to reach.
  mapfile -t link < <(readlink -f "/proc/$shell_pid/cwd" "/proc/$shell_pid/exe" 2>/dev/null)
  (( ${#link[@]} == 2 )) || return 0
  if wg_is_login_shell "${link[1]}" && [[ -d ${link[0]} ]]; then
    printf '%s\n' "${link[0]}"
  fi
}

wg_cwd_project() {
  local cwd="$1" rest
  [[ -n $cwd ]] || return 0
  [[ $cwd == "$WG_PROJECTS_DIR"/* ]] || return 0
  rest="${cwd#"$WG_PROJECTS_DIR"/}"
  printf '%s\n' "${rest%%/*}"
}

wg_cwd_worktree() {
  local cwd="$1" rest
  [[ $cwd == *"/.claude/worktrees/"* ]] || return 0
  rest="${cwd#*/.claude/worktrees/}"
  printf '%s\n' "${rest%%/*}"
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

wg_title_status() {
  local title="$1" glyph
  for glyph in "${WG_GLYPHS_IDLE[@]}"; do
    [[ $title == "$glyph"* ]] && { printf 'idle\n'; return 0; }
  done
  for glyph in "${WG_GLYPHS_BUSY[@]}"; do
    [[ $title == "$glyph"* ]] && { printf 'busy\n'; return 0; }
  done
  printf 'plain\n'
}

wg_title_text() {
  local title="$1" glyph
  for glyph in "${WG_GLYPHS_IDLE[@]}" "${WG_GLYPHS_BUSY[@]}"; do
    if [[ $title == "$glyph"* ]]; then
      title="${title#"$glyph"}"
      printf '%s\n' "${title# }"
      return 0
    fi
  done
  printf '%s\n' "$title"
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

  local address pid workspace floating title
  local cwd project worktree group status
  while IFS=$'\t' read -r address pid workspace floating title; do
    cwd="$(wg_window_cwd "$pid")"
    project="$(wg_cwd_project "$cwd")"
    worktree="$(wg_cwd_worktree "$cwd")"
    # Same precedence wg_window_group applies -- an override beats the project
    # -- resolved out of the map instead of out of two jq processes.
    group="${WG_STATE_MAP[o:$address]:-}"
    if [[ -z $group && -n $project ]]; then
      group="${WG_STATE_MAP[p:$project]:-}"
    fi
    status="$(wg_title_status "$title")"
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
