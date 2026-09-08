# shellcheck shell=bash
# Requires lib/hypr.sh, lib/state.sh and lib/resolve.sh to be sourced first.

: "${WG_WALKER:=walker}"

wg_status_glyph() {
  case $1 in
    idle) printf '✳\n' ;;
    busy) printf '◐\n' ;;
    *)    printf '·\n' ;;
  esac
}

wg_menu_build() {
  local state="${1:-$(wg_state_read)}" table
  table="$(wg_window_table)"

  local name label total busy
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    label="$(wg_state_group_field "$name" label "$state")"
    [[ -n $label ]] || label="$name"
    total="$(awk -F'\t' -v g="$name" '$5 == g' <<<"$table" | wc -l)"
    busy="$(awk -F'\t' -v g="$name" '$5 == g && $6 == "busy"' <<<"$table" | wc -l)"
    printf 'group:%s\t▸ %-18s %d windows, %d busy\n' "$name" "$label" "$total" "$busy"
  done < <(wg_state_group_names "$state")

  printf 'noop\t%s\n' "──────────────────────────────"

  local address group status title glyph shown where
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    address="$(printf '%s\n' "$line" | awk -F'\t' '{print $1}')"
    group="$(printf '%s\n' "$line" | awk -F'\t' '{print $5}')"
    status="$(printf '%s\n' "$line" | awk -F'\t' '{print $6}')"
    title="$(printf '%s\n' "$line" | awk -F'\t' '{print $9}')"
    glyph="$(wg_status_glyph "$status")"
    shown="$(wg_title_text "$title")"
    where="${group:-ungrouped}"
    printf 'window:%s\t  %s %-44s %s\n' "$address" "$glyph" "$shown" "$where"
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

  index="$(printf '%s\n' "${displays[@]}" | "$WG_WALKER" -d -i -p "$prompt" || true)"
  [[ $index =~ ^[0-9]+$ ]] || return 0
  (( index < ${#actions[@]} )) || return 0
  [[ ${actions[index]} == noop ]] && return 0
  printf '%s\n' "${actions[index]}"
}
