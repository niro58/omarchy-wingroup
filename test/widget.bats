#!/usr/bin/env bats

# The bar widget, exercised through the one path that matters and that no shell
# test can reach: QML.
#
# The colour of a group button is decided by classes() and idleStep() in
# Widget.qml, reading the "class" field the bar output carries -- one name, or a
# list of them. A list read through a Repeater's modelData is not a JavaScript
# Array: QML hands it over as a QVariantList, and Array.isArray says no. The
# widget used to ask exactly that question, so every group with two classes --
# which is every group with a window being worked in, "busy" and "idleN" --
# collapsed to the single class "busy,idle1", matched no idle step, and drew
# grey. The groups that were working were the grey ones.
#
# So the test runs the real functions, taken out of the real file, through a
# real Repeater, and asks what step a ["busy","idle1"] group comes out as. The
# answer is carried in the exit code: this runtime's console output does not
# survive the way it is invoked here, and an exit code cannot be swallowed.

load helper

setup() {
  wg_setup_tmp
  command -v qml6 >/dev/null || skip "qml6 (Qt 6) is not installed"
  WIDGET="$WG_ROOT/shell/wingroup.groups/Widget.qml"
  [ -f "$WIDGET" ] || skip "no widget to test"
}

# Writes a QML file that defines the widget's own classes() and idleStep(),
# lifted verbatim from Widget.qml, and exits with the step it computes for $1.
wg_widget_harness() {
  local class_json="$1" out="$WG_TMP/harness.qml"
  {
    printf 'import QtQuick\n\nItem {\n'
    printf '  property var groups: JSON.parse(%s).groups\n' \
           "'{\"groups\":[{\"text\":\"g\",\"class\":$class_json}]}'"
    printf '  property int code: 99\n\n'
    # The functions as they ship, so a change to either is a change to the test.
    sed -n '/^  function classes(/,/^  }$/p' "$WIDGET"
    printf '\n'
    sed -n '/^  function idleStep(/,/^  }$/p' "$WIDGET"
    printf '\n  readonly property var heat: ["a", "b", "c", "d"]\n'
    cat <<'EOF'

  Repeater {
    model: parent.groups
    Item {
      required property var modelData
      Component.onCompleted: code = idleStep(modelData)
    }
  }

  Component.onCompleted: Qt.callLater(function () { Qt.exit(code) })
}
EOF
  } >"$out"
  printf '%s\n' "$out"
}

@test "a group with one class keeps its idle step" {
  run env QT_QPA_PLATFORM=offscreen qml6 "$(wg_widget_harness '"idle3"')"
  [ "$status" -eq 3 ]
}

@test "a busy group keeps its idle step, though its class is a list" {
  run env QT_QPA_PLATFORM=offscreen qml6 "$(wg_widget_harness '["busy", "idle1"]')"
  [ "$status" -eq 1 ]
}

@test "a group with no windows has no idle step" {
  run env QT_QPA_PLATFORM=offscreen qml6 "$(wg_widget_harness '""')"
  [ "$status" -eq 0 ]
}

@test "the idle step is capped at the number of heat colours" {
  run env QT_QPA_PLATFORM=offscreen qml6 "$(wg_widget_harness '["busy", "idle9"]')"
  [ "$status" -eq 4 ]
}

teardown() {
  wg_teardown_tmp
}
