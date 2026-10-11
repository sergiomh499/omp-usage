import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "sergiomh499.omp-usage"
  ipcTarget: "sergiomh499.omp-usage"

  // Dynamic state: whatever `omp usage --json` and omp's stats.db report,
  // nothing hardcoded per provider.
  property var reports: []
  property var burn: []
  property double generatedAt: 0
  property bool refreshing: false
  property string usageError: ""

  readonly property int refreshSec: Math.max(30, Number(setting("refreshSec", 60)))
  readonly property string home: Quickshell.env("HOME")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Sized exactly like jesseburlamaque.antigravity-usage (the widget that
  // demonstrably works in this bar): width+implicitWidth both bound through
  // an inner `button` item that fills the root.
  width: button.implicitWidth
  implicitWidth: button.implicitWidth
  height: button.implicitHeight
  implicitHeight: button.implicitHeight

  // --------------------------------------------------------------- processes
  Process {
    id: usageProc
    running: false
    command: ["omp", "usage", "--json"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyUsage(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: function(text) {
        if (text && text.trim() !== "") console.warn("sergiomh499.omp-usage", text.trim())
      }
    }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode !== 0) root.usageError = "omp usage failed (exit " + exitCode + ")"
    }
  }

  Process {
    id: statsProc
    running: false
    command: [
      "sqlite3", "-json", root.home + "/.omp/stats.db",
      "select provider, sum(input_tokens + output_tokens) as tok, sum(cost_total) as cost" +
      " from messages where timestamp >= strftime('%s','now','localtime','start of day') * 1000" +
      " group by provider order by tok desc"
    ]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyBurn(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: function(text) {
        if (text && text.trim() !== "") console.warn("sergio.omp-usage/stats", text.trim())
      }
    }
  }

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: if (opened) refresh()

  // ------------------------------------------------------------------ actions
  function refresh() {
    if (!usageProc.running) {
      refreshing = true
      usageProc.running = true
    }
    if (!statsProc.running) statsProc.running = true
  }

  function applyUsage(content) {
    try {
      var data = JSON.parse(String(content || "{}"))
      reports = Array.isArray(data.reports) ? data.reports : []
      generatedAt = Number(data.generatedAt || 0)
      usageError = ""
    } catch (e) {
      usageError = "bad JSON from omp usage"
      console.error("sergiomh499.omp-usage", "parse failed:", e)
    }
  }

  function applyBurn(content) {
    var text = String(content || "").trim()
    if (!text) { burn = []; return }
    try { burn = JSON.parse(text) } catch (e) { console.error("sergio.omp-usage/stats", e) }
  }

  // ---------------------------------------------------------------- data view
  function burnFor(provider) {
    for (var i = 0; i < burn.length; i++)
      if (burn[i].provider === provider) return burn[i]
    return null
  }

  // One row per connected provider: usage reports first, then any provider
  // that burned tokens today without a limits report (still worth showing).
  function providerRows() {
    var rows = []
    var seen = {}
    for (var i = 0; i < reports.length; i++) {
      var r = reports[i]
      seen[r.provider] = true
      rows.push({ name: r.provider, limits: r.limits || [], meta: r.metadata || {}, burn: burnFor(r.provider) })
    }
    for (var j = 0; j < burn.length; j++)
      if (!seen[burn[j].provider] && Number(burn[j].tok || 0) > 0)
        rows.push({ name: burn[j].provider, limits: [], meta: {}, burn: burn[j] })
    return rows
  }

  // Worst (most-consumed) limit of a provider — drives the popup rows.
  function worst(limits) {
    var w = { frac: 0, status: "ok", label: "", resetsAt: 0, window: "" }
    for (var i = 0; i < limits.length; i++) {
      var l = limits[i]
      var f = l.amount ? Number(l.amount.usedFraction || 0) : 0
      if (f >= w.frac) {
        w = {
          frac: f,
          status: l.status || "ok",
          label: l.label || "",
          resetsAt: (l.window && l.window.resetsAt) || 0,
          window: (l.window && l.window.label) || ""
        }
      }
    }
    return w
  }

  // Shared limits (e.g. "Claude & GPT" reported once per model family) would
  // render twice in the popup; dedupe by label+window.
  function uniqueLimits(limits) {
    var out = [], keys = {}
    for (var i = 0; i < limits.length; i++) {
      var l = limits[i]
      var key = (l.label || "") + "|" + ((l.window && l.window.label) || "")
      if (keys[key]) continue
      keys[key] = true
      out.push(l)
    }
    return out
  }

  function statusColor(status, frac) {
    if (status === "exhausted" || frac >= 0.98) return "#F38BA8"
    if (status === "warning" || frac >= 0.8) return "#F9E2AF"
    return "#A6E3A1"
  }

  function pct(frac) { return Math.round(Math.min(1, Math.max(0, frac)) * 100) + "%" }

  // Short name for popup/tooltip. Generic fallback: word initials, so a
  // provider added later in OMP still gets a sane label without a code change.
  function shortName(p) {
    var known = {
      "google-antigravity": "AG", "opencode-go": "OC", "openrouter": "OR",
      "perplexity": "PX", "nvidia": "NV", "anthropic": "AN", "openai": "OA",
      "github-copilot": "GH", "copilot": "GH", "zai": "ZAI"
    }
    if (known[p]) return known[p]
    return String(p).split(/[-_.]/).map(function(w) { return w.charAt(0) }).join("").toUpperCase()
  }

  function formatTokens(n) {
    n = Number(n || 0)
    if (n >= 1e9) return (n / 1e9).toFixed(1) + "B"
    if (n >= 1e6) return (n / 1e6).toFixed(1) + "M"
    if (n >= 1e3) return (n / 1e3).toFixed(1) + "K"
    return String(n)
  }

  function formatMoney(n) {
    n = Number(n || 0)
    return "$" + (n >= 10 ? n.toFixed(0) : n >= 1 ? n.toFixed(1) : n.toFixed(2))
  }

  function formatReset(ms) {
    var diff = ms - Date.now()
    if (diff <= 0) return "now"
    var mins = Math.ceil(diff / 60000)
    if (mins < 60) return mins + "m"
    var hours = Math.floor(mins / 60)
    if (hours < 24) return hours + "h" + (mins % 60) + "m"
    return Math.floor(hours / 24) + "d" + (hours % 24) + "h"
  }

  function clockTime(ms) {
    var d = new Date(ms)
    function pad(x) { return x < 10 ? "0" + x : String(x) }
    return pad(d.getHours()) + ":" + pad(d.getMinutes())
  }

  function fetchedAgo() {
    if (!generatedAt) return ""
    var secs = Math.max(0, Math.round((Date.now() - generatedAt) / 1000))
    if (secs < 60) return secs + "s ago"
    return Math.floor(secs / 60) + "m ago"
  }

  function tooltipText() {
    var rows = providerRows()
    if (rows.length === 0) return usageError || "OMP: no usage data"
    var lines = []
    for (var i = 0; i < rows.length; i++) {
      var w = worst(rows[i].limits)
      var line = rows[i].name + ": "
      if (rows[i].limits.length > 0) line += pct(w.frac) + " " + w.label + " · resets in " + formatReset(w.resetsAt)
      else line += "no limits reported"
      if (rows[i].burn) line += " · today " + formatTokens(rows[i].burn.tok) + " tok"
      lines.push(line)
    }
    return lines.join("\n")
  }

  // ----------------------------------------------------------------- bar chips
  // One box per provider, all the same height, vertically centred in the icon
  // slot and evenly spaced — matches the neighbouring icon widgets' rhythm.
  Item {
    id: button
    anchors.fill: parent
    implicitWidth: chipRow.implicitWidth
    implicitHeight: Style.bar.iconSlot

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: 6

      Repeater {
        model: root.providerRows()

        delegate: Rectangle {
          id: chip
          required property var modelData

          readonly property var w: root.worst(modelData.limits)
          readonly property bool hasLimits: modelData.limits.length > 0

          height: Style.bar.iconSlot - 8
          width: chipText.implicitWidth + 14
          radius: 5
          color: Qt.rgba(1, 1, 1, 0.06)
          border.width: 1
          border.color: chip.hasLimits ? root.statusColor(w.status, w.frac) : root.dim

          Text {
            id: chipText
            anchors.centerIn: parent
            text: root.shortName(chip.modelData.name) + (chip.hasLimits ? " " + root.pct(chip.w.frac) : "")
            color: chip.hasLimits ? root.statusColor(chip.w.status, chip.w.frac) : root.dim
            font.family: root.fontFamily
            font.pixelSize: 10
            font.bold: true
          }
        }
      }
    }

    MouseArea {
      anchors.fill: chipRow
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (bar && bar.showTooltip) bar.showTooltip(button, root.tooltipText())
      onExited: if (bar && bar.hideTooltip) bar.hideTooltip(button)
      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton || mouse.button === Qt.RightButton) refresh()
        else root.toggle()
      }
    }
  }

  // ---------------------------------------------------------------- popup
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "q" || t === "Q") root.close()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: "OMP provider usage" + (root.fetchedAgo() ? " · " + root.fetchedAgo() : "")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              text: root.refreshing ? "…" : "r: refresh"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            visible: root.usageError !== ""
            textFormat: Text.PlainText
            text: root.usageError
            color: "#F38BA8"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.providerRows()

            delegate: Column {
              id: providerSection
              required property var modelData
              width: column.width
              spacing: Style.space(6)

              PanelSectionHeader {
                foreground: root.foreground
                fontFamily: root.fontFamily
                text: {
                  var title = modelData.name
                  if (modelData.meta.planType) title += " · plan: " + modelData.meta.planType
                  else if (modelData.meta.email) title += " · " + modelData.meta.email
                  return title
                }
              }

              Text {
                visible: modelData.burn !== null
                textFormat: Text.PlainText
                text: modelData.burn
                  ? "Today: " + root.formatTokens(modelData.burn.tok) + " tokens · " + root.formatMoney(modelData.burn.cost)
                  : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.uniqueLimits(modelData.limits)

                delegate: Column {
                  id: limitRow
                  required property var modelData
                  width: column.width
                  spacing: 3

                  RowLayout {
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: modelData.label + " (" + ((modelData.window && modelData.window.label) || "?") + ")"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      textFormat: Text.PlainText
                      text: root.pct(modelData.amount ? (modelData.amount.usedFraction || 0) : 0)
                      color: root.statusColor(modelData.status || "ok", modelData.amount ? (modelData.amount.usedFraction || 0) : 0)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }
                  }

                  Rectangle {
                    width: parent.width
                    height: 6
                    radius: 3
                    color: Qt.rgba(1, 1, 1, 0.10)

                    Rectangle {
                      width: parent.width * Math.min(1, Math.max(0, modelData.amount ? (modelData.amount.usedFraction || 0) : 0))
                      height: parent.height
                      radius: parent.radius
                      color: root.statusColor(modelData.status || "ok", modelData.amount ? (modelData.amount.usedFraction || 0) : 0)

                      Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                    }
                  }

                  Text {
                    visible: modelData.window && modelData.window.resetsAt
                    textFormat: Text.PlainText
                    text: modelData.window && modelData.window.resetsAt
                      ? "resets in " + root.formatReset(modelData.window.resetsAt) + " (" + root.clockTime(modelData.window.resetsAt) + ")"
                      : ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              Text {
                visible: modelData.limits.length === 0
                textFormat: Text.PlainText
                text: "No usage limits reported for this provider"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }
}
