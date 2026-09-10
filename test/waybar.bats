#!/usr/bin/env bats

load helper

setup() {
  wg_setup_tmp
  wg_seed_state
}

teardown() { wg_teardown_tmp; }

# The module's "class" is a plain string when it carries one class and a JSON
# array when it carries several -- waybar takes either, and only the array form
# puts more than one class on the widget. Read whichever it is as one
# space-separated list, so a single assertion covers the whole set.
wg_class_list() {
  jq -r 'if (.class | type) == "array" then (.class | join(" ")) else .class end'
}

@test "slot 0 renders the first group with its idle count as a superscript" {
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' <<<"$output")" = "shop¹" ]
}

@test "slot 1 renders the second group" {
  run "$WG_ROOT/bin/wingroup-waybar" 1
  [ "$(jq -r '.text' <<<"$output")" = "site¹" ]
}

# The superscript is the idle count, not the busy one: what the bar is for is
# spotting a session that has finished and can be given the next thing.
@test "a group whose sessions are all busy gets no superscript" {
  wg_patch_state '.groups[0].projects = ["shop-core"]'
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.text' <<<"$output")" = "shop" ]
}

@test "a group with no windows at all gets no superscript" {
  run "$WG_ROOT/bin/wingroup-waybar" 2
  [ "$(jq -r '.text' <<<"$output")" = "fleet" ]
  [ "$(jq -r '.class' <<<"$output")" = "" ]
}

@test "an empty slot renders empty text so waybar hides it" {
  run "$WG_ROOT/bin/wingroup-waybar" 5
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' <<<"$output")" = "" ]
}

@test "a group with busy windows gets the busy class" {
  run "$WG_ROOT/bin/wingroup-waybar" 0
  # The group also has one idle session, so the heat class rides along: the
  # state and the heat are two facts about the same group, not one field
  # fighting over itself.
  [ "$(wg_class_list <<<"$output")" = "busy idle1" ]
}

@test "the group on the focused monitor gets the active class, which beats busy" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "active idle1" ]
}

# The bug: `hyprctl activeworkspace` answers for the focused monitor only, so
# focusing the laptop screen made the group still filling the other monitor
# look like it was nowhere at all.
@test "a group on screen on an unfocused monitor is visible, not inactive" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-laptop-focused.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "visible idle1" ]
}

@test "a group on no monitor at all is not visible" {
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-laptop-focused.json"
  run "$WG_ROOT/bin/wingroup-waybar" 2
  [ "$(jq -r '.class' <<<"$output")" = "" ]
}

# The bug: both bars asked which monitor had *focus*, so a group active on the
# external screen was drawn as active on the laptop bar too. Waybar names the
# monitor a bar is drawn on in WAYBAR_OUTPUT_NAME.
@test "with WAYBAR_OUTPUT_NAME a group is active only on its own screen" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WAYBAR_OUTPUT_NAME=DP-1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "active idle1" ]
}

@test "with WAYBAR_OUTPUT_NAME the other screen's bar calls it visible, not active" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WAYBAR_OUTPUT_NAME=eDP-2
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "visible idle1" ]
}

@test "with WAYBAR_OUTPUT_NAME a group on no screen at all still has no class" {
  export WAYBAR_OUTPUT_NAME=eDP-2
  run "$WG_ROOT/bin/wingroup-waybar" 2
  [ "$(jq -r '.class' <<<"$output")" = "" ]
}

# It has not been confirmed that every waybar build and config exports the
# variable, so the path without it has to stay exactly as it was: the reference
# monitor is the focused one, wherever this copy of the module is drawn.
@test "without WAYBAR_OUTPUT_NAME the focused monitor still decides" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  unset WAYBAR_OUTPUT_NAME
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "active idle1" ]
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-laptop-focused.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "visible idle1" ]
}

# A bar on an output the compositor does not list -- a monitor unplugged between
# the two questions -- must still say something sensible rather than nothing.
@test "an unknown WAYBAR_OUTPUT_NAME falls back to on-screen-somewhere" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WAYBAR_OUTPUT_NAME=HDMI-A-9
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  [ "$(wg_class_list <<<"$output")" = "visible idle1" ]
}

@test "on a single monitor the focused group is still active" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-single.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "active idle1" ]
}

