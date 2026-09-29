#!/usr/bin/env bats

# What is left of each account, per account.
#
# Claude Code's own /usage reads api/oauth/usage with the account's OAuth token,
# and that is the only thing on the machine that knows how much of a window is
# spent -- the transcripts say what was used, never what remains. So this asks
# the same endpoint, once per registered account, with that account's own token
# from its own configuration directory.
#
# Two rules the tests below exist to hold:
#
#   A token is read and sent, and never written anywhere. Not into the record,
#   not into an error message, not into a log.
#
#   An account that cannot answer says so in its own record. One account being
#   logged out, rate limited or offline must not cost the others their reading,
#   and must not leave the bar showing a stale number as though it were current.

load helper

setup() {
  wg_setup_tmp
  # shellcheck source=lib/state.sh
  source "$WG_LIB_DIR/state.sh"
  # shellcheck source=lib/sessions.sh
  source "$WG_LIB_DIR/sessions.sh"
  # shellcheck source=lib/accounts.sh
  source "$WG_LIB_DIR/accounts.sh"

  # Never the real one: the records are what the bar reads, and a test must not
  # tell the user's own bar that an account is out of room.
  export WG_USAGE_DIR="$WG_TMP/usage"

  # The endpoint, stubbed. It writes what it was asked for so a test can assert
  # on the call, and answers with whatever the test put in $WG_TMP/reply.
  export WG_USAGE_FETCH="$WG_TMP/fetch-stub"
  export WG_USAGE_FETCH_LOG="$WG_TMP/fetch.log"
  # The contract is the collector's: the HTTP status on the first line, the
  # body after it.
  cat >"$WG_USAGE_FETCH" <<'STUB'
#!/usr/bin/env bash
# $1 is the account's directory, $2 the token. The token is logged as its
# length alone -- a test that printed one would be a test that leaked one.
printf '%s\ttoken:%s\n' "$1" "${#2}" >>"$WG_USAGE_FETCH_LOG"
cat "$WG_TMP/status" 2>/dev/null || printf '200\n'
cat "$WG_TMP/reply" 2>/dev/null
STUB
  chmod +x "$WG_USAGE_FETCH"
  : >"$WG_USAGE_FETCH_LOG"

  wg_usage_reply '{"five_hour":{"utilization":30,"resets_at":"2026-09-29T12:00:00+00:00"},
                   "seven_day":{"utilization":51,"resets_at":"2026-10-05T20:00:00+00:00"}}'
}

teardown() { wg_teardown_tmp; }

wg_usage_reply() { printf '%s' "$1" >"$WG_TMP/reply"; printf '200\n' >"$WG_TMP/status"; }
# $1 is the HTTP status the endpoint answers with; "000" is curl's own word for
# never having got an answer at all.
wg_usage_fails() { printf '%s' "${2:-}" >"$WG_TMP/reply"; printf '%s\n' "$1" >"$WG_TMP/status"; }

# Gives account $1 a credentials file, as `claude auth login` would.
wg_usage_logged_in() {
  local dir; dir="$(wg_account_dir "$1")"
  mkdir -p "$dir"
  printf '{"claudeAiOauth":{"accessToken":"%s"}}\n' "${2:-tok-$1-secret}" >"$dir/.credentials.json"
}

# Not `.[$f] // ""`: jq's // takes the right-hand side for false as well as for
# null, so the account that is not active would read as a field that is not
# there -- and the test asserting it is "false" would pass whether the collector
# wrote false or wrote nothing at all.
record() {
  jq -r --arg f "$2" 'if has($f) then (.[$f] | tostring) else "" end' "$WG_USAGE_DIR/$1.json"
}

@test "the active account's windows are written to its own record" {
  wg_usage_logged_in default
  run "$WG_ROOT/bin/wingroup-usage"
  [ "$status" -eq 0 ]
  [ -f "$WG_USAGE_DIR/default.json" ]
  [ "$(record default five_hour_percent)" = "30" ]
  [ "$(record default seven_day_percent)" = "51" ]
  [ "$(record default five_hour_resets_at)" = "2026-09-29T12:00:00+00:00" ]
  [ "$(record default state)" = "ok" ]
}

