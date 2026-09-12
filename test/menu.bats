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
  # The picker reports what is in each group, and a group holds what is on its
  # workspace -- so this suite, like the bar's, means a filed desktop. The
  # fixture is the unfiled one the filing tests act on.
  wg_tidy_desktop
}

teardown() { wg_teardown_tmp; }

# The fixture desktop with window $1 dragged onto workspace $2 -- the one thing
# a user does by hand that counting by project owner could never see. Only the
# name is touched: the fixture's workspace ids are arbitrary and nothing here
# reads them.
#
# Reads whatever client list is currently in force, so two moves compose, and
# writes through a temporary rather than into the file it is reading.
wg_move_window() {
  jq --arg a "$1" --arg w "$2" \
    'map(if .address == $a then .workspace.name = $w else . end)' \
    "${WG_FIXTURE_CLIENTS:-$WG_FIXTURES/clients.json}" >"$WG_TMP/clients-moved.tmp"
  mv -f "$WG_TMP/clients-moved.tmp" "$WG_TMP/clients-moved.json"
  export WG_FIXTURE_CLIENTS="$WG_TMP/clients-moved.json"
}

@test "the menu opens with one entry per group, in state order" {
  count="$(wg_menu_build | grep -c '^group:')"
  [ "$count" -eq 3 ]
  first="$(wg_menu_build | head -n1 | cut -f1)"
  [ "$first" = "group:shop" ]
}

# Three windows, not the two this used to say, and the third is 0xaaa3: an
# override files it under site, and it is sitting on shop's workspace. The row
# counts what is in the group, and what is in the group is what is on it.
@test "a group entry shows its window, idle and busy counts" {
  display="$(wg_menu_build | head -n1 | cut -f2)"
  [[ "$display" == *"shop"* ]]
  [[ "$display" == *"3 windows"* ]]
  [[ "$display" == *"1 idle"* ]]
  [[ "$display" == *"2 busy"* ]]
}

# A plain terminal is neither idle nor busy, but it is still a window. Being in
# the group is now being on its workspace, so the terminal is dragged there
# rather than claimed by an override.
@test "a group entry counts a window with no Claude session as neither idle nor busy" {
  wg_move_window 0xaaa6 shop
  display="$(wg_menu_build | head -n1 | cut -f2)"
  [[ "$display" == *"4 windows · 1 idle · 2 busy"* ]]
}

# --- which group a window is in --------------------------------------------
#
# A group is a named workspace, so a window is in the group whose workspace it
# is on -- not the group that happens to own the directory it was opened in.
# The fixture desktop is tidy, every window on the workspace of the group that
# owns its project, which is exactly the arrangement in which the two rules
# agree and neither of them is being tested. These are the cases where they
# part company.

# The reported bug, in the form it was reported: a session running in a project
# no group has ever claimed, sitting in plain sight on a group's workspace, and
# the picker saying the group held nothing.
@test "a group counts a window on its workspace whose project no group owns" {
  jq -n '[{address: "0xdd1", pid: 9100, class: "Alacritty", floating: false,
           title: "✳ 3dprint slicer profile",
           workspace: {id: -99, name: "shop"}}]' >"$WG_TMP/clients-unclaimed.json"
  export WG_FIXTURE_CLIENTS="$WG_TMP/clients-unclaimed.json"
  # cwd.map holds the fixture pids and nothing else, and what this window needs
  # is a directory that is a real project and is in no group's project list.
  wg_window_cwd() { printf '%s\n' "$WG_PROJECTS_DIR/3dprint"; }

  [[ "$(wg_menu_build | grep '^group:shop' | cut -f2)" == *"1 windows · 1 idle · 0 busy"* ]]
  [[ "$(wg_menu_build | grep '^group:site' | cut -f2)" == *"0 windows · 0 idle · 0 busy"* ]]
  # And the row for the window itself agrees with the group row above it.
  [[ "$(wg_menu_build | grep '^window:0xdd1' | cut -f2)" == *"shop"* ]]
}

