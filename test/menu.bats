#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
  source "$WG_ROOT/lib/hypr.sh"
  source "$WG_ROOT/lib/state.sh"
  source "$WG_ROOT/lib/resolve.sh"
  source "$WG_ROOT/lib/menu.sh"
  wg_stub_cwd
  export WG_WALKER="$WG_ROOT/test/bin/walker-stub"
}

teardown() { wg_teardown_tmp; }

@test "the menu opens with one entry per group, in state order" {
  count="$(wg_menu_build | grep -c '^group:')"
  [ "$count" -eq 3 ]
  first="$(wg_menu_build | head -n1 | cut -f1)"
  [ "$first" = "group:everest" ]
}

@test "a group entry shows its window and busy counts" {
  display="$(wg_menu_build | head -n1 | cut -f2)"
  [[ "$display" == *"everest"* ]]
  [[ "$display" == *"2 windows"* ]]
  [[ "$display" == *"1 busy"* ]]
}

@test "the menu lists every window" {
  count="$(wg_menu_build | grep -c '^window:')"
  [ "$count" -eq 7 ]
}

@test "a window entry uses the stripped title and names its group" {
  display="$(wg_menu_build | grep '^window:0xaaa1' | cut -f2)"
  [[ "$display" == *"Everest-web full redesign"* ]]
  [[ "$display" != *"✳ ✳"* ]]
  [[ "$display" == *"everest"* ]]
}

@test "an ungrouped window says so" {
  display="$(wg_menu_build | grep '^window:0xaaa6' | cut -f2)"
  [[ "$display" == *"ungrouped"* ]]
}

@test "the menu ends with the three action entries" {
  actions="$(wg_menu_build | tail -n3 | cut -f1 | tr '\n' ' ')"
  [ "$actions" = "new tidy toggle-auto " ]
}

@test "the auto entry reflects the current setting" {
  display="$(wg_menu_build | grep '^toggle-auto' | cut -f2)"
  [[ "$display" == *"on"* ]]
  wg_state_write "$(jq '.auto = false' "$WG_STATE_DIR/state.json")"
  display="$(wg_menu_build | grep '^toggle-auto' | cut -f2)"
  [[ "$display" == *"off"* ]]
}

@test "wg_group_menu_build offers only groups and a way to make a new one" {
  groups="$(wg_group_menu_build | cut -f1 | tr '\n' ' ')"
  [ "$groups" = "group:everest group:plat group:drivora new " ]
}

@test "wg_menu_run returns the action at the index walker chose" {
  export WG_WALKER_PICK=1
  action="$(wg_group_menu_build | wg_menu_run 'Group')"
  [ "$action" = "group:plat" ]
}

@test "wg_menu_run returns nothing when walker is cancelled" {
  export WG_WALKER_PICK=""
  action="$(wg_group_menu_build | wg_menu_run 'Group')"
  [ "$action" = "" ]
}

@test "wg_menu_run ignores an out-of-range index" {
  export WG_WALKER_PICK=99
  action="$(wg_group_menu_build | wg_menu_run 'Group')"
  [ "$action" = "" ]
}
