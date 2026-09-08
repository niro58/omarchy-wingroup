#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  export WG_WALKER="$WG_ROOT/test/bin/walker-stub"
}

teardown() { wg_teardown_tmp; }

wingroup() { "$WG_ROOT/bin/wingroup" "$@"; }

@test "activate by name switches to the group workspace" {
  wingroup activate everest
  [ "$(dispatches)" = "workspace name:everest" ]
}

@test "activate by slot index switches to that group" {
  wingroup activate 1
  [ "$(dispatches)" = "workspace name:plat" ]
}

@test "activate rejects an unknown group without dispatching" {
  run wingroup activate nosuch
  [ "$status" -ne 0 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "next moves to the first group when the focus is not on a group" {
  wingroup next
  [ "$(dispatches)" = "workspace name:everest" ]
}

@test "next advances from the focused group" {
  export WG_FIXTURE_ACTIVEWS="$WG_FIXTURES/activeworkspace-everest.json"
  wingroup next
  [ "$(dispatches)" = "workspace name:plat" ]
}

@test "prev wraps around from the first group to the last" {
  export WG_FIXTURE_ACTIVEWS="$WG_FIXTURES/activeworkspace-everest.json"
  wingroup prev
  [ "$(dispatches)" = "workspace name:drivora" ]
}

@test "new creates a group with a slugified name and the given projects" {
  wingroup new "Niro 3D Print" niro-3dprint-app niro-3dprint-web
  run bash -c "jq -r '.groups[-1].name' '$WG_STATE_DIR/state.json'"
  [ "$output" = "niro-3d-print" ]
  run bash -c "jq -r '.groups[-1].label' '$WG_STATE_DIR/state.json'"
  [ "$output" = "Niro 3D Print" ]
  run bash -c "jq -r '.groups[-1].projects | join(\",\")' '$WG_STATE_DIR/state.json'"
  [ "$output" = "niro-3dprint-app,niro-3dprint-web" ]
}

@test "new refuses a duplicate group name" {
  run wingroup new everest
  [ "$status" -ne 0 ]
}

@test "rename changes the label and leaves the workspace name alone" {
  wingroup rename everest "EV stack"
  run bash -c "jq -r '.groups[0].label' '$WG_STATE_DIR/state.json'"
  [ "$output" = "EV stack" ]
  run bash -c "jq -r '.groups[0].name' '$WG_STATE_DIR/state.json'"
  [ "$output" = "everest" ]
}

@test "dissolve removes the group and never touches a window" {
  wingroup dissolve plat
  run bash -c "jq -r '[.groups[].name] | join(\",\")' '$WG_STATE_DIR/state.json'"
  [ "$output" = "everest,drivora" ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "send writes an override and moves the window" {
  wingroup send --address 0xaaa1 --group plat
  run bash -c "jq -r '.overrides[\"0xaaa1\"]' '$WG_STATE_DIR/state.json'"
  [ "$output" = "plat" ]
  [ "$(dispatches)" = "movetoworkspacesilent name:plat,address:0xaaa1" ]
}

@test "send refuses an unknown group" {
  run wingroup send --address 0xaaa1 --group nosuch
  [ "$status" -ne 0 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "tidy files every misplaced window and skips overrides, floats and strays" {
  wingroup tidy --yes
  run bash -c "wc -l <'$WG_DISPATCH_LOG'"
  [ "$output" -eq 4 ]
  run bash -c "grep -c '0xaaa3' '$WG_DISPATCH_LOG' || true"
  [ "$output" -eq 0 ]
  run bash -c "grep -c '0xaaa7' '$WG_DISPATCH_LOG' || true"
  [ "$output" -eq 0 ]
}

# Regression test for the tab-collapsing defect: wg_tidy_moves used to read
# the nine-column window table with a multi-variable `IFS=$'\t' read`, which
# collapses the empty interior `group` column for an ungrouped window and
# shifts `status` ("plain") into `$group`. That made tidy try to move
# ungrouped windows to a workspace literally named "plain".
@test "tidy never moves the ungrouped window, and never targets a workspace called plain" {
  wingroup tidy --yes
  run bash -c "grep -c '0xaaa6' '$WG_DISPATCH_LOG' || true"
  [ "$output" -eq 0 ]
  run bash -c "grep -c 'name:plain' '$WG_DISPATCH_LOG' || true"
  [ "$output" -eq 0 ]
}

@test "tidy without --yes dispatches nothing when the confirmation is cancelled" {
  export WG_WALKER_PICK=""
  wingroup tidy
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "toggle-auto flips the setting" {
  wingroup toggle-auto
  run bash -c "jq -r '.auto' '$WG_STATE_DIR/state.json'"
  [ "$output" = "false" ]
  wingroup toggle-auto
  run bash -c "jq -r '.auto' '$WG_STATE_DIR/state.json'"
  [ "$output" = "true" ]
}

@test "menu activates the group the picker returned" {
  export WG_WALKER_PICK=1
  wingroup menu
  [ "$(dispatches)" = "workspace name:plat" ]
}

@test "menu focuses the window the picker returned" {
  export WG_WALKER_PICK=5
  wingroup menu
  [[ "$(dispatches)" == focuswindow* ]]
}

@test "an unknown subcommand exits non-zero with usage" {
  run wingroup wat
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}
