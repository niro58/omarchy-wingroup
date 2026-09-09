#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  source "$WG_ROOT/lib/hypr.sh"
}

teardown() { wg_teardown_tmp; }

@test "wg_hypr_query returns the clients fixture as JSON" {
  run wg_hypr_query clients
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" -eq 7 ]
}

@test "wg_hypr_query reads the active workspace" {
  run wg_hypr_query activeworkspace
  [ "$status" -eq 0 ]
  [ "$(jq -r '.name' <<<"$output")" = "1" ]
}

@test "wg_hypr_dispatch records the dispatch instead of running it" {
  wg_hypr_dispatch movetoworkspacesilent "name:shop,address:0xaaa1"
  [ "$(dispatches)" = "movetoworkspacesilent name:shop,address:0xaaa1" ]
}

@test "wg_hypr_query lists every monitor and the workspace on it" {
  run wg_hypr_query monitors
  [ "$status" -eq 0 ]
  [ "$(jq 'length' <<<"$output")" -eq 2 ]
  [ "$(jq -r 'map(.activeWorkspace.name) | join(",")' <<<"$output")" = "3,template" ]
  [ "$(jq -r 'first(.[] | select(.focused) | .name)' <<<"$output")" = "DP-1" ]
}

@test "wg_hypr_query fails loudly on an unhandled query" {
  run wg_hypr_query devices
  [ "$status" -ne 0 ]
}
