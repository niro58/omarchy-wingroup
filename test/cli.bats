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

# SUPER+G pressed twice, or the keybind and the bar's right-click together,
# must not stack two pickers on the screen.
@test "menu does nothing, quietly, while another picker holds the lock" {
  export WG_WALKER_PICK=1
  exec 9>"$XDG_RUNTIME_DIR/wingroup-menu.lock"
  flock -n 9
  run wingroup menu
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ ! -s "$WG_DISPATCH_LOG" ]
  exec 9>&-
}

@test "menu runs again once the first picker has let the lock go" {
  export WG_WALKER_PICK=1
  exec 9>"$XDG_RUNTIME_DIR/wingroup-menu.lock"
  flock -n 9
  exec 9>&-
  wingroup menu
  [ "$(dispatches)" = "workspace name:plat" ]
}

# Three groups, then new/tidy/toggle-auto, then the separator: the first window
# is index 7 now that the actions no longer sit at the bottom of the list.
@test "menu focuses the window the picker returned" {
  export WG_WALKER_PICK=7
  wingroup menu
  [[ "$(dispatches)" == focuswindow* ]]
}

# --- the picker's "+ new group…", which used to be a dead entry ---

@test "the picker's new-group entry creates the group from what was typed" {
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT="Niro 3D Print"
  wingroup menu
  run bash -c "jq -r '.groups[-1].name' '$WG_STATE_DIR/state.json'"
  [ "$output" = "niro-3d-print" ]
  run bash -c "jq -r '.groups[-1].label' '$WG_STATE_DIR/state.json'"
  [ "$output" = "Niro 3D Print" ]
}

# A group with no projects files nothing, so the entry would still leave the
# user with work to do. The window in front of them is the obvious first
# project, and wanting a group for it is why they reached for the entry.
@test "the new group picks up the focused window's project when nothing owns it" {
  wg_patch_state '.groups[0].projects = ["everest-rs", "everest-api"]'
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT="Web"
  wingroup menu
  run bash -c "jq -r '.groups[-1].projects | join(\",\")' '$WG_STATE_DIR/state.json'"
  [ "$output" = "everest-web" ]
  [[ "$(notifications)" == *"everest-web"* ]]
}

@test "the new group takes no project when another group already owns it" {
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT="Web"
  wingroup menu
  run bash -c "jq -r '.groups[-1].projects | length' '$WG_STATE_DIR/state.json'"
  [ "$output" -eq 0 ]
  [[ "$(notifications)" == *"already belongs to everest"* ]]
}

@test "the new group takes no project when the focused window is in none" {
  export WG_FIXTURE_ACTIVEWINDOW="$WG_FIXTURES/activewindow-ungrouped.json"
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT="Scratch"
  wingroup menu
  run bash -c "jq -r '.groups[-1].name' '$WG_STATE_DIR/state.json'"
  [ "$output" = "scratch" ]
  run bash -c "jq -r '.groups[-1].projects | length' '$WG_STATE_DIR/state.json'"
  [ "$output" -eq 0 ]
  [[ "$(notifications)" == *"not in a project"* ]]
}

@test "the new group is created with no projects when there is no focused window" {
  export WG_FIXTURE_ACTIVEWINDOW="$WG_FIXTURES/activewindow-none.json"
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT="Scratch"
  wingroup menu
  run bash -c "jq -r '.groups[-1].projects | length' '$WG_STATE_DIR/state.json'"
  [ "$output" -eq 0 ]
}

@test "cancelling the new-group prompt creates nothing and says nothing" {
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT=""
  run wingroup menu
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.groups | length' '$WG_STATE_DIR/state.json'"
  [ "$output" -eq 3 ]
  [ ! -s "$WG_NOTIFY_LOG" ]
}

@test "the new-group entry rejects a duplicate exactly as wingroup new does" {
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT="everest"
  run wingroup menu
  [ "$status" -ne 0 ]
  run bash -c "jq -r '.groups | length' '$WG_STATE_DIR/state.json'"
  [ "$output" -eq 3 ]
}

# --- failures from a keybind-launched picker have to be visible ---