# The other half of the same rule: a window a group does own, dragged onto a
# different group's workspace, is counted where it is and not where it belongs.
# Both rows are read, because the count has to move rather than be shared.
@test "a window on another group's workspace counts there, not for its owner" {
  # 0xaaa5 is busy and its project, site-platform, belongs to site.
  wg_move_window 0xaaa5 shop
  [[ "$(wg_menu_build | grep '^group:shop' | cut -f2)" == *"4 windows · 1 idle · 3 busy"* ]]
  [[ "$(wg_menu_build | grep '^group:site' | cut -f2)" == *"1 windows · 1 idle · 0 busy"* ]]
}

# And a window on a numbered workspace is in no group, whoever owns its project
# -- which is the honest answer while it waits to be filed. It has not stopped
# existing, though: the footer counts every Claude session on the desktop,
# grouped or not, and that number does not move.
@test "a window on a numbered workspace counts for no group, but still for the desktop" {
  # 0xaaa1 is idle and its project, shop-web, belongs to shop.
  wg_move_window 0xaaa1 1
  [[ "$(wg_menu_build | grep '^group:shop' | cut -f2)" == *"2 windows · 0 idle · 2 busy"* ]]
  [[ "$(wg_menu_build | grep '^group:site' | cut -f2)" == *"2 windows · 1 idle · 1 busy"* ]]
  [ "$(wg_menu_build | tail -n1 | cut -f2)" = "── 5 Claude sessions · 2 idle · 3 busy" ]
}

@test "the menu lists every window" {
  count="$(wg_menu_build | grep -c '^window:')"
  [ "$count" -eq 7 ]
}

@test "a window entry uses the stripped title and names its group" {
  display="$(wg_menu_build | grep '^window:0xaaa1' | cut -f2)"
  [[ "$display" == *"Everest-web full redesign"* ]]
  [[ "$display" != *"✳ ✳"* ]]
  [[ "$display" == *"shop"* ]]
}

# Column 8 of the window table has held the worktree name since the first
# version and nothing displayed it. Two windows in different worktrees of the
# same repo resolve to the same project and so to the same group -- which is
# what filing them wants and no help at all in a list of rows all reading
# "site".
@test "a window sitting in a worktree names it next to its group" {
  display="$(wg_menu_build | grep '^window:0xaaa2' | cut -f2)"
  [[ "$display" == *"shop:price-units"* ]]
}

@test "a window that is not in a worktree says nothing extra" {
  display="$(wg_menu_build | grep '^window:0xaaa1' | cut -f2)"
  [[ "$display" == *"shop"* ]]
  [[ "$display" != *"shop:"* ]]
}

# The whole point of the column: same repo, same workspace, two rows that used
# to be indistinguishable. The pair is 0xaaa1 and 0xaaa2, both of them on shop's
# workspace -- what the row says before the colon is where the window is, so two
# windows on one workspace is the case where the worktree is all that is left to
# tell them apart.
@test "two windows in different worktrees of one repo are told apart" {
  wg_window_cwd() {
    case "$1" in
      1001) printf '%s\n' "$WG_PROJECTS_DIR/shop-web/.claude/worktrees/price-units" ;;
      1002) printf '%s\n' "$WG_PROJECTS_DIR/shop-web/.claude/worktrees/vat-rounding" ;;
      *) return 0 ;;
    esac
  }
  [[ "$(wg_menu_build | grep '^window:0xaaa1' | cut -f2)" == *"shop:price-units"* ]]
  [[ "$(wg_menu_build | grep '^window:0xaaa2' | cut -f2)" == *"shop:vat-rounding"* ]]
}

@test "wg_menu_where joins the group and the worktree, and falls back to ungrouped" {
  wg_menu_where site spec-draft
  [ "$WG_WHERE" = "site:spec-draft" ]
  wg_menu_where site ""
  [ "$WG_WHERE" = "site" ]
  wg_menu_where "" ""
  [ "$WG_WHERE" = "ungrouped" ]
}

