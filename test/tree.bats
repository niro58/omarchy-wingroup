#!/usr/bin/env bats

# Working out, from the rectangles a group was recorded in, the order its
# windows have to be put back in for Hyprland to build that arrangement again.
#
# Hyprland's dwindle layout splits the tile of whichever window has focus, so an
# arrangement is not a set of rectangles to be assigned -- it is a sequence of
# splits to be replayed. A recorded desktop is a guillotine partition: every
# arrangement dwindle can produce is one, because every split cuts a tile in
# two, all the way across. Reading that partition back gives the tree, and the
# tree gives the sequence.
#
# The plan is written as the moves it takes:
#   root  <key>                 -- this window goes in first, on its own
#   split <seed> <dir> <insert> -- focus <seed>, preselect <dir>, move <insert> in
#
# so a reader can follow it against what the compositor is told to do.

load helper

setup() {
  wg_setup_tmp
  source "$WG_ROOT/lib/tree.sh"
}

teardown() { wg_teardown_tmp; }

# rows are "key x y w h", one per line, as the record holds them
plan() { printf '%s\n' "$@" | wg_tree_plan; }

@test "one window is a plan of one move" {
  run plan "A 0 0 100 100"
  [ "$status" -eq 0 ]
  [ "$output" = "root A" ]
}

@test "two side by side split to the right" {
  run plan "A 0 0 100 200" "B 100 0 100 200"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "root A" ]
  [ "${lines[1]}" = "split A r B" ]
}

@test "two stacked split downwards" {
  run plan "A 0 0 200 100" "B 0 100 200 100"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "split A d B" ]
}

# The window that goes in first is the one in the top left corner: it is the
# tile every later split cuts away from, so it is the only one that can start
# out owning the whole workspace.
@test "the first window is the one in the top left" {
  run plan "B 100 0 100 200" "A 0 0 100 200"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "root A" ]
}

# A column beside a column. The outer cut is vertical, so the plan splits right
# first and then divides each side -- and the second window of the left side is
# put in against A, not against B, which is the whole point of naming a seed.
@test "a two by two grid splits outwards then down each side" {
  run plan "A 0 0 100 100" "B 100 0 100 100" "C 0 100 100 100" "D 100 100 100 100"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "root A" ]
  [ "${lines[1]}" = "split A r B" ]
  [ "${lines[2]}" = "split A d C" ]
  [ "${lines[3]}" = "split B d D" ]
}

@test "one window beside a stacked pair" {
  run plan "A 0 0 100 200" "B 100 0 100 100" "C 100 100 100 100"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "root A" ]
  [ "${lines[1]}" = "split A r B" ]
  [ "${lines[2]}" = "split B d C" ]
}

@test "a stacked pair beside a stacked pair keeps each pair together" {
  run plan "A 0 0 100 100" "C 0 100 100 100" "B 100 0 100 100" "D 100 100 100 100"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[1]}" = "split A r B" ]
}

# Tiles do not touch: Hyprland leaves a gap between them, so the right edge of
# one window and the left edge of the next are several pixels apart. Reading the
# partition has to allow for that or no cut is ever found and every group falls
# back to being left as it is -- which is the behaviour this replaces.
@test "the gap between tiles does not hide the cut" {
  run plan "A 2122 1656 781 468" "B 2917 1656 781 468" \
           "C 2122 2138 781 468" "D 2917 2138 781 468"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "root A" ]
  [ "${lines[1]}" = "split A r B" ]
  [ "${lines[2]}" = "split A d C" ]
  [ "${lines[3]}" = "split B d D" ]
}

# A pinwheel: four rectangles that tile a square with no cut running all the way
# across. dwindle cannot build it, so no record can hold it -- but a record can
# be damaged, or hold a stale rectangle, and the answer then has to be "I cannot
# do this" rather than a plan that puts windows somewhere arbitrary.
@test "an arrangement with no cut across is refused" {
  run plan "A 0 0 200 100" "B 200 0 100 200" \
           "C 100 100 200 100" "D 0 100 100 100"
  [ "$status" -ne 0 ]
}

@test "two windows in the same place are refused rather than guessed at" {
  run plan "A 0 0 100 100" "B 0 0 100 100"
  [ "$status" -ne 0 ]
}

@test "no rows is not an error and plans nothing" {
  run bash -c "source '$WG_ROOT/lib/tree.sh'; printf '' | wg_tree_plan"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# Six windows, three columns, the middle one split three ways -- the shape a
# real group ends up in after a few hours of opening terminals.
@test "a deeper arrangement is planned all the way down" {
  run plan "A 0 0 100 300" \
           "B 100 0 100 100" "C 100 100 100 100" "D 100 200 100 100" \
           "E 200 0 100 150" "F 200 150 100 150"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "root A" ]
  [ "${#lines[@]}" -eq 6 ]
}

# Every window goes in exactly once. A plan that named one twice would move it
# back and forth and leave another stranded on the holding workspace.
@test "every window is put in exactly once" {
  run bash -c "source '$WG_ROOT/lib/tree.sh'
    printf '%s\n' 'A 0 0 100 300' 'B 100 0 100 100' 'C 100 100 100 100' \
                  'D 100 200 100 100' 'E 200 0 100 150' 'F 200 150 100 150' \
      | wg_tree_plan | awk '/^root/ {print \$2} /^split/ {print \$4}' | sort | tr -d '\n'"
  [ "$output" = "ABCDEF" ]
}
