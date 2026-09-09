# shellcheck shell=bash

: "${WG_STATE_DIR:=$HOME/.local/state/omarchy/wingroup}"
WG_STATE_FILE="$WG_STATE_DIR/state.json"

wg_state_default() {
  printf '%s\n' '{"auto":true,"follow":true,"catchall":null,"groups":[],"overrides":{}}'
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

# Commits $1 as the new state, or fails without touching the existing file.
#
# Both guards matter more than they look. wg_state_read treats an unparseable
# state file as corrupt: it renames it to state.json.corrupt and installs the
# empty default, which loses every group the user ever made. So anything that
# would commit a non-JSON or truncated file destroys their configuration. And
# the daemon runs its handlers under `|| true`, which suppresses errexit for
# everything they call -- a failed write there would otherwise fall straight
# through to the mv and commit the truncated file.
wg_state_write() {
  local json="$1" tmp
  if ! jq -e . >/dev/null 2>&1 <<<"$json"; then
    printf 'wingroup: refusing to write state that is not valid JSON; %s left unchanged\n' \
      "$WG_STATE_FILE" >&2
    return 1
  fi
  mkdir -p "$WG_STATE_DIR" || return 1
  tmp="$(mktemp "$WG_STATE_DIR/.state.XXXXXX")" || return 1
  if ! printf '%s\n' "$json" >"$tmp"; then
    rm -f "$tmp"
    printf 'wingroup: failed to write %s; %s left unchanged\n' "$tmp" "$WG_STATE_FILE" >&2
    return 1
  fi
  if ! mv -f "$tmp" "$WG_STATE_FILE"; then
    rm -f "$tmp"
    return 1
  fi
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