@test "the tooltip breaks the windows down into idle and busy, and lists the projects" {
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"2 windows · 1 idle · 1 busy"* ]]
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"shop-web, shop-core, shop-api"* ]]
}

# A plain terminal is a window of the group, but it is not a session waiting.
@test "a window with no Claude session counts as neither idle nor busy" {
  wg_patch_state '.overrides["0xaaa6"] = "shop"'
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"3 windows · 1 idle · 1 busy"* ]]
  [ "$(jq -r '.text' <<<"$output")" = "shop¹" ]
}

@test "slot 7 lists overflow groups in its tooltip" {
  cp "$WG_FIXTURES/state-many.json" "$WG_STATE_DIR/state.json"
  run "$WG_ROOT/bin/wingroup-waybar" 7
  [ "$(jq -r '.text' <<<"$output")" = "g7" ]
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"2 more: g8, g9"* ]]
}

@test "slot 7 has no overflow line when there are exactly eight groups or fewer" {
  run "$WG_ROOT/bin/wingroup-waybar" 7
  [[ "$(jq -r '.tooltip' <<<"$output")" != *"more:"* ]]
}

@test "the module output is valid JSON even when the state file is corrupt" {
  printf 'garbage' >"$WG_STATE_DIR/state.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  run bash -c "'$WG_ROOT/bin/wingroup-waybar' 0 | jq -e . >/dev/null"
  [ "$status" -eq 0 ]
}

# --- idle heat -------------------------------------------------------------
#
# An idle session is unused capacity: something finished, sitting there waiting
# to be given the next thing. The more of them a group is holding, the harder
# the button should pull the eye, so the module emits the count as a class --
# idle1..idle4 -- and style.css ramps it from warm to red. The count is capped:
# past a handful the exact number stops changing what you do about it.

# A client list of $2 idle and $3 busy Claude windows, all of them sent to
# group $1 by an override. An override owns a window outright, which saves
# inventing a project and a fixture cwd for every window just to get a count up.
wg_group_windows() {
  local group="$1" idle="$2" busy="${3:-0}"
  jq -n --argjson i "$idle" --argjson b "$busy" '
    [ range(0; $i) | {address: "0xbb\(.)", title: "✳ waiting for the next thing"} ]
    + [ range(0; $b) | {address: "0xcc\(.)", title: "◐ working on it"} ]
    | map(. + {pid: 9000, class: "Alacritty", floating: false,
               workspace: {id: 1, name: "1"}})' >"$WG_TMP/clients-heat.json"
  export WG_FIXTURE_CLIENTS="$WG_TMP/clients-heat.json"
  jq --arg g "$group" --argjson i "$idle" --argjson b "$busy" '
    .overrides = (reduce range(0; $i) as $n ({}; .["0xbb\($n)"] = $g)
                  | reduce range(0; $b) as $n (.; .["0xcc\($n)"] = $g))' \
    "$WG_STATE_DIR/state.json" >"$WG_TMP/state.heat"
  mv -f "$WG_TMP/state.heat" "$WG_STATE_DIR/state.json"
}

# Nothing waiting on you is the common case and has to look exactly as it
# always did: no heat class, nothing for the ramp to style.
@test "a group with no idle sessions emits no idle class at all" {
  wg_group_windows shop 0 0
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class' <<<"$output")" = "" ]
}

@test "one idle session warms the group to the first step of the ramp" {
  wg_group_windows shop 1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "idle1" ]
}

@test "two idle sessions step the ramp up" {
  wg_group_windows shop 2
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "idle2" ]
}

@test "three idle sessions step the ramp up again" {
  wg_group_windows shop 3
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "idle3" ]
}

# The ceiling is the class, not the count: the superscript still says five.
@test "five idle sessions cap at the top step of the ramp" {
  wg_group_windows shop 5
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "idle4" ]
  [ "$(jq -r '.text' <<<"$output")" = "shop⁵" ]
}

@test "a wildly idle group still caps at the top step" {
  wg_group_windows shop 12
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "idle4" ]
  [ "$(jq -r '.text' <<<"$output")" = "shop¹²" ]
}

# The heat is a second class beside the state, never instead of it -- waybar
# puts both on the widget, so #custom-wingroup0.busy.idle4 is a live selector.
@test "the idle class rides alongside busy" {
  wg_group_windows shop 5 1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "busy idle4" ]
}

@test "the idle class rides alongside active" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  wg_group_windows template 3
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "active idle3" ]
}

