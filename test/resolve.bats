#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  source "$WG_ROOT/lib/hypr.sh"
  source "$WG_ROOT/lib/state.sh"
  source "$WG_ROOT/lib/resolve.sh"
  wg_stub_cwd
  wg_seed_state
}

teardown() { wg_teardown_tmp; }

@test "wg_cwd_project reads a plain project directory" {
  run wg_cwd_project /home/dev/projects/shop-web
  [ "$output" = "shop-web" ]
}

@test "wg_cwd_project reads a subdirectory of a project" {
  run wg_cwd_project /home/dev/projects/shop-web/src/lib
  [ "$output" = "shop-web" ]
}

@test "wg_cwd_project collapses a claude worktree to its repo" {
  run wg_cwd_project /home/dev/projects/site-platform/.claude/worktrees/spec-draft
  [ "$output" = "site-platform" ]
}

@test "wg_cwd_project returns empty for home, for the projects dir itself, and for outside paths" {
  run wg_cwd_project /home/dev
  [ "$output" = "" ]
  run wg_cwd_project /home/dev/projects
  [ "$output" = "" ]
  run wg_cwd_project /etc
  [ "$output" = "" ]
  run wg_cwd_project ""
  [ "$output" = "" ]
}

@test "wg_cwd_worktree extracts the worktree name only when there is one" {
  run wg_cwd_worktree /home/dev/projects/site-platform/.claude/worktrees/spec-draft
  [ "$output" = "spec-draft" ]
  run wg_cwd_worktree /home/dev/projects/site-platform/.claude/worktrees/spec-draft/src
  [ "$output" = "spec-draft" ]
  run wg_cwd_worktree /home/dev/projects/shop-web
  [ "$output" = "" ]
}

@test "wg_project_group maps every project of a multi-project group" {
  run wg_project_group shop-web
  [ "$output" = "shop" ]
  run wg_project_group shop-core
  [ "$output" = "shop" ]
  run wg_project_group shop-api
  [ "$output" = "shop" ]
  run wg_project_group site-platform
  [ "$output" = "site" ]
}

@test "wg_project_group returns empty for an unmapped project" {
  run wg_project_group some-other-repo
  [ "$output" = "" ]
}

@test "wg_window_group prefers an override over project resolution" {
  run wg_window_group 0xaaa3 shop-api
  [ "$output" = "site" ]
}

@test "wg_window_group falls back to the project when there is no override" {
  run wg_window_group 0xaaa1 shop-web
  [ "$output" = "shop" ]
}

@test "wg_window_group returns empty with no override and no project" {
  run wg_window_group 0xaaa6 ""
  [ "$output" = "" ]
}

@test "wg_title_status classifies every known glyph" {
  run wg_title_status "✳ Everest-web full redesign"
  [ "$output" = "idle" ]
  run wg_title_status "◐ CMS preview 503 error"
  [ "$output" = "busy" ]
  run wg_title_status "◑ Sentry errors review"
  [ "$output" = "busy" ]
}

@test "wg_title_status degrades unknown and absent glyphs to plain" {
  run wg_title_status "dev@host:~"
  [ "$output" = "plain" ]
  run wg_title_status "⏳ some future glyph"
  [ "$output" = "plain" ]
  run wg_title_status ""
  [ "$output" = "plain" ]
}

@test "wg_title_text strips the status glyph but leaves plain titles alone" {
  run wg_title_text "✳ Everest-web full redesign"
  [ "$output" = "Everest-web full redesign" ]
  run wg_title_text "dev@host:~"
  [ "$output" = "dev@host:~" ]
}

@test "wg_window_table emits one row per window" {
  output="$(wg_window_table | wc -l)"
  [ "$output" -eq 7 ]
}

@test "wg_window_table resolves a worktree window" {
  output="$(wg_window_table | awk -F'\t' '$1=="0xaaa2"{print $5, $6, $7, $8}')"
  [ "$output" = "shop busy shop-core price-units" ]
}

@test "wg_window_table honours an override" {
  output="$(wg_window_table | awk -F'\t' '$1=="0xaaa3"{print $5, $7}')"
  [ "$output" = "site shop-api" ]
}

