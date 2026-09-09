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

@test "a group entry shows its window, idle and busy counts" {
  display="$(wg_menu_build | head -n1 | cut -f2)"
  [[ "$display" == *"everest"* ]]
  [[ "$display" == *"2 windows"* ]]
  [[ "$display" == *"1 idle"* ]]
  [[ "$display" == *"1 busy"* ]]
}

# A plain terminal is neither idle nor busy, but it is still a window.
@test "a group entry counts a window with no Claude session as neither idle nor busy" {
  wg_patch_state '.overrides["0xaaa6"] = "everest"'
  display="$(wg_menu_build | head -n1 | cut -f2)"
  [[ "$display" == *"3 windows · 1 idle · 1 busy"* ]]
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

# Column 8 of the window table has held the worktree name since the first
# version and nothing displayed it. Two windows in different worktrees of the
# same repo resolve to the same project and so to the same group -- which is
# what filing them wants and no help at all in a list of rows all reading
# "plat".
@test "a window sitting in a worktree names it next to its group" {
  display="$(wg_menu_build | grep '^window:0xaaa2' | cut -f2)"
  [[ "$display" == *"everest:odtah-price"* ]]
}

@test "a window that is not in a worktree says nothing extra" {
  display="$(wg_menu_build | grep '^window:0xaaa1' | cut -f2)"
  [[ "$display" == *"everest"* ]]
  [[ "$display" != *"everest:"* ]]
}

# The whole point of the column: same repo, same project, same group, two rows
# that used to be indistinguishable.
@test "two windows in different worktrees of one repo are told apart" {
  wg_window_cwd() {
    case "$1" in
      1001) printf '%s\n' "$WG_PROJECTS_DIR/everest-web/.claude/worktrees/odtah-price" ;;
      1005) printf '%s\n' "$WG_PROJECTS_DIR/everest-web/.claude/worktrees/vat-rounding" ;;
      *) return 0 ;;
    esac
  }
  [[ "$(wg_menu_build | grep '^window:0xaaa1' | cut -f2)" == *"everest:odtah-price"* ]]
  [[ "$(wg_menu_build | grep '^window:0xaaa5' | cut -f2)" == *"everest:vat-rounding"* ]]
}

@test "wg_menu_where joins the group and the worktree, and falls back to ungrouped" {
  wg_menu_where plat connectors-spec
  [ "$WG_WHERE" = "plat:connectors-spec" ]
  wg_menu_where plat ""
  [ "$WG_WHERE" = "plat" ]
  wg_menu_where "" ""
  [ "$WG_WHERE" = "ungrouped" ]
}

# A worktree is named after a branch and a branch name has no upper bound. This
# is the last column of a row whose other columns are padded to fixed widths, so
# an unbounded field here is the one thing that can push the layout around.
@test "a long worktree name is cut down rather than allowed to stretch the row" {
  wg_menu_where plat "feat-connectors-spec-second-pass"
  [ "$WG_WHERE" = "plat:feat-connectors…" ]
  # Exactly at the limit, nothing is cut.
  wg_menu_where plat "sixteen-chars-ab"
  [ "$WG_WHERE" = "plat:sixteen-chars-ab" ]
}

@test "an ungrouped window says so" {
  display="$(wg_menu_build | grep '^window:0xaaa6' | cut -f2)"
  [[ "$display" == *"ungrouped"* ]]
}

# Order matters more than it looks. The actions used to sit below every window,
# which on a working desktop is some twenty rows down: far enough that
# "+ new group…" read as an entry the picker did not have. Groups stay first --
# switching to one is what SUPER+G is for -- and the actions come next.
@test "the picker lists groups, then the actions, then the windows" {
  actions="$(wg_menu_build | cut -f1 | sed 's/:.*//' | tr '\n' ' ')"
  [ "$actions" = "group group group new delete tidy toggle-auto noop window window window window window window window " ]
}

# The index walker returns is a position in this list, so the layout is a
# contract, not a presentation detail.
@test "the action entries follow the last group, at indices 3 to 6" {
  [ "$(wg_menu_build | sed -n '4p' | cut -f1)" = "new" ]
  [ "$(wg_menu_build | sed -n '5p' | cut -f1)" = "delete" ]
  [ "$(wg_menu_build | sed -n '6p' | cut -f1)" = "tidy" ]
  [ "$(wg_menu_build | sed -n '7p' | cut -f1)" = "toggle-auto" ]
  [ "$(wg_menu_build | sed -n '8p' | cut -f1)" = "noop" ]
  [ "$(wg_menu_build | sed -n '9p' | cut -f1)" = "window:0xaaa1" ]
}

# A group can be made from the picker; until now it could only be unmade from a
# terminal.
@test "the picker offers a way to remove a group" {
  display="$(wg_menu_build | grep '^delete\b' | cut -f2)"
  [[ "$display" == *"remove a group"* ]]
}

# state.json has carried a per-group monitor since the first version and
# nothing ever read it; a pin nobody can see is a pin nobody trusts.
@test "a group pinned to a monitor says so in its entry" {
  wg_patch_state '.groups[1].monitor = "DP-1"'
  display="$(wg_menu_build | grep '^group:plat' | cut -f2)"
  [[ "$display" == *"on DP-1"* ]]
}

@test "a group with no pin says nothing about monitors" {
  display="$(wg_menu_build | grep '^group:plat' | cut -f2)"
  [[ "$display" != *" on "* ]]
}

