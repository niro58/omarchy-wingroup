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
  run wg_cwd_project /home/niro/projects/everest-web
  [ "$output" = "everest-web" ]
}

@test "wg_cwd_project reads a subdirectory of a project" {
  run wg_cwd_project /home/niro/projects/everest-web/src/lib
  [ "$output" = "everest-web" ]
}

@test "wg_cwd_project collapses a claude worktree to its repo" {
  run wg_cwd_project /home/niro/projects/niro-platform/.claude/worktrees/connectors-spec
  [ "$output" = "niro-platform" ]
}

@test "wg_cwd_project returns empty for home, for the projects dir itself, and for outside paths" {
  run wg_cwd_project /home/niro
  [ "$output" = "" ]
  run wg_cwd_project /home/niro/projects
  [ "$output" = "" ]
  run wg_cwd_project /etc
  [ "$output" = "" ]
  run wg_cwd_project ""
  [ "$output" = "" ]
}

@test "wg_cwd_worktree extracts the worktree name only when there is one" {
  run wg_cwd_worktree /home/niro/projects/niro-platform/.claude/worktrees/connectors-spec
  [ "$output" = "connectors-spec" ]
  run wg_cwd_worktree /home/niro/projects/niro-platform/.claude/worktrees/connectors-spec/src
  [ "$output" = "connectors-spec" ]
  run wg_cwd_worktree /home/niro/projects/everest-web
  [ "$output" = "" ]
}

@test "wg_project_group maps every project of a multi-project group" {
  run wg_project_group everest-web
  [ "$output" = "everest" ]
  run wg_project_group everest-rs
  [ "$output" = "everest" ]
  run wg_project_group everest-api
  [ "$output" = "everest" ]
  run wg_project_group niro-platform
  [ "$output" = "plat" ]
}

@test "wg_project_group returns empty for an unmapped project" {
  run wg_project_group some-other-repo
  [ "$output" = "" ]
}

@test "wg_window_group prefers an override over project resolution" {
  run wg_window_group 0xaaa3 everest-api
  [ "$output" = "plat" ]
}

@test "wg_window_group falls back to the project when there is no override" {
  run wg_window_group 0xaaa1 everest-web
  [ "$output" = "everest" ]
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
  run wg_title_status "niro@niro:~"
  [ "$output" = "plain" ]
  run wg_title_status "⏳ some future glyph"
  [ "$output" = "plain" ]
  run wg_title_status ""
  [ "$output" = "plain" ]
}

@test "wg_title_text strips the status glyph but leaves plain titles alone" {
  run wg_title_text "✳ Everest-web full redesign"
  [ "$output" = "Everest-web full redesign" ]
  run wg_title_text "niro@niro:~"
  [ "$output" = "niro@niro:~" ]
}

@test "wg_window_table emits one row per window" {
  run bash -c "wg_window_table | wc -l"
  [ "$output" -eq 7 ]
}

@test "wg_window_table resolves a worktree window" {
  run bash -c "wg_window_table | awk -F'\t' '\$1==\"0xaaa2\"{print \$5, \$6, \$7, \$8}'"
  [ "$output" = "everest busy everest-rs odtah-price" ]
}

@test "wg_window_table honours an override" {
  run bash -c "wg_window_table | awk -F'\t' '\$1==\"0xaaa3\"{print \$5, \$7}'"
  [ "$output" = "plat everest-api" ]
}

@test "wg_window_table leaves a projectless window ungrouped" {
  run bash -c "wg_window_table | awk -F'\t' '\$1==\"0xaaa6\"{print \"[\" \$5 \"]\" \$6}'"
  [ "$output" = "[]plain" ]
}

@test "wg_window_table marks the floating window" {
  run bash -c "wg_window_table | awk -F'\t' '\$1==\"0xaaa7\"{print \$4}'"
  [ "$output" = "true" ]
}

@test "wg_window_row returns exactly one row, or nothing for an unknown address" {
  run bash -c "wg_window_row 0xaaa1 | wc -l"
  [ "$output" -eq 1 ]
  run bash -c "wg_window_row 0xdead | wc -c"
  [ "$output" -eq 0 ]
}