@test "wg_window_table leaves a projectless window ungrouped" {
  output="$(wg_window_table | awk -F'\t' '$1=="0xaaa6"{print "[" $5 "]" $6}')"
  [ "$output" = "[]plain" ]
}

@test "wg_window_table marks the floating window" {
  output="$(wg_window_table | awk -F'\t' '$1=="0xaaa7"{print $4}')"
  [ "$output" = "true" ]
}

@test "wg_window_row returns exactly one row, or nothing for an unknown address" {
  output="$(wg_window_row 0xaaa1 | wc -l)"
  [ "$output" -eq 1 ]
  output="$(wg_window_row 0xdead | wc -c)"
  [ "$output" -eq 0 ]
}

@test "wg_window_row returns the same row the full table has for that address" {
  local from_table from_row
  from_table="$(wg_window_table | awk -F'\t' '$1 == "0xaaa2"')"
  from_row="$(wg_window_row 0xaaa2)"
  [ "$from_row" = "$from_table" ]
}

# The row is filtered by address before the table is built, not after: one row
# costs one cwd resolution, not one per open window.
@test "wg_window_row resolves only the address it was asked for" {
  export WG_CWD_LOG="$WG_TMP/cwd.log"
  : >"$WG_CWD_LOG"
  wg_window_row 0xaaa1 >/dev/null
  run bash -c "wc -l <'$WG_CWD_LOG'"
  [ "$output" -eq 1 ]
  run bash -c "cat '$WG_CWD_LOG'"
  [ "$output" = "1001" ]
}

# The picker took 1.6 seconds to appear on a 15-window desktop because
# wg_window_table asked the state two questions per window through jq: an
# override lookup and a project lookup, about thirty processes. Both maps are
# now built once per table build, so the count is flat in the number of windows
# -- three for the seven-window fixture set (state read, the maps, the client
# list), where the old code spent sixteen.
@test "a table build spawns a handful of jq processes, not two per window" {
  wg_count_jq
  wg_window_table >/dev/null
  run jq_calls
  [ "$output" -lt 8 ]
}

@test "the jq count does not grow with the number of windows" {
  local one_client seven
  one_client="$(jq '[.[0]]' "$WG_FIXTURES/clients.json")"
  wg_count_jq
  wg_window_table >/dev/null
  seven="$(jq_calls)"
  : >"$WG_JQ_LOG"
  wg_window_table "$one_client" >/dev/null
  [ "$seven" -eq "$(jq_calls)" ]
}

# One row is one cwd resolution, and one process-table walk for it -- not one
# per window on screen.
@test "a table build reads the process table once, not once per window" {
  local calls
  calls="$(WG_CHILDREN_LOADED=0
    wg_children_load() { WG_CHILDREN_LOADED=1; printf 'walk\n' >>"$WG_TMP/ps.log"; }
    : >"$WG_TMP/ps.log"
    wg_window_table >/dev/null
    wc -l <"$WG_TMP/ps.log")"
  [ "$calls" -eq 1 ]
}

@test "wg_row_split keeps every column in place when interior columns are empty" {
  wg_row_split "$(printf '0xaaa1\t1001\t1\tfalse\t\tplain\t\t\t✳ a\tb')"
  [ "${WG_ROW[1]}" = "0xaaa1" ]
  [ "${WG_ROW[4]}" = "false" ]
  [ "${WG_ROW[5]}" = "" ]
  [ "${WG_ROW[6]}" = "plain" ]
  [ "${WG_ROW[7]}" = "" ]
  [ "${WG_ROW[8]}" = "" ]
  # Column 9 is the title, and it keeps whatever tabs it arrived with.
  [ "${WG_ROW[9]}" = "$(printf '✳ a\tb')" ]
}

@test "wg_window_row for an unknown address resolves nothing at all" {
  export WG_CWD_LOG="$WG_TMP/cwd.log"
  : >"$WG_CWD_LOG"
  wg_window_row 0xdead >/dev/null
  [ ! -s "$WG_CWD_LOG" ]
}
