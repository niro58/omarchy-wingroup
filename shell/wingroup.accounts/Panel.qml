import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Every Claude account claude-swap knows, in one bar button and one panel.
//
// Omarchy's own agents panel shows one record per *tool* -- Claude, Codex,
// Fireworks -- so a machine with four Claude subscriptions sees one of them, the
// one whose credentials happen to be live. This is the same kind of panel turned
// the other way: one row per Claude account, each with its five-hour and weekly
// windows and when they reset, the live one marked, and a click to make another
// live.
//
// All of it comes from `cswap list --json`. claude-swap already polls the usage
// endpoint on its own schedule and backs off when Anthropic asks it to, so this
// only ever asks claude-swap -- never the endpoint -- and asking often costs
// nothing but a read of its cache. Switching is `cswap switch N`, which takes
// Claude Code's own credential locks; nothing here touches a credential.
//
// The drawing is Omarchy's: the same Panel base, keyboard panel, section headers
// and meter as the agents panel, so it sits in the bar as one of the family
// rather than as something bolted on.
Panel {
  id: root
  moduleName: "wingroup.accounts"
  ipcTarget: "wingroup.accounts"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property var accounts: []
  property string error: ""
  property double fetchedAt: 0
  property double nowMs: Date.now()
  property int selected: 0
  property bool switching: false

  // The bar lays a widget out at its implicit size, and a Panel is a bare Item
  // with none: without these the widget loaded, logged nothing, and drew at zero
  // width -- present in the layout and invisible on the bar.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var live: {
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].active) return accounts[i]
    return null
  }

  // --- pure helpers, kept free of the scene so test/accounts-widget.bats can
  // run them through a real QML engine ----------------------------------------

  // `cswap list --json` into the rows the panel draws. Anything claude-swap
  // could not read keeps its row with no numbers rather than losing its row:
  // an account that has gone quiet is exactly the one worth seeing.
  function parseAccounts(text) {
    var doc
    try { doc = JSON.parse(text) } catch (e) { return null }
    if (!doc || !Array.isArray(doc.accounts)) return null
    var rows = []
    for (var i = 0; i < doc.accounts.length; i++) {
      var a = doc.accounts[i]
      var u = a.usage || null
      rows.push({
        number: a.number,
        email: String(a.email || ("Account " + a.number)),
        active: a.active === true,
        status: String(a.usageStatus || ""),
        problem: a.usageError ? String(a.usageError) : "",
        disabled: a.disabled === true,
        // When claude-swap last got an answer for this account. It serves its
        // last good reading when a check fails, so the numbers below can be
        // far older than this list.
        checkedAt: Date.parse(a.usageFetchedAt || a.lastGoodFetchedAt || "") || 0,
        fiveHour: u && u.fiveHour ? { percent: Number(u.fiveHour.pct) / 100, resetsAt: String(u.fiveHour.resetsAt || "") } : null,
        sevenDay: u && u.sevenDay ? { percent: Number(u.sevenDay.pct) / 100, resetsAt: String(u.sevenDay.resetsAt || "") } : null
      })
    }
    return rows
  }

  // Milliseconds until an ISO timestamp, or 0 once it has passed.
  function resetMs(iso, now) {
    var at = Date.parse(iso)
    if (isNaN(at)) return 0
    return Math.max(0, at - now)
  }

  function formatDuration(ms) {
    var minutes = Math.round(ms / 60000)
    if (minutes < 60) return minutes + "m"
    var hours = Math.floor(minutes / 60)
    if (hours < 24) return hours + "h " + (minutes % 60) + "m"
    var days = Math.floor(hours / 24)
    return days + "d " + (hours % 24) + "h"
  }

  // The tighter of the two windows is the one that decides whether an account
  // can take work: a week at 100% is spent however quiet the last five hours were.
  function binding(row) {
    if (!row) return null
    var a = row.fiveHour, b = row.sevenDay
    if (!a) return b
    if (!b) return a
    return b.percent > a.percent ? b : a
  }

  function alarming(row) {
    var w = binding(row)
    return !!w && w.percent >= 0.9
  }

  // How old a row's numbers are, once they are too old to trust; 0 while they
  // are fresh enough, or when nothing says when they were read. claude-swap
  // checks an idle account at most every ten minutes, and backs off for an hour
  // when Anthropic rate-limits the check -- during which it keeps serving the
  // last reading. Fifteen minutes is past any normal gap, so a row this old is
  // one claude-swap could not refresh, and its numbers may say there is room
  // on an account Claude has already stopped.
  function staleMs(row, now) {
    if (!row || !row.checkedAt) return 0
    var age = now - row.checkedAt
    return age > 15 * 60000 ? age : 0
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }

  // --- talking to claude-swap -------------------------------------------------

  function refresh() {
    if (!lister.running) lister.running = true
  }

  function switchTo(row) {
    if (!row || row.active || switching) return
    switching = true
    switcher.command = ["env", "-u", "CLAUDE_CONFIG_DIR", "cswap", "switch", String(row.number)]
    switcher.running = true
  }

  // CLAUDE_CONFIG_DIR is taken out of the environment on purpose. claude-swap
  // honours it, and a shell started from a session that had one set would point
  // it at that directory instead of ~/.claude -- listing, and worse switching,
  // a login that is not the one every terminal is using.
  Process {
    id: lister
    command: ["env", "-u", "CLAUDE_CONFIG_DIR", "cswap", "list", "--json"]
    stdout: StdioCollector { id: listOut }
    onExited: function(code) {
      var rows = code === 0 ? root.parseAccounts(listOut.text) : null
      if (rows === null) {
        root.error = code === 127
          ? "claude-swap is not installed."
          : "claude-swap did not answer."
        return
      }
      root.error = ""
      root.accounts = rows
      root.fetchedAt = Date.now()
      root.selected = root.clamp(root.selected, 0, Math.max(0, rows.length - 1))
    }
  }

  Process {
    id: switcher
    onExited: function() {
      root.switching = false
      root.refresh()
    }
  }

  // Five minutes while closed, which is all the bar button needs to go red when
  // the live account runs short; every thirty seconds while the panel is open,
  // which is when someone is actually reading the numbers.
  Timer {
    interval: root.opened ? 30000 : 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: { root.nowMs = Date.now(); root.refresh() }
  }

  onOpenedChanged: if (opened) { nowMs = Date.now(); refresh() }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  // --- the bar ----------------------------------------------------------------

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The live account's tighter window, because that is the one about to stop
    // work; the glyph alone while there is nothing to report. A "?" when that
    // reading is too old to trust -- see staleMs.
    text: {
      var w = root.binding(root.live)
      if (!w) return "󱚣"
      return "󱚣 " + Math.round(w.percent * 100) + "%" + (root.staleMs(root.live, root.nowMs) > 0 ? "?" : "")
    }
    active: root.alarming(root.live)
    onPressed: function(buttonCode) { root.toggle() }
  }

  // --- the panel --------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0 && root.accounts.length > 0)
          root.selected = root.clamp(root.selected + dy, 0, root.accounts.length - 1)
      }
      onActivateRequested: root.switchTo(root.accounts[root.selected])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refresh() }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: flick.width
          spacing: Style.space(12)

          PanelSectionHeader {
            text: "CLAUDE ACCOUNTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.error !== ""
            width: parent.width
            text: root.error
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.accounts

            AccountRow {
              required property var modelData
              required property int index
              width: column.width
              account: modelData
              selected: index === root.selected
              onPicked: { root.selected = index; root.switchTo(modelData) }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: {
              if (root.switching) return "Switching…"
              if (root.fetchedAt === 0) return ""
              var seconds = Math.max(0, Math.round((root.nowMs - root.fetchedAt) / 1000))
              return "Updated " + (seconds < 60 ? "just now" : root.formatDuration(seconds * 1000) + " ago")
                + " · Enter switches · r refreshes"
            }
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  // One account: its address, whether it is live, and its two windows.
  component AccountRow: Rectangle {
    id: row
    property var account: null
    property bool selected: false
    signal picked()

    readonly property bool live: !!account && account.active

    implicitHeight: body.implicitHeight + Style.space(16)
    radius: Style.space(8)
    color: selected ? root.alpha(root.foreground, 0.08) : "transparent"
    border.width: live ? 1 : 0
    border.color: root.alpha(root.foreground, 0.35)

    MouseArea {
      anchors.fill: parent
      cursorShape: row.live ? Qt.ArrowCursor : Qt.PointingHandCursor
      onClicked: row.picked()
    }

    Column {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(8)
      spacing: Style.space(6)

      Item {
        width: parent.width
        implicitHeight: emailText.implicitHeight

        Text {
          id: emailText
          textFormat: Text.PlainText
          text: row.account ? row.account.email : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.live
          elide: Text.ElideRight
          anchors.left: parent.left
          anchors.right: liveTag.left
          anchors.rightMargin: Style.spacing.sm
        }

        Text {
          id: liveTag
          textFormat: Text.PlainText
          text: row.live ? "● live" : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Text {
        visible: text !== ""
        textFormat: Text.PlainText
        width: parent.width
        text: {
          if (!row.account) return ""
          if (row.account.disabled) return "Held out of rotation"
          if (row.account.status !== "ok" && row.account.problem !== "")
            return "Could not read usage (" + row.account.problem + ")"
          var stale = root.staleMs(row.account, root.nowMs)
          if (stale > 0)
            return "Last checked " + root.formatDuration(stale) + " ago — may be out of date"
          return ""
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      WindowRow { width: parent.width; title: "5-hour"; window: row.account ? row.account.fiveHour : null }
      WindowRow { width: parent.width; title: "Weekly"; window: row.account ? row.account.sevenDay : null }
    }
  }

  // A window: its name, how much of it is used, a meter, and when it resets.
  component WindowRow: Column {
    id: windowRow
    property string title: ""
    property var window: null
    readonly property bool alarming: !!window && window.percent >= 0.9

    spacing: Style.space(4)

    Item {
      width: parent.width
      implicitHeight: Math.max(label.implicitHeight, value.implicitHeight)

      Text {
        id: label
        textFormat: Text.PlainText
        text: {
          var ms = windowRow.window ? root.resetMs(windowRow.window.resetsAt, root.nowMs) : 0
          return windowRow.title + (ms > 0 ? " · resets in " + root.formatDuration(ms) : "")
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: value
        textFormat: Text.PlainText
        text: windowRow.window ? Math.round(windowRow.window.percent * 100) + "%" : "—"
        color: windowRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Meter {
      width: parent.width
      value: windowRow.window ? windowRow.window.percent : -1
      alarming: windowRow.alarming
    }
  }

  // Rounded track showing how much of an allowance is used -- the agents
  // panel's meter, so the two read the same side by side.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground
      Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }
  }

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }
}
