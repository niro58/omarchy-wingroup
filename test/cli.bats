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
  wingroup activate shop
  [ "$(dispatches)" = "workspace name:shop" ]
}

@test "activate by slot index switches to that group" {
  wingroup activate 1
  [ "$(dispatches)" = "workspace name:site" ]
}

@test "activate rejects an unknown group without dispatching" {
  run wingroup activate nosuch
  [ "$status" -ne 0 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "next moves to the first group when the focus is not on a group" {
  wingroup next
  [ "$(dispatches)" = "workspace name:shop" ]
}

@test "next advances from the focused group" {
  export WG_FIXTURE_ACTIVEWS="$WG_FIXTURES/activeworkspace-shop.json"
  wingroup next
  [ "$(dispatches)" = "workspace name:site" ]
}

@test "prev wraps around from the first group to the last" {
  export WG_FIXTURE_ACTIVEWS="$WG_FIXTURES/activeworkspace-shop.json"
  wingroup prev
  [ "$(dispatches)" = "workspace name:fleet" ]
}

@test "new creates a group with a slugified name and the given projects" {
  wingroup new "Acme 3D Print" acme-3d-app acme-3d-web
  run bash -c "jq -r '.groups[-1].name' '$WG_STATE_DIR/state.json'"
  [ "$output" = "acme-3d-print" ]
  run bash -c "jq -r '.groups[-1].label' '$WG_STATE_DIR/state.json'"
  [ "$output" = "Acme 3D Print" ]
  run bash -c "jq -r '.groups[-1].projects | join(\",\")' '$WG_STATE_DIR/state.json'"
  [ "$output" = "acme-3d-app,acme-3d-web" ]
}

@test "new refuses a duplicate group name" {
  run wingroup new shop
  [ "$status" -ne 0 ]
}

@test "rename changes the label and leaves the workspace name alone" {
  wingroup rename shop "EV stack"
  run bash -c "jq -r '.groups[0].label' '$WG_STATE_DIR/state.json'"
  [ "$output" = "EV stack" ]
  run bash -c "jq -r '.groups[0].name' '$WG_STATE_DIR/state.json'"
  [ "$output" = "shop" ]
}

@test "dissolve removes the group and never touches a window" {
  wingroup dissolve site
  run bash -c "jq -r '[.groups[].name] | join(\",\")' '$WG_STATE_DIR/state.json'"
  [ "$output" = "shop,fleet" ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "send writes an override and moves the window" {
  wingroup send --address 0xaaa1 --group site
  run bash -c "jq -r '.overrides[\"0xaaa1\"]' '$WG_STATE_DIR/state.json'"
  [ "$output" = "site" ]
  [ "$(dispatches)" = "movetoworkspacesilent name:site,address:0xaaa1" ]
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
  [ "$(dispatches)" = "workspace name:site" ]
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
  [ "$(dispatches)" = "workspace name:site" ]
}

# Three groups, then new/delete/tidy/toggle-auto, then the separator: the first
# window is index 8 now that the actions no longer sit at the bottom of the list.
@test "menu focuses the window the picker returned" {
  export WG_WALKER_PICK=8
  wingroup menu
  [[ "$(dispatches)" == focuswindow* ]]
}

# --- the picker's "+ new group…", which used to be a dead entry ---

@test "the picker's new-group entry creates the group from what was typed" {
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT="Acme 3D Print"
  wingroup menu
  run bash -c "jq -r '.groups[-1].name' '$WG_STATE_DIR/state.json'"
  [ "$output" = "acme-3d-print" ]
  run bash -c "jq -r '.groups[-1].label' '$WG_STATE_DIR/state.json'"
  [ "$output" = "Acme 3D Print" ]
}

# A group with no projects files nothing, so the entry would still leave the
# user with work to do. The window in front of them is the obvious first
# project, and wanting a group for it is why they reached for the entry.
@test "the new group picks up the focused window's project when nothing owns it" {
  wg_patch_state '.groups[0].projects = ["shop-core", "shop-api"]'
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT="Web"
  wingroup menu
  run bash -c "jq -r '.groups[-1].projects | join(\",\")' '$WG_STATE_DIR/state.json'"
  [ "$output" = "shop-web" ]
  [[ "$(notifications)" == *"shop-web"* ]]
}

@test "the new group takes no project when another group already owns it" {
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT="Web"
  wingroup menu
  run bash -c "jq -r '.groups[-1].projects | length' '$WG_STATE_DIR/state.json'"
  [ "$output" -eq 0 ]
  [[ "$(notifications)" == *"already belongs to shop"* ]]
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
  export WG_WALKER_INPUT="shop"
  run wingroup menu
  [ "$status" -ne 0 ]
  run bash -c "jq -r '.groups | length' '$WG_STATE_DIR/state.json'"
  [ "$output" -eq 3 ]
}

# --- a group that counts a window has to be one that holds it ---

# The complaint this answers, verbatim: "if counts on window it should actually
# move to it not just group". A new group owning a project whose windows were
# open elsewhere showed them in its count and on the bar, then activating it
# showed an empty workspace, because nothing ever moved them.
@test "new files the windows its projects already own onto its workspace" {
  wg_patch_state '.groups |= map(select(.name != "shop"))'
  wingroup new shop shop-web shop-core shop-api
  run dispatches
  [ "${lines[0]}" = "movetoworkspacesilent name:shop,address:0xaaa1" ]
  [ "${lines[1]}" = "movetoworkspacesilent name:shop,address:0xaaa2" ]
  [ "${#lines[@]}" -eq 2 ]
}

# 0xaaa1 is already on the shop workspace, 0xaaa8 floats over shop-web,
# and 0xaaa3 was sent to site by hand. Filing is tidy's rules, narrowed to the
# new group -- so of the group's four windows only one is dispatched at.
@test "new moves nothing that is floating, already filed, or sent by hand" {
  export WG_FIXTURE_CLIENTS="$WG_FIXTURES/clients-new-group.json"
  wg_patch_state '.groups |= map(select(.name != "shop"))'
  wingroup new shop shop-web shop-core shop-api
  [ "$(dispatches)" = "movetoworkspacesilent name:shop,address:0xaaa2" ]
}

# A group with no projects owns no window yet, so there is nothing to file and
# no reason to go and build the window table to find that out.
@test "new with no projects moves nothing and asks the compositor for nothing" {
  export WG_HYPRCTL_LOG="$WG_TMP/hyprctl.log"
  wingroup new "Scratch"
  [ ! -s "$WG_DISPATCH_LOG" ]
  [ ! -s "$WG_HYPRCTL_LOG" ]
}

@test "new leaves the windows of every other group where they are" {
  wg_patch_state '.groups |= map(select(.name != "shop"))'
  wingroup new shop shop-web shop-core shop-api
  run bash -c "grep -c '0xaaa4\|0xaaa5' '$WG_DISPATCH_LOG' || true"
  [ "$output" -eq 0 ]
}

# The picker shares cmd_new, so it files too -- and says what it filed, since a
# picker action has no terminal to print to.
@test "the picker's new-group entry files the windows the group claims, and says so" {
  wg_patch_state '.groups |= map(select(.name != "shop"))'
  # Two groups left, so "+ new group…" is index 2.
  export WG_WALKER_PICK=2
  export WG_WALKER_INPUT="Shop"
  wingroup menu
  [ "$(dispatches)" = "movetoworkspacesilent name:shop,address:0xaaa1" ]
  [[ "$(notifications)" == *"Filed 1 window(s) onto it"* ]]
}

# --- removing a group from the picker ---

# dissolve has always existed, but only in a terminal: a group made by mistake
# from the picker could not be unmade from it. Pick the group, then confirm it.
@test "the picker removes the group that was chosen and confirmed" {
  export WG_WALKER_PICKS="4 1 1"
  wingroup menu
  run bash -c "jq -r '[.groups[].name] | join(\",\")' '$WG_STATE_DIR/state.json'"
  [ "$output" = "shop,fleet" ]
  [[ "$(notifications)" == *"Removed group site"* ]]
}

# dissolve's semantics, unchanged: the group and its overrides go, the windows
# stay exactly where they are.
@test "removing a group from the picker closes and moves no window" {
  export WG_WALKER_PICKS="4 1 1"
  wingroup menu
  [ ! -s "$WG_DISPATCH_LOG" ]
  run bash -c "jq -r '.overrides | length' '$WG_STATE_DIR/state.json'"
  [ "$output" -eq 0 ]
}

# A mis-click must not silently destroy a group, so the confirmation's first
# entry -- the one already under the cursor -- is the one that cancels.
@test "cancelling the confirmation leaves the group alone and says nothing" {
  export WG_WALKER_PICKS="4 1 0"
  wingroup menu
  run bash -c "jq -r '[.groups[].name] | join(\",\")' '$WG_STATE_DIR/state.json'"
  [ "$output" = "shop,site,fleet" ]
  [ ! -s "$WG_NOTIFY_LOG" ]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

@test "backing out of the group chooser removes nothing" {
  export WG_WALKER_PICKS="4"
  wingroup menu
  run bash -c "jq -r '.groups | length' '$WG_STATE_DIR/state.json'"
  [ "$output" -eq 3 ]
  [ ! -s "$WG_NOTIFY_LOG" ]
}

# With no groups the chooser would be empty, and an empty walker reads as a
# broken entry rather than as "nothing to do here".
@test "the remove entry says so when there are no groups at all" {
  wg_patch_state '.groups = []'
  export WG_WALKER_PICKS="1"
  wingroup menu
  [[ "$(notifications)" == *"no groups to remove"* ]]
  [ ! -s "$WG_DISPATCH_LOG" ]
}

# --- the send picker's "+ new group…" ---

# SUPER+CTRL+G's group chooser has always carried this entry, and it only ever
# printed "create the group first" at a terminal nobody was looking at.
@test "the send picker's new-group entry creates the group and sends the window to it" {
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT="Games"
  wingroup send --address 0xaaa1
  run bash -c "jq -r '.groups[-1].name' '$WG_STATE_DIR/state.json'"
  [ "$output" = "games" ]
  run bash -c "jq -r '.overrides[\"0xaaa1\"]' '$WG_STATE_DIR/state.json'"
  [ "$output" = "games" ]
  [ "$(dispatches)" = "movetoworkspacesilent name:games,address:0xaaa1" ]
}

@test "cancelling the send picker's prompt creates nothing and sends nothing" {
  export WG_WALKER_PICK=3
  export WG_WALKER_INPUT=""
  run wingroup send --address 0xaaa1
  [ "$status" -eq 0 ]
  run bash -c "jq -r '.groups | length' '$WG_STATE_DIR/state.json'"
  [ "$output" -eq 3 ]
  [ ! -s "$WG_DISPATCH_LOG" ]
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
  export WG_WALKER_INPUT="shop"
  run wingroup menu
  [ "$status" -ne 0 ]
  [[ "$(notifications)" == *"group already exists: shop"* ]]
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
  wingroup monitor shop DP-1
  run bash -c "jq -r '.groups[0].monitor' '$WG_STATE_DIR/state.json'"
  [ "$output" = "DP-1" ]
}

@test "monitor - clears the pin" {
  wingroup monitor shop DP-1
  wingroup monitor shop -
  run bash -c "jq -r '.groups[0].monitor' '$WG_STATE_DIR/state.json'"
  [ "$output" = "null" ]
}

@test "monitor refuses a monitor that does not exist, and lists the ones that do" {
  run wingroup monitor shop HDMI-9
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
  wingroup activate shop
  run dispatches
  [ "${lines[0]}" = "focusmonitor DP-1" ]
  [ "${lines[1]}" = "moveworkspacetomonitor name:shop DP-1" ]
  [ "${lines[2]}" = "workspace name:shop" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "activate does not move a workspace that is already on its pinned monitor" {
  wg_patch_state '.groups[1].monitor = "DP-1"'
  wingroup activate site
  run dispatches
  [ "${lines[0]}" = "focusmonitor DP-1" ]
  [ "${lines[1]}" = "workspace name:site" ]
  [ "${#lines[@]}" -eq 2 ]
  run bash -c "grep -c moveworkspacetomonitor '$WG_DISPATCH_LOG' || true"
  [ "$output" -eq 0 ]
}

# A workspace that has never existed has no monitor to be moved off, and gets
# created on the monitor that was just focused.
@test "activate on a pinned group whose workspace does not exist yet only focuses and switches" {
  wg_patch_state '.groups[2].monitor = "DP-1"'
  wingroup activate fleet
  run dispatches
  [ "${lines[0]}" = "focusmonitor DP-1" ]
  [ "${lines[1]}" = "workspace name:fleet" ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "activate on an unpinned group touches no monitor, even beside a pinned one" {
  wg_patch_state '.groups[1].monitor = "DP-1"'
  wingroup activate shop
  [ "$(dispatches)" = "workspace name:shop" ]
}

@test "an unknown subcommand exits non-zero with usage" {
  run wingroup wat
  [ "$status" -ne 0 ]
  [[ "$output" == *"usage"* ]]
}
