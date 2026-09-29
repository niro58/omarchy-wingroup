#!/usr/bin/env bats

# The Claude accounts panel, through the one path that can run its logic: QML.
#
# What is tested is the reading of `cswap list --json` into rows and the choice
# of which window a row is judged by. The drawing is checked by eye on the real
# bar; the decisions a user relies on -- which account is live, which one is
# spent, what an account nobody could read looks like -- are checked here,
# against the functions as they ship, lifted verbatim out of Panel.qml.
#
# Answers come back through the exit code, as in test/widget.bats: console
# output does not survive the way qml6 is invoked here, and an exit code cannot
# be swallowed.

load helper

setup() {
  wg_setup_tmp
  command -v qml6 >/dev/null || skip "qml6 (Qt 6) is not installed"
  # Overridable so a mutation run can point the tests at a broken copy rather
  # than editing the file a running bar has loaded -- the shell reloads a
  # plugin the moment its file changes.
  PANEL="${WG_ACCOUNTS_PANEL:-$WG_ROOT/shell/wingroup.accounts/Panel.qml}"

  # The harness has to be shown to load before any answer it gives means
  # anything. qml6 exits 2 when a file fails to load -- and 2 is also a perfectly
  # good answer to "how many rows", which is how a broken harness passed the
  # first version of the row-count test.
  run timeout 20 env QT_QPA_PLATFORM=offscreen qml6 "$(wg_accounts_harness 42)"
  [ "$status" -eq 42 ] || {
    echo "the harness built from Panel.qml does not load (exit $status)"
    return 1
  }
}

teardown() { wg_teardown_tmp; }

# One function out of Panel.qml, found by name and ended by counting braces.
#
# Not a sed range to the next "  }": a function written on one line has no such
# closing line of its own, so the range runs on through whatever follows it and
# the harness gets half of some other function.
wg_accounts_function() {
  awk -v name="$1" '
    !found && $0 ~ "^  function " name "\\(" { found = 1 }
    found {
      print
      depth += gsub(/\{/, "{") - gsub(/\}/, "}")
      if (depth == 0) exit
    }
  ' "$PANEL"
}

# A QML file holding the panel's own functions that runs $1 as a JavaScript
# expression and exits with its value.
wg_accounts_harness() {
  local expr="$1" out="$WG_TMP/harness.qml" fn
  {
    printf 'import QtQuick\n\nItem {\n'
    for fn in parseAccounts resetMs formatDuration binding alarming clamp; do
      wg_accounts_function "$fn"
    done
    # try/catch because an expression that throws never reaches Qt.exit, and
    # qml6 then waits for ever -- which is how a mutation run of this file hung
    # for eight minutes instead of failing. 99 is "it threw", distinct from any
    # answer a test expects.
    printf '  Component.onCompleted: Qt.callLater(function () { try { Qt.exit(%s) } catch (e) { Qt.exit(99) } })\n}\n' "$expr"
  } >"$out"
  printf '%s\n' "$out"
}

# timeout as well, for whatever a try/catch cannot reach: a hang at load time.
run_expr() { run timeout 20 env QT_QPA_PLATFORM=offscreen qml6 "$(wg_accounts_harness "$1")"; }

# Two accounts as claude-swap reports them: the live one with room, a second
# whose week is nearly spent.
TWO='{"schemaVersion":1,"activeAccountNumber":1,"accounts":[
  {"number":1,"email":"a@x","active":true,"usageStatus":"ok",
   "usage":{"fiveHour":{"pct":58.0,"resetsAt":"2099-01-01T00:00:00Z"},
            "sevenDay":{"pct":12.0,"resetsAt":"2099-01-05T00:00:00Z"}}},
  {"number":2,"email":"b@x","active":false,"usageStatus":"ok",
   "usage":{"fiveHour":{"pct":2.0,"resetsAt":"2099-01-01T00:00:00Z"},
            "sevenDay":{"pct":94.0,"resetsAt":"2099-01-02T00:00:00Z"}}}]}'

js() { printf '%s' "$1" | tr -d '\n'; }

@test "every account claude-swap reports becomes a row" {
  run_expr "parseAccounts('$(js "$TWO")').length"
  [ "$status" -eq 2 ]
}

@test "the live account is the one claude-swap marks active" {
  run_expr "parseAccounts('$(js "$TWO")').findIndex(function (r) { return r.active }) + 1"
  [ "$status" -eq 1 ]
}

@test "percentages arrive as fractions of the window" {
  run_expr "Math.round(parseAccounts('$(js "$TWO")')[0].fiveHour.percent * 100)"
  [ "$status" -eq 58 ]
}

# The tighter window decides. Account 2 has barely touched its five hours and
# has almost nothing left of its week -- it is not somewhere to send work, and
# the row has to say so rather than show the 2% that looks like plenty.
@test "an account is judged by its tighter window, not its emptier one" {
  run_expr "Math.round(binding(parseAccounts('$(js "$TWO")')[1]).percent * 100)"
  [ "$status" -eq 94 ]
}

@test "a week at 94% is alarming even with the five hours nearly empty" {
  run_expr "alarming(parseAccounts('$(js "$TWO")')[1]) ? 7 : 3"
  [ "$status" -eq 7 ]
}

@test "an account with room is not alarming" {
  run_expr "alarming(parseAccounts('$(js "$TWO")')[0]) ? 7 : 3"
  [ "$status" -eq 3 ]
}

# An account claude-swap could not read keeps its row -- an account that has
# gone quiet is exactly the one worth seeing -- and carries no numbers, so it
# can never read as an account with room.
@test "an account nobody could read keeps its row and has no windows" {
  local doc='{"accounts":[{"number":3,"email":"c@x","active":false,"usageStatus":"unavailable","usageError":"http-429","usage":null}]}'
  run_expr "(function (r) { return (r.length === 1 && r[0].fiveHour === null && r[0].sevenDay === null && r[0].problem === 'http-429') ? 7 : 3 })(parseAccounts('$doc'))"
  [ "$status" -eq 7 ]
}

@test "an account with no windows is not alarming" {
  local doc='{"accounts":[{"number":3,"email":"c@x","active":false,"usageStatus":"unavailable","usage":null}]}'
  run_expr "alarming(parseAccounts('$doc')[0]) ? 7 : 3"
  [ "$status" -eq 3 ]
}

# Anything that is not claude-swap's document -- an error page, nothing at all --
# is "could not read", not "no accounts". The panel shows an error for the first
# and a list for the second, and mixing them up would show an empty list as if
# every account had vanished.
@test "output that is not claude-swap's document is refused, not read as empty" {
  run_expr "parseAccounts('not json') === null ? 7 : 3"
  [ "$status" -eq 7 ]
}

@test "a reset already in the past counts down to nothing" {
  run_expr "resetMs('2000-01-01T00:00:00Z', Date.now()) === 0 ? 7 : 3"
  [ "$status" -eq 7 ]
}

@test "durations read in the largest unit that fits" {
  run_expr "(formatDuration(45 * 60000) === '45m' && formatDuration(210 * 60000) === '3h 30m' && formatDuration(50 * 3600000) === '2d 2h') ? 7 : 3"
  [ "$status" -eq 7 ]
}
