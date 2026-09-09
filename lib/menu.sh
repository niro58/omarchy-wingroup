# shellcheck shell=bash
# Requires lib/hypr.sh, lib/state.sh and lib/resolve.sh to be sourced first.

: "${WG_WALKER:=walker}"
: "${WG_WALKER_LAUNCHER:=$HOME/.local/share/omarchy/bin/omarchy-launch-walker}"

wg_status_glyph() {
  case $1 in
    idle) printf '✳\n' ;;
    busy) printf '◐\n' ;;
    *)    printf '·\n' ;;
  esac
}

# A window row's last column: the group the window belongs to, and -- when the
# window is sitting in a Claude worktree -- which worktree, as "group:worktree".
#
# Column 8 of the window table has carried the worktree name since the first
# version and nothing read it. It exists because two windows in different
# worktrees of the same repo resolve to the same project and therefore the same
# group, which is what you want for filing them and useless for telling them
# apart in a list: three rows reading "plat" and no way to know which is which.
#
# Truncated, because a worktree is named after a branch and a branch name has no
# upper bound. This is the row's last column and the one before it is padded to
# a fixed width, so an unbounded field here is the one thing that can push the
# layout around. The result is left in WG_WHERE rather than printed: this runs
# once per open window, and a command substitution per row is a fork per row.
WG_MENU_WORKTREE_MAX=16
WG_WHERE=""