@test "wg_menu_input returns what was typed" {
  export WG_WALKER_INPUT="Niro 3D Print"
  [ "$(wg_menu_input 'New group')" = "Niro 3D Print" ]
}

@test "wg_menu_input returns nothing when the prompt is cancelled" {
  export WG_WALKER_INPUT=""
  [ "$(wg_menu_input 'New group')" = "" ]
}

@test "wg_menu_input trims what was typed, so spaces alone are nothing" {
  export WG_WALKER_INPUT="   "
  [ "$(wg_menu_input 'New group')" = "" ]
  export WG_WALKER_INPUT="  plat  "
  [ "$(wg_menu_input 'New group')" = "plat" ]
}

# Input-only mode is still dmenu mode, and it gets the same sizing and the same
# launcher treatment as the picker it is opened from.
@test "wg_menu_input asks walker for input-only dmenu mode, with the picker geometry" {
  export WG_WALKER_ARGS_LOG="$WG_TMP/walker-args"
  export WG_WALKER_INPUT="x"
  wg_menu_input 'New group' >/dev/null
  run cat "$WG_WALKER_ARGS_LOG"
  [ "$output" = "--width 644 --maxheight 300 --minheight 300 -d -I -p New group" ]
}

@test "on Omarchy the input prompt goes through omarchy-launch-walker too" {
  export WG_WALKER_ARGS_LOG="$WG_TMP/walker-args"
  export WG_WALKER_LAUNCHER="$WG_ROOT/test/bin/walker-launcher-stub"
  export WG_WALKER_INPUT="x"
  ln -sf "$WG_ROOT/test/bin/walker-stub" "$WG_TMP/walker"
  export PATH="$WG_TMP:$PATH"
  export WG_WALKER=walker
  [ "$(wg_menu_input 'New group')" = "x" ]
  run grep -c '^launcher -d -I -p New group$' "$WG_WALKER_ARGS_LOG"
  [ "$output" -eq 1 ]
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

# The chooser for removing a group: no "+ new group…" on it -- offering to make
# one there is noise, and one entry off is the wrong group gone.
@test "wg_group_list_build offers the groups and nothing else" {
  groups="$(wg_group_list_build | cut -f1 | tr '\n' ' ')"
  [ "$groups" = "group:everest group:plat group:drivora " ]
}

# Nothing is under the cursor by accident: the entry at index 0 is the one that
# does nothing.
@test "the delete confirmation puts cancel first and names the group" {
  run bash -c "cd '$WG_ROOT' && source lib/hypr.sh && source lib/state.sh \
    && source lib/resolve.sh && source lib/menu.sh && wg_delete_confirm_build plat plat"
  [ "${lines[0]}" = "$(printf 'noop\tCancel')" ]
  [[ "${lines[1]}" == "delete:plat"*"Remove group plat"* ]]
  [[ "${lines[1]}" == *"windows stay where they are"* ]]
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

# Omarchy sizes its own walker and starts the elephant/walker services first;
# the picker is a walker like any other and should look and behave like one.
@test "off Omarchy the picker calls walker itself, with Omarchy's geometry" {
  export WG_WALKER_ARGS_LOG="$WG_TMP/walker-args"
  export WG_WALKER_LAUNCHER="$WG_TMP/no-such-launcher"
  export WG_WALKER_PICK=1
  action="$(wg_group_menu_build | wg_menu_run 'Group')"
  [ "$action" = "group:plat" ]
  run cat "$WG_WALKER_ARGS_LOG"
  [ "$output" = "--width 644 --maxheight 300 --minheight 300 -d -i -p Group" ]
}

@test "on Omarchy the picker goes through omarchy-launch-walker, which starts the services" {
  export WG_WALKER_ARGS_LOG="$WG_TMP/walker-args"
  export WG_WALKER_LAUNCHER="$WG_ROOT/test/bin/walker-launcher-stub"
  export WG_WALKER_PICK=1
  # The default binary name, so the launcher is the one that has to be picked --
  # with a stub of that name ahead of any real walker on PATH, in case it is not.
  ln -sf "$WG_ROOT/test/bin/walker-stub" "$WG_TMP/walker"
  export PATH="$WG_TMP:$PATH"
  export WG_WALKER=walker

  action="$(wg_group_menu_build | wg_menu_run 'Group')"
  [ "$action" = "group:plat" ]
  run grep -c '^launcher -d -i -p Group$' "$WG_WALKER_ARGS_LOG"
  [ "$output" -eq 1 ]
  run grep -c 'width 644' "$WG_WALKER_ARGS_LOG"
  [ "$output" -eq 1 ]
}

@test "an explicitly chosen walker binary wins over the launcher" {
  export WG_WALKER_ARGS_LOG="$WG_TMP/walker-args"
  export WG_WALKER_LAUNCHER="$WG_ROOT/test/bin/walker-launcher-stub"
  export WG_WALKER_PICK=1
  action="$(wg_group_menu_build | wg_menu_run 'Group')"
  [ "$action" = "group:plat" ]
  run grep -c '^launcher' "$WG_WALKER_ARGS_LOG"
  [ "$output" -eq 0 ]
}

@test "the picker still gets the entries on stdin, one per line" {
  export WG_WALKER_STDIN_LOG="$WG_TMP/walker-stdin"
  export WG_WALKER_PICK=0
  wg_group_menu_build | wg_menu_run 'Group' >/dev/null
  run cat "$WG_WALKER_STDIN_LOG"
  [ "${lines[0]}" = "everest" ]
  [ "${lines[3]}" = "+ new group…" ]
}
