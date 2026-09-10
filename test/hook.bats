#!/usr/bin/env bats
#
# The hook is the only thing on the machine that knows a session's id, and it
# runs at the worst possible moment to be wrong: SessionStart, in front of a
# user who is waiting for their session. So half of what is checked here is
# what it records, and the other half is that nothing it can be handed makes it
# fail, hang, or say anything on stdout.

load helper

setup() {
  wg_setup_tmp
  # The runtime paths are read at source time, and wg_setup_tmp has just
  # pointed them at the temp directory.
  # shellcheck source=lib/state.sh
  source "$WG_LIB_DIR/state.sh"
  # shellcheck source=lib/sessions.sh
  source "$WG_LIB_DIR/sessions.sh"

  WG_SCOPE="$(wg_fake_scope 9029a872)"
  WG_SESSION_CWD="$WG_TMP/projects/shop-web"
  # The hook resolves its own scope through $WG_PROC_DIR/self, so the fake
  # process table needs a "self" in it. wg_sessions_scan globs [0-9]* and so
  # never picks this entry up as a process of its own.
  wg_fake_proc self claude "$WG_SCOPE" "$WG_SESSION_CWD"
}

teardown() { wg_teardown_tmp; }

# Runs the hook with $1 as the payload on stdin, the way Claude Code does.
# Through a file rather than a heredoc so that stdin is never a terminal --
# which is a case the hook deliberately treats as "nobody is going to type a
# payload here" and skips.
hook() {
  printf '%s' "$1" >"$WG_TMP/payload.json"
  run bash -c "'$WG_ROOT/bin/wingroup-hook' <'$WG_TMP/payload.json'"
}

recorded() {
  jq -r --arg s "$WG_SCOPE" --arg f "$1" '.sessions[$s][$f] // ""' <<<"$(wg_sessions_read)"
}

@test "a well-formed payload records the session id against the scope" {
  hook '{"session_id":"11111111-2222-3333-4444-555555555555",
         "transcript_path":"/home/dev/.claude/projects/x.jsonl",
         "cwd":"/home/dev/projects/shop-web",
         "hook_event_name":"SessionStart","source":"startup"}'
  [ "$status" -eq 0 ]
  [ "$(recorded session)" = "11111111-2222-3333-4444-555555555555" ]
  [ "$(recorded cwd)" = "/home/dev/projects/shop-web" ]
  [ "$(recorded source)" = "hook" ]
}

# A SessionStart hook's stdout is fed into the session as context. Anything
# printed here would be prepended to the user's conversation.
@test "the hook prints nothing on stdout" {
  hook '{"session_id":"abc","cwd":"/home/dev/projects/shop-web"}'
  [ -z "$output" ]
}

@test "a payload that is not JSON records nothing and still exits 0" {
  hook 'not json at all'
  [ "$status" -eq 0 ]
  [ "$(jq '.sessions | length' <<<"$(wg_sessions_read)")" -eq 0 ]
}

@test "an empty payload records nothing and still exits 0" {
  hook ''
  [ "$status" -eq 0 ]
  [ "$(jq '.sessions | length' <<<"$(wg_sessions_read)")" -eq 0 ]
}

# JSON of some future shape, or of the wrong shape entirely: the field names
# belong to Claude Code, and this hook is not the place to discover they moved.
@test "a payload with no session id records nothing" {
  hook '{"hook_event_name":"SessionStart","cwd":"/home/dev/projects/shop-web"}'
  [ "$status" -eq 0 ]
  [ "$(jq '.sessions | length' <<<"$(wg_sessions_read)")" -eq 0 ]
}

# Claude runs the hook as a child of the session, so the hook's own working
# directory is the session's when the payload does not carry one.
@test "a payload with no cwd falls back to the directory the hook runs in" {
  printf '%s' '{"session_id":"abc"}' >"$WG_TMP/payload.json"
  run bash -c "cd '$WG_SESSION_CWD' && '$WG_ROOT/bin/wingroup-hook' <'$WG_TMP/payload.json'"
  [ "$status" -eq 0 ]
  [ "$(recorded cwd)" = "$WG_SESSION_CWD" ]
}

# Without a scope there is no join key, so an entry could never be matched to
# an oom-kill line -- an ssh login or a test runner has no business in the map.
@test "a shell outside a systemd scope records nothing" {
  printf '0::/user.slice/user-1000.slice/session-3.scope/init\n' >"$WG_PROC_DIR/self/cgroup"
  hook '{"session_id":"abc","cwd":"/home/dev/projects/shop-web"}'
  [ "$status" -eq 0 ]
  [ "$(jq '.sessions | length' <<<"$(wg_sessions_read)")" -eq 0 ]
}

# The point of the whole arrangement: the scan cannot know a session id, so it
# must never overwrite the one the hook was told.
@test "a later scan does not blank the id the hook recorded" {
  hook '{"session_id":"11111111-2222","cwd":"/home/dev/projects/shop-web"}'
  wg_fake_proc 1001 claude "$WG_SCOPE" "$WG_TMP/projects/shop-web-live"
  run wg_sessions_scan
  [ "$output" -eq 1 ]
  [ "$(recorded session)" = "11111111-2222" ]
  [ "$(recorded source)" = "hook" ]
  # The cwd is the scan's, though: that one the scan does know, and a session
  # that has been cd'd since it started is somewhere new.
  [ "$(recorded cwd)" = "$WG_TMP/projects/shop-web-live" ]
}