wg_menu_where() {
  local group="$1" worktree="${2:-}"
  WG_WHERE="${group:-ungrouped}"
  [[ -n $worktree ]] || return 0
  if (( ${#worktree} > WG_MENU_WORKTREE_MAX )); then
    worktree="${worktree:0:WG_MENU_WORKTREE_MAX - 1}…"
  fi
  WG_WHERE+=":$worktree"
}

wg_menu_build() {
  local state="${1:-$(wg_state_read)}" table line
  table="$(wg_window_table)"

  # Every group's counts in one pass over the table. Asking per group cost two
  # awk and two wc processes each, on top of a jq for the label -- five
  # processes per group, for numbers one pass already has. Keys are prefixed
  # because a bare @ or * subscript means something else to bash.
  local -A wins=() idles=() busies=()
  local key
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    wg_row_split "$line"
    [[ -n ${WG_ROW[5]} ]] || continue
    key="g:${WG_ROW[5]}"
    wins[$key]=$(( ${wins[$key]:-0} + 1 ))
    case ${WG_ROW[6]} in
      idle) idles[$key]=$(( ${idles[$key]:-0} + 1 )) ;;
      busy) busies[$key]=$(( ${busies[$key]:-0} + 1 )) ;;
    esac
  done <<<"$table"

  # Groups first: switching to one is what the picker gets opened for.
  #
  # Name, label and pinned monitor together, NUL-delimited, in one jq: a label
  # is free text and could hold a tab or a newline.
  local name label monitor entry
  while IFS= read -r -d '' name && IFS= read -r -d '' label && IFS= read -r -d '' monitor; do
    [[ -n $name ]] || continue
    entry="$(printf '▸ %-18s %d windows · %d idle · %d busy' \
      "$label" "${wins[g:$name]:-0}" "${idles[g:$name]:-0}" "${busies[g:$name]:-0}")"
    # A group pinned to a monitor always opens there; say which, so the pin is
    # visible somewhere other than state.json.
    if [[ -n $monitor ]]; then
      entry+=" · on $monitor"
    fi
    printf 'group:%s\t%s\n' "$name" "$entry"
  done < <(jq -j '.groups[]?
    | (.name | tostring) as $n
    | $n, "\u0000",
      (if (.label // "") == "" then $n else (.label | tostring) end), "\u0000",
      (if (.monitor // "") == "" then "" else (.monitor | tostring) end), "\u0000"' \
    <<<"$state")

  # Then the actions, above the window list rather than below it. With fifteen
  # windows open they used to land some twenty rows down -- far enough that
  # "+ new group…" read as something the picker did not have.
  #
  # The two that make and unmake a group sit together, then the two that act on
  # everything at once. "− remove a group…" only opens a chooser and then a
  # confirmation, so landing on it by mistake costs a keystroke, not a group.
  local auto
  auto="$(jq -r 'if .auto then "on" else "off" end' <<<"$state")"
  printf 'new\t%s\n' "+ new group…"
  printf 'delete\t%s\n' "− remove a group…"
  printf 'tidy\t%s\n' "⟳ tidy — file every window by its project"
  printf 'toggle-auto\t%s\n' "⏻ auto-assign: $auto"

  printf 'noop\t%s\n' "──────────────────────────────"

  local glyph shown
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    wg_row_split "$line"
    glyph="$(wg_status_glyph "${WG_ROW[6]}")"
    shown="$(wg_title_text "${WG_ROW[9]}")"
    # Column 5 is the group, column 8 the worktree.
    wg_menu_where "${WG_ROW[5]}" "${WG_ROW[8]}"
    printf 'window:%s\t  %s %-44s %s\n' "${WG_ROW[1]}" "$glyph" "$shown" "$WG_WHERE"
  done <<<"$table"
}

# Every group and nothing else: the chooser for picking one to act on.
wg_group_list_build() {
  local state="${1:-$(wg_state_read)}" name label
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    label="$(wg_state_group_field "$name" label "$state")"
    [[ -n $label ]] || label="$name"
    printf 'group:%s\t%s\n' "$name" "$label"
  done < <(wg_state_group_names "$state")
}

# The same list plus a way out of it: sending a window to a group you have not
# made yet is the one place where creating one is part of the same errand.
wg_group_menu_build() {
  wg_group_list_build "${1:-}"
  printf 'new\t%s\n' "+ new group…"
}

# The confirmation in front of removing a group.
#
# Cancel is first, so the entry already under the cursor is the harmless one --
# tidy can put its action first because the worst a stray Enter does there is
# move some windows, and this one cannot be undone.
wg_delete_confirm_build() {
  local name="$1" label="${2:-$1}"
  printf 'noop\t%s\n' "Cancel"
  printf 'delete:%s\t%s\n' "$name" "Remove group $label — its windows stay where they are"
}

# The command that puts walker on the screen, left in WG_PICKER.
#
# Omarchy's own launcher starts elephant and the walker service if they are not
# up yet -- without them the first walker of the session is slow, or does not
# come up at all -- and applies the house geometry. Use it when it is there, and
# when nobody has named a specific walker binary: $WG_WALKER pointing anywhere
# else is a deliberate override (the tests do exactly that), and it has to win.
# Off Omarchy there is no launcher, so pass the same geometry to walker directly.
declare -ga WG_PICKER=()

wg_menu_picker() {
  if [[ $WG_WALKER == walker && -x $WG_WALKER_LAUNCHER ]]; then
    WG_PICKER=("$WG_WALKER_LAUNCHER")
  else
    WG_PICKER=("$WG_WALKER" --width 644 --maxheight 300 --minheight 300)
  fi
}

# Reads action<TAB>display on stdin, shows walker, prints the chosen action.
wg_menu_run() {
  local prompt="${1:-}" index
  local -a actions=() displays=()
  local action display

  while IFS=$'\t' read -r action display; do
    actions+=("$action")
    displays+=("$display")
  done

  wg_menu_picker
  index="$(printf '%s\n' "${displays[@]}" | "${WG_PICKER[@]}" -d -i -p "$prompt" || true)"
  [[ $index =~ ^[0-9]+$ ]] || return 0
  (( index < ${#actions[@]} )) || return 0
  [[ ${actions[index]} == noop ]] && return 0
  printf '%s\n' "${actions[index]}"
}

# Asks for one line of text and prints it, trimmed.
#
# walker's -I/--inputonly is dmenu mode showing nothing but the input box, so
# there are no entries to feed it and stdin stays shut. Cancelling and typing
# nothing both print nothing: the caller cannot tell those apart, and has no
# reason to.
wg_menu_input() {
  local prompt="${1:-}" text
  wg_menu_picker
  text="$("${WG_PICKER[@]}" -d -I -p "$prompt" </dev/null || true)"
  text="${text%%$'\n'*}"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  printf '%s\n' "$text"
}