@test "the idle class rides alongside visible" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  wg_group_windows template 2
  export WG_FIXTURE_MONITORS="$WG_FIXTURES/monitors-laptop-focused.json"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "visible idle2" ]
}

# waybar-custom(5): "The class parameter also accepts an array of strings."
# That array is the only thing that puts two classes on one widget -- a string
# with a space in it becomes a single GTK class named "busy idle4", which no
# selector matches. One class stays the string the module always emitted.
@test "one class goes out as a string and several as the array waybar needs" {
  wg_group_windows shop 1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class | type' <<<"$output")" = "string" ]
  wg_group_windows shop 5 1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(jq -r '.class | type' <<<"$output")" = "array" ]
  [ "$(jq -r '.class | length' <<<"$output")" = "2" ]
}

# --- crashed sessions ------------------------------------------------------
#
# systemd-oomd kills a Claude session and its terminal simply vanishes; the only
# trace is a journal line naming the scope. The watcher turns that into a record
# while the map of live sessions can still say what was in it, and the bar's job
# is to say which group is the one that lost something.

WG_CRASH_N=0

# Files one crash the way the machine does: record the live session first, then
# file the kill against its scope. Through the library rather than by writing
# crashed.json by hand, so a record shape lib/sessions.sh would never produce is
# not a record these tests trust. The subshell keeps the libraries' defaults out
# of the test's own shell.
wg_crash() {
  local cwd="$1" session="${2:-}" at="${3:-2026-09-10T11:02:03+02:00}"
  WG_CRASH_N=$(( WG_CRASH_N + 1 ))
  # A scope of its own per crash: the list is deduped by scope, so two crashes
  # sharing one would quietly become a single record.
  local scope
  scope="$(wg_fake_scope "c0ffee0$WG_CRASH_N")"
  (
    set -euo pipefail
    source "$WG_LIB_DIR/state.sh"
    source "$WG_LIB_DIR/sessions.sh"
    wg_sessions_record "$scope" "$session" "$cwd" hook
    wg_crashed_add "$scope" "$at"
  )
}

# The other end of the same lifecycle -- `wingroup crashed --restore` finishes
# by calling this -- and through the library for the same reason wg_crash is:
# what the runtime directory looks like after a clear is the library's own
# decision, and a test that removed the file by hand would be asserting its own
# behaviour rather than the shipped one.
wg_crash_clear() {
  (
    set -euo pipefail
    source "$WG_LIB_DIR/state.sh"
    source "$WG_LIB_DIR/sessions.sh"
    wg_crashed_clear
  )
}

@test "a group that lost a session to the oom killer gets the crashed class" {
  wg_crash /home/dev/projects/shop-web sess-a1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "busy idle1 crashed" ]
}

@test "a group that lost nothing does not get the crashed class" {
  wg_crash /home/dev/projects/shop-web sess-a1
  run "$WG_ROOT/bin/wingroup-waybar" 1
  [ "$(wg_class_list <<<"$output")" = "busy idle1" ]
}

# Three independent facts about one group: where it is, how much finished work
# is waiting in it, and what it lost. All three ride together.
@test "the crashed class rides alongside the idle heat and the active class" {
  cp "$WG_FIXTURES/state-template.json" "$WG_STATE_DIR/state.json"
  wg_group_windows template 3
  wg_crash /home/dev/projects/shop-web sess-a1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "active idle3 crashed" ]
}

@test "the tooltip names what died, where it was and when" {
  wg_crash /home/dev/projects/shop-core sess-a1 2026-09-10T11:02:03+02:00
  run "$WG_ROOT/bin/wingroup-waybar" 0
  local tooltip
  tooltip="$(jq -r '.tooltip' <<<"$output")"
  [[ "$tooltip" == *"/home/dev/projects/shop-core"* ]]
  [[ "$tooltip" == *"2026-09-10T11:02:03+02:00"* ]]
  # The line the tooltip has always opened with is still the line it opens with.
  [ "$(head -n1 <<<"$tooltip")" = "shop — 2 windows · 1 idle · 1 busy" ]
}

# A crash record carries a directory, not a group: a session that died in a
# project no group has claimed belongs to nobody, and must not be hung on
# whichever button happens to be first.
@test "a crash in a project belonging to no group attaches to no group" {
  wg_crash /home/dev/projects/unclaimed sess-a1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "busy idle1" ]
  [[ "$(jq -r '.tooltip' <<<"$output")" != *"Crashed"* ]]
}