# A worktree is named after a branch and a branch name has no upper bound. This
# is the last column of a row whose other columns are padded to fixed widths, so
# an unbounded field here is the one thing that can push the layout around.
@test "a long worktree name is cut down rather than allowed to stretch the row" {
  wg_menu_where site "feat-spec-draft-second-pass"
  [ "$WG_WHERE" = "site:feat-spec-draft…" ]
  # Exactly at the limit, nothing is cut.
  wg_menu_where site "sixteen-chars-ab"
  [ "$WG_WHERE" = "site:sixteen-chars-ab" ]
}

@test "an ungrouped window says so" {
  display="$(wg_menu_build | grep '^window:0xaaa6' | cut -f2)"
  [[ "$display" == *"ungrouped"* ]]
}

# The label in front of the colon is where the window is, and a window that has
# been dragged somewhere else is somewhere else. It has to agree with the group
# rows above it: a window counted under one group and labelled with another is
# the contradiction the whole change is about.
@test "the where label names the workspace the window is on, not its owner's group" {
  # 0xaaa5's project, site-platform, belongs to site; the window is on shop's.
  wg_move_window 0xaaa5 shop
  display="$(wg_menu_build | grep '^window:0xaaa5' | cut -f2)"
  [[ "$display" == *"shop"* ]]
  [[ "$display" != *"site"* ]]
}

# Ungrouped is about where the window is too, not about whether anything claims
# its directory: on workspace 1 it is in no group yet, however well known its
# project is.
@test "a window on a numbered workspace says ungrouped even when a group owns its project" {
  # 0xaaa1's project, shop-web, belongs to shop.
  wg_move_window 0xaaa1 1
  display="$(wg_menu_build | grep '^window:0xaaa1' | cut -f2)"
  [[ "$display" == *"ungrouped"* ]]
  [[ "$display" != *"shop"* ]]
}

