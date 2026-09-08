# shellcheck shell=bash

: "${WG_STATE_DIR:=$HOME/.local/state/omarchy/wingroup}"
WG_STATE_FILE="$WG_STATE_DIR/state.json"

wg_state_default() {
  printf '%s\n' '{"auto":true,"catchall":null,"groups":[],"overrides":{}}'
}

wg_state_read() {
  if [[ ! -f $WG_STATE_FILE ]]; then
    wg_state_write "$(wg_state_default)"
  elif ! jq -e . "$WG_STATE_FILE" >/dev/null 2>&1; then
    mv -f "$WG_STATE_FILE" "$WG_STATE_FILE.corrupt"
    wg_state_write "$(wg_state_default)"
  fi
  cat "$WG_STATE_FILE"
}

wg_state_write() {
  local json="$1" tmp
  mkdir -p "$WG_STATE_DIR"
  tmp="$(mktemp "$WG_STATE_DIR/.state.XXXXXX")"
  printf '%s\n' "$json" >"$tmp"
  mv -f "$tmp" "$WG_STATE_FILE"
}

wg_state_group_names() {
  local state="${1:-$(wg_state_read)}"
  jq -r '.groups[].name' <<<"$state"
}

wg_state_group_field() {
  local name="$1" field="$2" state="${3:-$(wg_state_read)}"
  jq -r --arg n "$name" --arg f "$field" \
    'first(.groups[] | select(.name == $n) | .[$f]) // empty' <<<"$state"
}

wg_state_prune_overrides() {
  local state="${1:-$(wg_state_read)}" live
  live="$(jq -R -s 'split("\n") | map(select(length > 0))')"
  jq --argjson live "$live" \
    '.overrides |= with_entries(select(.key as $k | $live | index($k)))' <<<"$state"
}
