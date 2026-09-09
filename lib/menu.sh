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

  # Name and label together, NUL-delimited, in one jq: a label is free text and
  # could hold a tab or a newline.
  local name label
  while IFS= read -r -d '' name && IFS= read -r -d '' label; do
    [[ -n $name ]] || continue
    printf 'group:%s\t▸ %-18s %d windows · %d idle · %d busy\n' \
      "$name" "$label" "${wins[g:$name]:-0}" "${idles[g:$name]:-0}" "${busies[g:$name]:-0}"
  done < <(jq -j '.groups[]?
    | (.name | tostring) as $n
    | $n, "\u0000", (if (.label // "") == "" then $n else (.label | tostring) end), "\u0000"' \
    <<<"$state")

  printf 'noop\t%s\n' "──────────────────────────────"

  local glyph shown where
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    wg_row_split "$line"
    glyph="$(wg_status_glyph "${WG_ROW[6]}")"
    shown="$(wg_title_text "${WG_ROW[9]}")"
    where="${WG_ROW[5]:-ungrouped}"
    printf 'window:%s\t  %s %-44s %s\n' "${WG_ROW[1]}" "$glyph" "$shown" "$where"
  done <<<"$table"

  local auto
  auto="$(jq -r 'if .auto then "on" else "off" end' <<<"$state")"
  printf 'new\t%s\n' "+ new group…"
  printf 'tidy\t%s\n' "⟳ tidy — file every window by its project"
  printf 'toggle-auto\t%s\n' "⏻ auto-assign: $auto"
}

wg_group_menu_build() {
  local state="${1:-$(wg_state_read)}" name label
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    label="$(wg_state_group_field "$name" label "$state")"
    [[ -n $label ]] || label="$name"
    printf 'group:%s\t%s\n' "$name" "$label"
  done < <(wg_state_group_names "$state")
  printf 'new\t%s\n' "+ new group…"
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

  # Omarchy's own launcher starts elephant and the walker service if they are
  # not up yet -- without them the first walker of the session is slow, or does
  # not come up at all -- and applies the house geometry. Use it when it is
  # there, and when nobody has named a specific walker binary: $WG_WALKER
  # pointing anywhere else is a deliberate override (the tests do exactly that),
  # and it has to win. Off Omarchy there is no launcher, so pass the same
  # geometry to walker directly.
  local -a picker=()
  if [[ $WG_WALKER == walker && -x $WG_WALKER_LAUNCHER ]]; then
    picker=("$WG_WALKER_LAUNCHER")
  else
    picker=("$WG_WALKER" --width 644 --maxheight 300 --minheight 300)
  fi

  index="$(printf '%s\n' "${displays[@]}" | "${picker[@]}" -d -i -p "$prompt" || true)"
  [[ $index =~ ^[0-9]+$ ]] || return 0
  (( index < ${#actions[@]} )) || return 0
  [[ ${actions[index]} == noop ]] && return 0
  printf '%s\n' "${actions[index]}"
}