@test "a crash outside the projects directory attaches to no group" {
  wg_crash /tmp/somewhere sess-a1
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$(wg_class_list <<<"$output")" = "busy idle1" ]
}

# This module is re-run on every window-title change, and Claude rewrites the
# title several times a second while it is working -- so whatever the module
# costs is paid at that rate, all day. The crash check is one read of the crash
# list: no journalctl, no walk of /proc, no jq per window.
#
# Nine, which is what the module cost before crash detection existed at all.
# The tenth jq the crash read would have added is not spent here because the
# module asks [[ -f $WG_CRASHED_FILE ]] first, and a machine where nothing has
# died has no such file: the whole feature costs a healthy desktop no processes
# whatsoever. Nine is therefore the number to defend -- ten would mean the
# guard has stopped guarding.
#
# The numbers are budgets, not facts about jq. If a change pushes one of them
# up, the change is the thing to look at.
@test "the module stays inside its jq budget when nothing has crashed" {
  wg_count_jq
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  run jq_calls
  [ "$output" -le 9 ]
}

# Resolving crashes costs a second read of the list and one load of the
# project->group map, and that is all it costs however many sessions died: the
# per-crash work is parameter expansion and an array lookup, not a jq.
@test "three crashed sessions cost no more jq than one" {
  wg_crash /home/dev/projects/shop-web sess-a1
  wg_crash /home/dev/projects/shop-core sess-b2
  wg_crash /home/dev/projects/shop-api sess-c3
  wg_count_jq
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  run jq_calls
  [ "$output" -le 12 ]
}

# The budget above was only ever measured with no crash file at all, which is
# the state of a machine that has never been oom-killed -- and the module lives
# on machines that have. An empty crash *document* is a different state, and a
# more expensive one: nothing can know a list is empty without reading it, so
# the mkdir and the jq of wg_crashed_rows are paid in full for a list holding
# nothing. That gap is the entire reason wg_crashed_clear removes the file
# instead of writing {"crashed": []}, so it is measured here rather than
# assumed -- if it ever closes, the removal has stopped buying anything and the
# next test below is dead weight.
@test "an empty crash document costs more jq than no crash file at all" {
  mkdir -p "$WG_RUNTIME_DIR"
  wg_count_jq
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  local absent
  absent="$(jq_calls)"
  printf '%s\n' '{"crashed":[]}' >"$WG_RUNTIME_DIR/crashed.json"
  : >"$WG_JQ_LOG"
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  local empty
  empty="$(jq_calls)"
  [ "$empty" -gt "$absent" ]
}

# So a clear has to leave behind the cheap state, not the empty document: the
# module is back on the budget it had before anything died, forever, rather
# than paying the higher one for the rest of the boot because of one crash it
# has already dealt with. Asserted through the module's cost rather than by
# stat-ing the file, because the cost is the thing that actually matters here
# and it is the thing the old budget test could not see -- with the clear
# writing an empty document this run spends the empty-document count above, not
# the no-crash-file one.
@test "clearing a crash puts the module back on its no-crash-file budget" {
  wg_crash /home/dev/projects/shop-web sess-a1
  wg_crash_clear
  wg_count_jq
  run "$WG_ROOT/bin/wingroup-waybar" 0
  [ "$status" -eq 0 ]
  run jq_calls
  [ "$output" -le 9 ]
}

# --- the crashed button ----------------------------------------------------
#
# A module of its own at the end of the bar: `wingroup-waybar crashed`. The
# slots say which group lost something; this one says the machine did, carries
# the count, and is the thing that gets clicked to bring the sessions back. It
# belongs to no group, so it takes no slot number and reads no state.

@test "the crashed button draws nothing when nothing has crashed" {
  run "$WG_ROOT/bin/wingroup-waybar" crashed
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' <<<"$output")" = "" ]
  [ "$(jq -r '.tooltip' <<<"$output")" = "" ]
  [ "$(jq -r '.class' <<<"$output")" = "" ]
}

