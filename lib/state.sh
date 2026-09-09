# shellcheck shell=bash

: "${WG_STATE_DIR:=$HOME/.local/state/omarchy/wingroup}"
WG_STATE_FILE="$WG_STATE_DIR/state.json"
# Serialises read-modify-write of the state file across processes. Beside the
# file it protects rather than in $XDG_RUNTIME_DIR, so it is always in a
# directory we already create and can always write, and so that two runs
# pointed at different state directories do not queue behind each other.
WG_STATE_LOCK="$WG_STATE_DIR/.state.lock"
# Seconds to wait for the lock. A holder keeps it for one jq, so waiting at all
# is already unusual; giving up loudly beats hanging a keybind forever.
: "${WG_STATE_LOCK_WAIT:=5}"

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

# Reads the state, applies the jq filter $1 to it, and writes the result back --
# all three under an exclusive lock, so a concurrent update cannot be lost.
# Anything after $1 is passed to jq ahead of the filter, for --arg and friends.
#
#     wg_state_update '.overrides[$a] = $g' --arg a "$address" --arg g "$group"
#
# Both bin/wingroup and bin/wingroup-daemon read the state, change it and write
# it back, and without a lock the second writer commits a document built from a
# copy taken before the first writer's change: a `wingroup new` landing inside a
# closewindow handler simply vanished, with no error anywhere. Every such site
# goes through here.
#
# The lock is an flock on an open descriptor, so a caller that dies holding it
# releases it -- the kernel closes the descriptor -- and nothing has to clean up
# after a killed picker or a crashed daemon. It is taken here and nowhere else,
# so there is no second lock to deadlock against; and wg_state_read does not
# take it, because the read-only path (the bar, the picker, every resolve) must
# not queue behind a writer for a document it is about to re-read anyway.
wg_state_update() {
  local filter="$1"; shift
  local fd state updated rc=0

  mkdir -p "$WG_STATE_DIR" || return 1
  # Append mode: opening the lock must never truncate or create-clobber it, and
  # nothing is ever written through this descriptor.
  exec {fd}>>"$WG_STATE_LOCK" || return 1
  if ! flock -w "$WG_STATE_LOCK_WAIT" "$fd"; then
    printf 'wingroup: timed out waiting for %s; %s left unchanged\n' \
      "$WG_STATE_LOCK" "$WG_STATE_FILE" >&2
    exec {fd}>&-
    return 1
  fi

  state="$(wg_state_read)"
  if ! updated="$(jq "$@" "$filter" <<<"$state")"; then
    exec {fd}>&-
    return 1
  fi
  wg_state_write "$updated" || rc=1
  # Releasing by closing rather than `flock -u`: one operation, and it is the
  # same one that happens if this process dies here instead.
  exec {fd}>&-
  return "$rc"
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

# Drops every override whose window is gone. The live addresses arrive on
# stdin, one per line; the state file is updated in place, under the lock.
wg_state_prune_overrides() {
  local live
  live="$(jq -R -s 'split("\n") | map(select(length > 0))')"
  # shellcheck disable=SC2016  # $k and $live are jq variables, not shell ones
  wg_state_update '.overrides |= with_entries(select(.key as $k | $live | index($k)))' \
    --argjson live "$live"
}