@test "every registered account is read, each with its own token" {
  wg_account_add second
  wg_usage_logged_in default
  wg_usage_logged_in second

  run "$WG_ROOT/bin/wingroup-usage"
  [ "$status" -eq 0 ]
  [ -f "$WG_USAGE_DIR/default.json" ]
  [ -f "$WG_USAGE_DIR/second.json" ]
  run bash -c "cut -f1 '$WG_USAGE_FETCH_LOG' | sort | tr '\n' ' '"
  [ "$output" = "$HOME/.claude $WG_ACCOUNTS_DIR/second " ]
}

# The one thing this must never do.
@test "no token reaches any file it writes" {
  wg_account_add second
  wg_usage_logged_in default "tok-default-secret"
  wg_usage_logged_in second "tok-second-secret"

  run "$WG_ROOT/bin/wingroup-usage"
  [ "$status" -eq 0 ]
  run bash -c "grep -rl 'secret' '$WG_STATE_DIR' 2>/dev/null | grep -v credentials | wc -l"
  [ "$output" -eq 0 ]
  run bash -c "printf '%s' \"\$output\" | grep -c secret || true"
  [ "$output" -eq 0 ]
}

@test "an account that was never logged in says so instead of guessing" {
  wg_account_add second
  wg_usage_logged_in default

  run "$WG_ROOT/bin/wingroup-usage"
  [ "$status" -eq 0 ]
  [ "$(record second state)" = "needs-login" ]
  [ "$(record default state)" = "ok" ]
}

@test "a token the endpoint rejects reads as needing a login, not as zero usage" {
  wg_usage_logged_in default
  wg_usage_fails 401 '{"error":"unauthorized"}'

  run "$WG_ROOT/bin/wingroup-usage"
  [ "$status" -eq 0 ]
  [ "$(record default state)" = "needs-login" ]
  [ "$(record default five_hour_percent)" = "" ]
}

# A window nobody could read is not a window at 0%. The bar has to be able to
# tell "you have room" from "I could not find out", because they lead to
# opposite decisions about where to open the next session.
@test "an endpoint that cannot be reached leaves no percentage behind" {
  wg_usage_logged_in default
  wg_usage_fails 000 ''

  run "$WG_ROOT/bin/wingroup-usage"
  [ "$status" -eq 0 ]
  [ "$(record default state)" = "unreachable" ]
  [ "$(record default five_hour_percent)" = "" ]
}

@test "an answer that is not JSON is an error, not a record of nothing" {
  wg_usage_logged_in default
  wg_usage_reply 'maintenance in progress'

  run "$WG_ROOT/bin/wingroup-usage"
  [ "$status" -eq 0 ]
  [ "$(record default state)" = "unreadable" ]
}

@test "one account failing does not cost the others their reading" {
  wg_account_add second
  wg_usage_logged_in second
  # default has no credentials at all

  run "$WG_ROOT/bin/wingroup-usage"
  [ "$status" -eq 0 ]
  [ "$(record default state)" = "needs-login" ]
  [ "$(record second state)" = "ok" ]
  [ "$(record second five_hour_percent)" = "30" ]
}

@test "the record says when it was taken, so the bar can tell fresh from stale" {
  wg_usage_logged_in default
  run "$WG_ROOT/bin/wingroup-usage"
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.taken_at' '$WG_USAGE_DIR/default.json'"
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

@test "the active account is marked in the records" {
  wg_account_add second
  wg_usage_logged_in default
  wg_usage_logged_in second
  wg_account_use second

  run "$WG_ROOT/bin/wingroup-usage"
  [ "$status" -eq 0 ]
  [ "$(record second active)" = "true" ]
  [ "$(record default active)" = "false" ]
}

@test "a record for an account that has been removed does not linger" {
  wg_account_add second
  wg_usage_logged_in second
  run "$WG_ROOT/bin/wingroup-usage"
  [ -f "$WG_USAGE_DIR/second.json" ]

  wg_account_remove second
  run "$WG_ROOT/bin/wingroup-usage"
  [ "$status" -eq 0 ]
  [ ! -f "$WG_USAGE_DIR/second.json" ]
}