# The same nothing, one state further along: a machine that has been oom-killed
# and dealt with, whose list is empty rather than absent. wg_crashed_clear
# leaves no file at all, but an empty document is still a document some other
# writer could leave behind, and it means the same thing to the bar.
@test "an empty crash list draws nothing either" {
  mkdir -p "$WG_RUNTIME_DIR"
  printf '%s\n' '{"crashed":[]}' >"$WG_RUNTIME_DIR/crashed.json"
  run "$WG_ROOT/bin/wingroup-waybar" crashed
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' <<<"$output")" = "" ]
  [ "$(jq -r '.class' <<<"$output")" = "" ]
  run bash -c "'$WG_ROOT/bin/wingroup-waybar' crashed | jq -e . >/dev/null"
  [ "$status" -eq 0 ]
}

@test "one crashed session puts the warning glyph and a count on the bar" {
  wg_crash /home/dev/projects/shop-web sess-a1
  run "$WG_ROOT/bin/wingroup-waybar" crashed
  [ "$status" -eq 0 ]
  [ "$(jq -r '.text' <<<"$output")" = "⚠1" ]
  [ "$(wg_class_list <<<"$output")" = "crashed" ]
}

# The count is the machine's, not a group's: these three are spread over two
# groups and one project no group has claimed, and the button still says three.
@test "three crashed sessions count up on the one button" {
  wg_crash /home/dev/projects/shop-web sess-a1
  wg_crash /home/dev/projects/site-platform sess-b2
  wg_crash /home/dev/projects/unclaimed sess-c3
  run "$WG_ROOT/bin/wingroup-waybar" crashed
  [ "$(jq -r '.text' <<<"$output")" = "⚠3" ]
  [ "$(wg_class_list <<<"$output")" = "crashed" ]
}

@test "the tooltip counts the dead and names every directory and time" {
  wg_crash /home/dev/projects/shop-web sess-a1 2026-09-10T11:02:03+02:00
  wg_crash /home/dev/projects/shop-core sess-b2 2026-09-10T11:44:00+02:00
  run "$WG_ROOT/bin/wingroup-waybar" crashed
  local tooltip
  tooltip="$(jq -r '.tooltip' <<<"$output")"
  [ "$(head -n1 <<<"$tooltip")" = "2 session(s) killed by systemd-oomd" ]
  [[ "$tooltip" == *"/home/dev/projects/shop-web — 2026-09-10T11:02:03+02:00"* ]]
  [[ "$tooltip" == *"/home/dev/projects/shop-core — 2026-09-10T11:44:00+02:00"* ]]
  # One line of heading and one line per session, and nothing else.
  [ "$(wc -l <<<"$tooltip")" -eq 3 ]
}

# What the click is actually deciding about: a recorded id brings the
# conversation back. So the tooltip says it per session rather than in general.
@test "the tooltip says which sessions can be resumed by id" {
  wg_crash /home/dev/projects/shop-web sess-a1
  run "$WG_ROOT/bin/wingroup-waybar" crashed
  [[ "$(jq -r '.tooltip' <<<"$output")" == *"/home/dev/projects/shop-web — "*" · resumable"* ]]
}

# A session that was already running when the SessionStart hook was installed
# was only ever seen by a scan, and a scan cannot learn an id. All a restore can
# offer there is a fresh claude in the same directory; promising a resume would
# be promising a conversation that is not coming back.
@test "a crash with no session id is not described as resumable" {
  wg_crash /home/dev/projects/shop-web ""
  run "$WG_ROOT/bin/wingroup-waybar" crashed
  local tooltip
  tooltip="$(jq -r '.tooltip' <<<"$output")"
  [[ "$tooltip" == *"no session id, a fresh claude"* ]]
  [[ "$tooltip" != *"resumable"* ]]
  [ "$(jq -r '.text' <<<"$output")" = "⚠1" ]
}

# This module is re-run on every window-title change like the slots are, and it
# sits on the bar of every machine whether or not anything has ever died there
# -- so what a healthy desktop pays for it is the number that matters.
#
# One: the single jq wg_emit spends to print the empty module. Nothing else is
# bought at all -- no state file, no window table, no state map, and not even a
# read of the crash list, because a machine with nothing to report has no crash
# file and [[ -f ]] answers that for free. Two would mean the guard has stopped
# guarding and the list is being read only to be told it is empty.
@test "the crashed button costs one jq when nothing has crashed" {
  wg_count_jq
  run "$WG_ROOT/bin/wingroup-waybar" crashed
  [ "$status" -eq 0 ]
  run jq_calls
  [ "$output" -le 1 ]
}