# Order matters more than it looks. The actions used to sit below every window,
# which on a working desktop is some twenty rows down: far enough that
# "+ new group…" read as an entry the picker did not have. Groups stay first --
# switching to one is what SUPER+G is for -- and the actions come next.
@test "the picker lists groups, then the actions, then the windows" {
  actions="$(wg_menu_build | cut -f1 | sed 's/:.*//' | tr '\n' ' ')"
  [ "$actions" = "group group group new delete tidy toggle-auto noop window window window window window window window noop " ]
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

# The question that asked for this row: every group entry says how much is
# waiting in that group, and nothing said how much was running at all.
@test "the last entry totals the Claude sessions across the whole desktop" {
  last="$(wg_menu_build | tail -n1)"
  [ "$(cut -f1 <<<"$last")" = "noop" ]
  [ "$(cut -f2 <<<"$last")" = "── 5 Claude sessions · 2 idle · 3 busy" ]
}

# Adding it at the bottom is what keeps the layout above it a contract: walker
# hands back a position in this list.
@test "the footer sits after the last window and moves no entry above it" {
  entries="$(wg_menu_build)"
  [ "$(wc -l <<<"$entries")" -eq 16 ]
  [ "$(sed -n '15p' <<<"$entries" | cut -f1)" = "window:0xaaa7" ]
  [ "$(sed -n '16p' <<<"$entries" | cut -f1)" = "noop" ]
}

# A plain shell and a file manager are windows, not sessions. Counting them
# would answer a question nobody asked with a bigger number.
@test "the footer leaves a window with no Claude session out of the count" {
  cat >"$WG_TMP/clients-plain.json" <<'EOF'
[
  {"address":"0xbbb1","pid":1001,"class":"Alacritty","title":"✳ ready for review","floating":false,"workspace":{"id":1,"name":"1"}},
  {"address":"0xbbb2","pid":1006,"class":"Alacritty","title":"dev@host:~","floating":false,"workspace":{"id":1,"name":"1"}},
  {"address":"0xbbb3","pid":1007,"class":"org.gnome.Nautilus","title":"Home","floating":true,"workspace":{"id":1,"name":"1"}}
]
EOF
  export WG_FIXTURE_CLIENTS="$WG_TMP/clients-plain.json"
  [ "$(wg_menu_build | grep -c '^window:')" -eq 3 ]
  [ "$(wg_menu_build | tail -n1 | cut -f2)" = "── 1 Claude sessions · 1 idle · 0 busy" ]
}

@test "the footer says zero when no window is a Claude session" {
  cat >"$WG_TMP/clients-none.json" <<'EOF'
[
  {"address":"0xbbb2","pid":1006,"class":"Alacritty","title":"dev@host:~","floating":false,"workspace":{"id":1,"name":"1"}}
]
EOF
  export WG_FIXTURE_CLIENTS="$WG_TMP/clients-none.json"
  [ "$(wg_menu_build | tail -n1 | cut -f2)" = "── 0 Claude sessions · 0 idle · 0 busy" ]
}

# An empty desktop is the one case where the table is a single blank line, and
# a count taken from it must still be a number.
@test "the footer counts zero when there are no windows at all" {
  printf '[]\n' >"$WG_TMP/clients-empty.json"
  export WG_FIXTURE_CLIENTS="$WG_TMP/clients-empty.json"
  windows="$(wg_menu_build | grep -c '^window:' || true)"
  [ "$windows" -eq 0 ]
  [ "$(wg_menu_build | tail -n1 | cut -f2)" = "── 0 Claude sessions · 0 idle · 0 busy" ]
}

# Unselectable, like the separator: it is something to read, not something to do.
@test "wg_menu_run returns nothing when the footer is chosen" {
  entries="$(wg_menu_build)"
  last=$(( $(wc -l <<<"$entries") - 1 ))
  [[ "$(sed -n "$(( last + 1 ))p" <<<"$entries")" == *"Claude sessions"* ]]
  # The row above it is selectable, so the index really is in range.
  export WG_WALKER_PICK=$(( last - 1 ))
  [ "$(wg_menu_run 'Groups' <<<"$entries")" = "window:0xaaa7" ]
  export WG_WALKER_PICK=$last
  [ "$(wg_menu_run 'Groups' <<<"$entries")" = "" ]
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
  display="$(wg_menu_build | grep '^group:site' | cut -f2)"
  [[ "$display" == *"on DP-1"* ]]
}

@test "a group with no pin says nothing about monitors" {
  display="$(wg_menu_build | grep '^group:site' | cut -f2)"
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
  export WG_WALKER_INPUT="  site  "
  [ "$(wg_menu_input 'New group')" = "site" ]
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
  [ "$groups" = "group:shop group:site group:fleet new " ]
}

# The chooser for removing a group: no "+ new group…" on it -- offering to make
# one there is noise, and one entry off is the wrong group gone.
@test "wg_group_list_build offers the groups and nothing else" {
  groups="$(wg_group_list_build | cut -f1 | tr '\n' ' ')"
  [ "$groups" = "group:shop group:site group:fleet " ]
}

# Nothing is under the cursor by accident: the entry at index 0 is the one that
# does nothing.
@test "the delete confirmation puts cancel first and names the group" {
  run bash -c "cd '$WG_ROOT' && source lib/hypr.sh && source lib/state.sh \
    && source lib/resolve.sh && source lib/menu.sh && wg_delete_confirm_build site site"
  [ "${lines[0]}" = "$(printf 'noop\tCancel')" ]
  [[ "${lines[1]}" == "delete:site"*"Remove group site"* ]]
  [[ "${lines[1]}" == *"windows stay where they are"* ]]
}

@test "wg_menu_run returns the action at the index walker chose" {
  export WG_WALKER_PICK=1
  action="$(wg_group_menu_build | wg_menu_run 'Group')"
  [ "$action" = "group:site" ]
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
  [ "$action" = "group:site" ]
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
  [ "$action" = "group:site" ]
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
  [ "$action" = "group:site" ]
  run grep -c '^launcher' "$WG_WALKER_ARGS_LOG"
  [ "$output" -eq 0 ]
}

@test "the picker still gets the entries on stdin, one per line" {
  export WG_WALKER_STDIN_LOG="$WG_TMP/walker-stdin"
  export WG_WALKER_PICK=0
  wg_group_menu_build | wg_menu_run 'Group' >/dev/null
  run cat "$WG_WALKER_STDIN_LOG"
  [ "${lines[0]}" = "shop" ]
  [ "${lines[3]}" = "+ new group…" ]
}
