// wingroup's groups on Omarchy 4's bar.
//
// Omarchy 4 replaced waybar with a shell of its own, and wingroup's buttons were
// waybar modules -- so after the upgrade the groups were all still there, filed
// and restored, and nothing on screen said so. This is the same bar, drawn by
// the shell: one button per group, its label, how many Claude sessions in it are
// waiting (the superscript), coloured by how many; and a warning button when
// systemd-oomd has killed a session nobody has brought back yet.
//
// Everything it shows comes from one call to `wingroup-waybar --all`, which
// builds the window table once and describes every group from it. Waybar ran a
// process per slot instead, each building the whole table to describe one group
// -- 1.74 seconds of work per redraw on eight groups, against 0.3 here.

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "wingroup.groups"

  property var groups: []
  property var crashed: ({ text: "", tooltip: "" })

  // The idle heat, dimmest first, as the waybar style had it: pale sand to a
  // vivid orange, never red -- red is the crash warning's, and two reds a metre
  // away read as one.
  readonly property var heat: ["#d7b377", "#e0a458", "#e8933d", "#f2851c"]
  readonly property var heatOpacity: [0.70, 0.82, 0.92, 1.0]

  // Waybar's convention, which the bar output still follows: "class" is one
  // name or a list of them. Both have to end up as a list here.
  //
  // Not Array.isArray. The list arrives from JSON.parse inside a Process's
  // stdout handler and reaches QML as a QVariantList, which Array.isArray says
  // no to -- so every group with more than one class took the String() branch
  // and became the single class "busy,idle1". That never matches /^idle(\d+)$/,
  // so every busy group lost its idle heat and drew in the bar's plain
  // foreground: the groups actually being worked in were the grey ones, and
  // only a group with exactly one class kept its colour.
  //
  // So: a string is split on the separators either form can arrive with, and
  // anything else is walked by index, which is true of a real Array and of a
  // QVariantList alike.
  function classes(group) {
    var c = group && group["class"]
    if (!c) return []
    if (typeof c === "string") return c.split(/[\s,]+/).filter(function (s) { return s !== "" })
    var out = []
    for (var i = 0; i < c.length; i++) {
      var one = String(c[i])
      if (one !== "") out.push(one)
    }
    return out
  }

  function idleStep(group) {
    var cs = classes(group)
    for (var i = 0; i < cs.length; i++) {
      var m = /^idle([0-9]+)$/.exec(cs[i])
      if (m) return Math.min(parseInt(m[1]), heat.length)
    }
    return 0
  }

  function has(group, name) { return classes(group).indexOf(name) !== -1 }

  // --- refreshing ----------------------------------------------------------
  //
  // A redraw is asked for on every Hyprland event that can change what the bar
  // says -- a window opening, closing or moving, a title changing (Claude's ✳
  // and ◐ live in the title), the focused workspace moving -- and debounced, so
  // a burst of title changes costs one run. A run that is asked for while one is
  // in flight is not dropped: it is owed, and paid when the first one ends. The
  // same two rules the waybar daemon learned the hard way.

  property bool owed: false

  function refresh() {
    if (listProcess.running) { owed = true; return }
    listProcess.running = true
  }

  Process {
    id: listProcess
    running: false
    command: ["wingroup-waybar", "--all"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var doc = JSON.parse(String(text || "{}"))
          root.groups = doc.groups || []
          root.crashed = doc.crashed || { text: "", tooltip: "" }
        } catch (e) {
          // A half-written answer is not worth a broken bar: keep the last one.
        }
      }
    }
    onExited: {
      if (root.owed) { root.owed = false; root.refresh() }
    }
  }

  Timer {
    id: debounce
    interval: 300
    repeat: false
    onTriggered: root.refresh()
  }

  // A slow heartbeat underneath, for anything that changes without an event
  // Hyprland reports -- a group created from a terminal, a crash recorded.
  Timer {
    interval: 10000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!event || !event.name) return
      var name = String(event.name)
      if (/^(windowtitle|openwindow|closewindow|movewindow|workspace|focusedmon|moveworkspace|activewindow)/.test(name))
        debounce.restart()
    }
  }

  // wingroup's own commands say when they have changed something -- a new
  // group, a pin, a crash cleared -- with `omarchy-shell -q wingroup.groups refresh`.
  IpcHandler {
    target: "wingroup.groups"
    function refresh(): void { root.refresh() }
  }

  function run(command) { if (root.bar) root.bar.run(command) }

  // --- drawing -------------------------------------------------------------

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)
  implicitWidth: row.implicitWidth + trailingGap
  implicitHeight: row.implicitHeight

  GridLayout {
    id: row
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.groups.length + (root.crashed.text !== "" ? 1 : 0)
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.groups

      WidgetButton {
        required property var modelData
        readonly property int step: root.idleStep(modelData)

        bar: root.bar
        text: modelData.text || modelData.name
        tooltipText: modelData.tooltip || ""
        // The group you are looking at, on the screen you are looking at.
        active: root.has(modelData, "active")
        foreground: step > 0 ? root.heat[step - 1]
                             : (root.bar ? root.bar.barForeground : Color.foreground)
        opacity: step > 0 ? root.heatOpacity[step - 1]
                          : (active || root.has(modelData, "visible") || root.has(modelData, "busy") ? 1 : 0.6)
        horizontalMargin: 6
        verticalPadding: 6
        fixedHeight: root.barSize
        onPressed: function() { root.run("wingroup activate " + Util.shellQuote(modelData.name)) }
      }
    }

    // What oomd killed and nobody has brought back yet. Clicking it brings them
    // all back, each on the workspace it died on.
    WidgetButton {
      visible: root.crashed.text !== ""
      bar: root.bar
      text: root.crashed.text
      tooltipText: root.crashed.tooltip || ""
      foreground: "#fff5f5"
      activeColor: "#c81e1e"
      active: true
      horizontalMargin: 6
      verticalPadding: 6
      fixedHeight: root.barSize
      onPressed: function() { root.run("wingroup crashed --restore"); root.refresh() }
    }
  }
}