# stderr goes nowhere when SUPER+G is what started the process, so a failure
# there used to look exactly like an entry that did nothing.
@test "a failure with no terminal is sent to the notification daemon as well as stderr" {
  run wingroup activate nosuch
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such group: nosuch"* ]]
  [[ "$(notifications)" == *"no such group: nosuch"* ]]
}

@test "the picker's own failures reach the notification daemon" {
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT="everest"
  run wingroup menu
  [ "$status" -ne 0 ]
  [[ "$(notifications)" == *"group already exists: everest"* ]]
}

# At a terminal the message is already in front of the user; a desktop
# notification on top of it is noise.
@test "a failure at a terminal stays on stderr and notifies nobody" {
  command -v script >/dev/null 2>&1 || skip "util-linux script is not installed"
  run script -qec "'$WG_ROOT/bin/wingroup' activate nosuch" /dev/null
  [ "$status" -ne 0 ]
  [[ "$output" == *"no such group: nosuch"* ]]
  [ ! -s "$WG_NOTIFY_LOG" ]
}

# --- pinning a group to a monitor ---

@test "monitor pins a group to a monitor that exists" {
  wingroup monitor everest DP-1
  run bash -c "jq -r '.groups[0].monitor' '$WG_STATE_DIR/state.json'"
  [ "$output" = "DP-1" ]
}

@test "monitor - clears the pin" {
  wingroup monitor everest DP-1
  wingroup monitor everest -
  run bash -c "jq -r '.groups[0].monitor' '$WG_STATE_DIR/state.json'"
  [ "$output" = "null" ]
}

@test "monitor refuses a monitor that does not exist, and lists the ones that do" {
  run wingroup monitor everest HDMI-9
  [ "$status" -ne 0 ]
  [[ "$output" == *"HDMI-9"* ]]
  [[ "$output" == *"eDP-2, DP-1"* ]]
  run bash -c "jq -r '.groups[0].monitor' '$WG_STATE_DIR/state.json'"
  [ "$output" = "null" ]
}

@test "monitor refuses an unknown group" {
  run wingroup monitor nosuch DP-1
  [ "$status" -ne 0 ]
}

# Hyprland binds a named workspace to whichever monitor was focused when it was
# first created, and leaves it there. Focusing the pinned monitor is therefore
# not enough on its own -- without the move, a group first opened on the laptop
# stays on the laptop forever, and the pin does nothing at all.
@test "activate on a pinned group focuses the monitor and drags the workspace over" {
  wg_patch_state '.groups[0].monitor = "DP-1"'
  wingroup activate everest
  run dispatches
  [ "${lines[0]}" = "focusmonitor DP-1" ]
  [ "${lines[1]}" = "moveworkspacetomonitor name:everest DP-1" ]
  [ "${lines[2]}" = "workspace name:everest" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "activate does not move a workspace that is already on its pinned monitor" {
  wg_patch_state '.groups[1].monitor = "DP-1"'
  wingroup activate plat
  run dispatches
  [ "${lines[0]}" = "focusmonitor DP-1" ]
  [ "${lines[1]}" = "workspace name:plat" ]
  [ "${#lines[@]}" -eq 2 ]
  run bash -c "grep -c moveworkspacetomonitor '$WG_DISPATCH_LOG' || true"
  [ "$output" -eq 0 ]
}

# A workspace that has never existed has no monitor to be moved off, and gets
# created on the monitor that was just focused.
@test "activate on a pinned group whose workspace does not exist yet only focuses and switches" {
  wg_patch_state '.groups[2].monitor = "DP-1"'
  wingroup activate drivora
  run dispatches
  [ "${lines[0]}" = "focusmonitor DP-1" ]
  [ "${lines[1]}" = "workspace name:drivora" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "activate on an unpinned group touches no monitor, even beside a pinned one" {
  wg_patch_state '.groups[1].monitor = "DP-1"'
  wingroup activate everest
  [ "$(dispatches)" = "workspace name:everest" ]
}

@test "an unknown subcommand exits non-zero with usage" {
  run wingroup wat
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}
