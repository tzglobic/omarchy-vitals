import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Live system vitals for the Omarchy bar: CPU with a per-core heat map and a
// one-minute history, memory, GPU, storage, network and disk I/O, and the
// processes behind the numbers. One unprivileged collector streams JSON over
// stdout; the panel talks back over stdin to change cadence, so the rate
// baselines survive open/close.
Panel {
  id: root
  moduleName: "tzglobic.vitals"
  ipcTarget: "vitals"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits and expose refresh/state alongside the usual open/close.
  manageIpc: false

  property var sample: ({})
  property var cpuHistory: []
  property bool collectorReady: false
  property string collectorError: ""

  // Keyboard cursor over the process list, shared with pointer hover so both
  // drive one highlight. A destructive action needs two presses: the first
  // arms the row, the second (within a few seconds) delivers the signal.
  property bool cursorActive: false
  property int cursorIndex: 0
  property int armedPid: 0
  property string armedMode: ""
  property string notice: ""
  property string noticeKind: "info"

  readonly property int refreshIntervalSec: Math.round(Util.clamp(setting("refreshIntervalSec", 2), 1, 60))
  readonly property bool showLabel: setting("showLabel", false) === true
  readonly property bool coresExpanded: setting("coresExpanded", false) === true
  readonly property int processCount: Math.round(Util.clamp(setting("processCount", 8), 3, 20))
  readonly property string temperatureUnit: String(setting("temperatureUnit", "C")).toUpperCase() === "F" ? "F" : "C"
  readonly property int warnPercent: Math.round(Util.clamp(setting("warnPercent", 75), 1, 99))
  readonly property int criticalPercent: Math.round(Util.clamp(setting("criticalPercent", 90), warnPercent + 1, 100))
  readonly property int historySec: 60
  readonly property string glyph: "󰗶"

  readonly property color fg: bar ? bar.foreground : Color.popups.text
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(fg, 1.4)
  readonly property color track: Util.alpha(fg, 0.12)
  readonly property string uiFont: bar ? bar.fontFamily : Style.font.family

  // Plugin-relative path to the collector. Qt hands back a file:// URL;
  // Process needs a plain path.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return url.replace(/\/$/, "")
  }
  readonly property string helper: pluginDir + "/bin/omarchy-vitals"

  readonly property var cpu: sample.cpu || ({})
  readonly property var memory: sample.memory || ({})
  readonly property var gpu: sample.gpu || ({})
  readonly property var io: sample.io || ({})
  readonly property var disks: sample.disks || []
  readonly property var processes: sample.processes || []
  readonly property int visibleProcessCount: Math.min(processCount, processes.length)
  readonly property string level: Model.overallLevel(sample, warnPercent, criticalPercent)
  readonly property string cpuLevel: Model.levelFor(cpu.percent, warnPercent, criticalPercent)
  readonly property string memoryLevel: Model.levelFor(memory.percent, warnPercent, criticalPercent)

  function levelColor(l) {
    return l === "critical" ? root.urgent : (l === "elevated" ? root.accent : root.fg)
  }

  // ------------------------------------------------------------- collector

  function ingest(line) {
    var doc
    try { doc = JSON.parse(line) } catch (e) { return }
    if (!doc || typeof doc !== "object" || !doc.cpu) return
    root.sample = doc
    root.cpuHistory = Model.pushHistory(root.cpuHistory, doc.at, doc.cpu.percent, root.historySec)
    root.collectorReady = true
    root.collectorError = ""
    var n = root.processes.length
    if (root.cursorIndex >= n) root.cursorIndex = Math.max(0, n - 1)
    if (root.armedPid !== 0 && !Model.hasPid(root.processes, root.armedPid)) root.disarm()
  }

  function send(command) {
    if (collector.running) collector.write(command + "\n")
  }

  function refresh() {
    if (collector.running) send("sample")
    else collector.running = true
  }

  // One-second ticks with the process list while the panel is open; the
  // configured cadence without it while closed.
  function applyCadence() {
    send("interval " + (root.opened ? 1 : root.refreshIntervalSec))
    send("procs " + (root.opened ? "on" : "off") + " " + root.processCount)
  }

  // ---------------------------------------------------------------- cursor

  function moveCursor(dy) {
    var n = root.visibleProcessCount
    if (n === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.cursorIndex = dy > 0 ? 0 : n - 1
      root.disarm()
      return
    }
    var next = Math.max(0, Math.min(n - 1, root.cursorIndex + dy))
    if (next !== root.cursorIndex) {
      root.cursorIndex = next
      root.disarm()
    }
  }

  function pointCursor(index) {
    root.cursorActive = true
    if (root.cursorIndex !== index) {
      root.cursorIndex = index
      root.disarm()
    }
  }

  function disarm() {
    root.armedPid = 0
    root.armedMode = ""
    armTimer.stop()
  }

  function requestSignal(index, mode) {
    var p = root.processes[index]
    if (!p) return
    root.pointCursor(index)
    if (p.mine !== true) {
      root.showNotice(p.name + " belongs to another user", "warn")
      return
    }
    if (root.armedPid === p.pid && root.armedMode === mode) {
      root.deliver(mode, p.pid, p.name)
      return
    }
    root.armedPid = p.pid
    root.armedMode = mode
    armTimer.restart()
  }

  function deliver(mode, pid, name) {
    root.disarm()
    actionProc.pendingName = name
    actionProc.command = Model.signalArgs(root.helper, mode, pid)
    actionProc.running = true
  }

  function handleActionResult(raw) {
    var result = {}
    try { result = JSON.parse(String(raw || "").trim()) } catch (e) {}
    if (result.ok) {
      root.showNotice((result.action === "kill" ? "Killed " : "Asked ") + actionProc.pendingName + (result.action === "kill" ? "" : " to quit"), "info")
    } else {
      root.showNotice(result.error || "Could not signal " + actionProc.pendingName, "warn")
    }
  }

  function showNotice(text, kind) {
    root.notice = text
    root.noticeKind = kind || "info"
    noticeTimer.restart()
  }

  function openBtop() {
    if (root.bar) root.bar.run("omarchy-launch-or-focus-tui btop")
    root.close()
  }

  function toggleLabel() {
    root.persistSetting("showLabel", !root.showLabel)
  }

  function toggleCores() {
    root.persistSetting("coresExpanded", !root.coresExpanded)
  }

  // Write one inline setting back to shell.json so the choice survives a
  // shell restart, the same way the power panel remembers its percentage.
  function persistSetting(key, value) {
    var next = {}
    next[key] = value
    root.settings = Object.assign({}, root.settings, next)
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  // Render the open panel card to a PNG. Grabs the item tree directly, so it
  // works even when compositor screen capture is unavailable, and it frames
  // exactly the card — which is what a marketplace preview wants.
  function snapshot(path) {
    if (!root.opened) return false
    var card = keyCatcher.parent && keyCatcher.parent.parent ? keyCatcher.parent.parent : keyCatcher
    return card.grabToImage(function(result) { result.saveToFile(String(path)) })
  }

  IpcHandler {
    target: "vitals"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function btop(): void { root.openBtop() }
    function cores(): void { root.toggleCores() }
    function state(): string { return JSON.stringify(root.sample) }
    function snapshot(path: string): bool { return root.snapshot(path) }
  }

  onOpenedChanged: {
    root.cursorActive = false
    root.cursorIndex = 0
    root.disarm()
    root.notice = ""
    root.applyCadence()
    if (opened) root.refresh()
  }
  onRefreshIntervalSecChanged: root.applyCadence()
  onProcessCountChanged: root.applyCadence()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Process {
    id: collector
    command: [root.helper, "--stream", "--interval", String(root.refreshIntervalSec), "--procs", String(root.processCount), "--no-procs"]
    stdinEnabled: true
    running: true
    stdout: SplitParser {
      onRead: function(line) { root.ingest(line) }
    }
    stderr: SplitParser {
      onRead: function(line) {
        var text = String(line).trim()
        if (text !== "") root.collectorError = text
      }
    }
    onStarted: root.applyCadence()
    onExited: function(code) {
      root.collectorReady = false
      if (root.collectorError === "") root.collectorError = "Collector exited with status " + code
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 5000
    onTriggered: if (!collector.running) collector.running = true
  }

  Process {
    id: actionProc
    property string pendingName: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleActionResult(text)
    }
    onExited: settleTimer.restart()
  }

  // SIGTERM takes a moment to land; re-sample once the process has had time to go.
  Timer { id: settleTimer; interval: 700; onTriggered: root.refresh() }
  Timer { id: armTimer; interval: 4000; onTriggered: root.disarm() }
  Timer { id: noticeTimer; interval: 3200; onTriggered: root.notice = "" }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.showLabel && !vertical
      ? Model.formatPercent(root.cpu.percent) + " " + root.glyph
      : root.glyph
    slotSize: Style.bar.iconSlot * (root.showLabel && !vertical ? 2 : 1)
    active: root.level === "critical"
    // Tooltip suppressed because the panel is the detail view.
    tooltipText: ""
    onPressed: function(b) {
      if (!root.bar) return
      if (b === Qt.RightButton) root.toggleLabel()
      else if (b === Qt.MiddleButton) root.openBtop()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: if (root.cursorActive) root.requestSignal(root.cursorIndex, "term")
      onDeleteRequested: if (root.cursorActive) root.requestSignal(root.cursorIndex, "term")
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r") root.refresh()
        else if (t === "b") root.openBtop()
        else if (t === "c") root.toggleCores()
        else if (t === "K" && root.cursorActive) root.requestSignal(root.cursorIndex, "kill")
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: scroller.width
          spacing: Style.spacing.panelGap

          // ---------- Hero: status-colored glyph · title · host line · btop ----------
          PanelHero {
            foreground: root.fg
            fontFamily: root.uiFont
            title: "Vitals"
            meta: root.collectorReady
              ? Model.hostLine(root.sample)
              : (root.collectorError !== "" ? "Collector unavailable" : "Warming up")
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.glyph
                color: root.levelColor(root.level)
                font.family: root.uiFont
                font.pixelSize: Style.font.display
                Behavior on color { ColorAnimation { duration: 240 } }
              }
            }
            trailingControl: Component {
              Button {
                iconText: "󰆍"
                text: "btop"
                bordered: true
                foreground: root.fg
                fontFamily: root.uiFont
                fontSize: Style.font.bodySmall
                iconSize: Style.font.body
                tooltipText: "Open btop (b)"
                onClicked: root.openBtop()
              }
            }
          }

          Text {
            visible: !root.collectorReady && root.collectorError !== ""
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.collectorError
            color: root.urgent
            font.family: root.uiFont
            font.pixelSize: Style.font.caption
          }

          // ---------- CPU: header · history · per-core heat map ----------
          Column {
            width: parent.width
            spacing: Style.space(8)

            MetricHeader {
              icon: "󰘚"
              label: "CPU"
              value: Model.formatPercent(root.cpu.percent)
              valueColor: root.levelColor(root.cpuLevel)
              detail: Model.cpuDetail(root.cpu, root.temperatureUnit)
            }

            Sparkline {
              width: parent.width
              height: Style.space(52)
              history: root.cpuHistory
              lineColor: root.levelColor(root.cpuLevel)
            }

            // Disclosure row for the per-core meters. Borderless and
            // left-aligned so it reads as a list row, not a form control;
            // collapsed, it still names the busiest core.
            Button {
              width: parent.width
              visible: (root.cpu.cores ? root.cpu.cores.length : 0) > 0
              leftAlign: true
              iconText: root.coresExpanded ? "󰅀" : "󰅂"
              text: Model.coresSummary(root.cpu.cores, root.coresExpanded)
              foreground: root.fg
              fontFamily: root.uiFont
              fontSize: Style.font.caption
              iconSize: Style.font.caption
              horizontalPadding: Style.space(8)
              verticalPadding: Style.space(4)
              tooltipText: root.coresExpanded ? "Collapse per-core meters (c)" : "Expand per-core meters (c)"
              onClicked: root.toggleCores()
            }

            Item {
              id: coresDrawer
              width: parent.width
              clip: true
              height: root.coresExpanded ? coreGrid.implicitHeight : 0
              implicitHeight: height
              visible: root.coresExpanded || height > 0
              Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

              CoreGrid {
                id: coreGrid
                width: parent.width
                cores: root.cpu.cores || []
              }
            }
          }

          // ---------- Memory: header · used/cached bar · legend · swap ----------
          Column {
            width: parent.width
            spacing: Style.space(8)

            MetricHeader {
              icon: "󰍛"
              label: "Memory"
              value: Model.formatPercent(root.memory.percent)
              valueColor: root.levelColor(root.memoryLevel)
              detail: Model.memoryDetail(root.memory)
            }

            SegmentBar {
              width: parent.width
              height: Style.space(8)
              fractions: Model.memoryFractions(root.memory)
              fill: root.levelColor(root.memoryLevel)
            }

            Row {
              spacing: Style.space(14)
              Legend { swatch: root.levelColor(root.memoryLevel); label: "Used " + Model.formatBytes(root.memory.usedBytes) }
              Legend { swatch: Util.alpha(root.levelColor(root.memoryLevel), 0.35); label: "Cached " + Model.formatBytes(root.memory.cachedBytes) }
              Legend { swatch: root.track; label: "Free " + Model.formatBytes(root.memory.freeBytes) }
            }

            Item {
              visible: root.memory.swapTotalBytes > 0
              width: parent.width
              implicitHeight: swapLabel.implicitHeight + Style.space(4) + Style.space(4)

              Text {
                id: swapLabel
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.top: parent.top
                text: "Swap"
                color: root.dim
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.top: parent.top
                text: Model.swapDetail(root.memory)
                color: root.dim
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
              }

              SegmentBar {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: Style.space(4)
                fractions: ({ used: Util.clamp(root.memory.swapPercent, 0, 100) / 100, cached: 0 })
                fill: Util.alpha(root.fg, 0.55)
              }
            }
          }

          // ---------- Stat tiles: network · disk I/O · GPU · storage ----------
          Grid {
            id: tiles
            width: parent.width
            columns: 2
            columnSpacing: Style.space(10)
            rowSpacing: Style.space(10)
            readonly property real cell: (width - columnSpacing) / 2

            StatTile {
              width: tiles.cell
              icon: "󰌗"
              label: "Network"
              value: "󰇚 " + Model.formatRate(root.io.netRxBps)
              sub: "󰕒 " + Model.formatRate(root.io.netTxBps)
            }

            StatTile {
              width: tiles.cell
              icon: "󰋊"
              label: "Disk I/O"
              value: "󰇚 " + Model.formatRate(root.io.diskReadBps)
              sub: "󰕒 " + Model.formatRate(root.io.diskWriteBps)
            }

            StatTile {
              visible: root.gpu.available === true
              width: tiles.cell
              icon: "󰢮"
              label: root.gpu.name || "GPU"
              value: Model.formatPercent(root.gpu.percent)
              valueColor: root.levelColor(Model.levelFor(root.gpu.percent, root.warnPercent, root.criticalPercent))
              sub: Model.gpuDetail(root.gpu, root.temperatureUnit)
              fraction: Util.clamp(root.gpu.percent, 0, 100) / 100
            }

            Repeater {
              model: root.disks.length
              delegate: StatTile {
                required property int index
                readonly property var disk: root.disks[index] || ({})
                width: tiles.cell
                icon: "󰋊"
                label: "Storage " + (disk.path || "")
                value: Model.storageValue(disk)
                valueColor: root.levelColor(Model.levelFor(disk.percent, root.warnPercent, root.criticalPercent))
                sub: Model.storageDetail(disk)
                fraction: Util.clamp(disk.percent, 0, 100) / 100
              }
            }
          }

          // ---------- Top processes ----------
          PanelSeparator { foreground: root.fg }

          Column {
            width: parent.width
            spacing: Style.space(4)

            Item {
              width: parent.width
              implicitHeight: Math.max(processHeader.implicitHeight, processHint.implicitHeight)

              PanelSectionHeader {
                id: processHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "TOP PROCESSES"
                foreground: root.fg
                fontFamily: root.uiFont
              }

              Text {
                id: processHint
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.notice !== ""
                  ? root.notice
                  : (root.armedPid !== 0 ? "Press again to confirm" : "x end · K kill · b btop")
                color: (root.notice !== "" && root.noticeKind === "warn") || root.armedPid !== 0 ? root.urgent : root.dim
                font.family: root.uiFont
                font.pixelSize: Style.font.caption
                Behavior on color { ColorAnimation { duration: 120 } }
              }
            }

            Text {
              visible: root.visibleProcessCount === 0
              width: parent.width
              textFormat: Text.PlainText
              text: root.collectorReady ? "Collecting…" : "Waiting for the collector"
              color: root.dim
              font.family: root.uiFont
              font.pixelSize: Style.font.bodySmall
              topPadding: Style.space(4)
            }

            // Model is a count, not the array, so rows persist across ticks and
            // their bars animate instead of being rebuilt every second.
            Repeater {
              model: root.visibleProcessCount
              delegate: ProcessRow {
                required property int index
                rowIndex: index
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ components

  component MetricHeader: Item {
    property string icon: ""
    property string label: ""
    property string value: ""
    property string detail: ""
    property color valueColor: root.fg

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(leading.implicitHeight, trailing.implicitHeight)

    Row {
      id: leading
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: icon
        color: root.dim
        font.family: root.uiFont
        font.pixelSize: Style.font.icon
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: label
        color: root.fg
        font.family: root.uiFont
        font.pixelSize: Style.font.body
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Row {
      id: trailing
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: detail
        visible: detail !== ""
        color: root.dim
        font.family: root.uiFont
        font.pixelSize: Style.font.caption
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: value
        color: valueColor
        font.family: root.uiFont
        font.pixelSize: Style.font.subtitle
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
        Behavior on color { ColorAnimation { duration: 240 } }
      }
    }
  }

  // One minute of CPU history. Newest sample sits on the right edge; the area
  // under the line is a translucent wash of the same color.
  component Sparkline: Item {
    id: spark
    property var history: []
    property color lineColor: root.accent

    readonly property real pad: Style.spaceReal(3)
    readonly property var points: Model.sparklinePoints(history, width, height, root.historySec, pad)
    readonly property var area: Model.sparklineArea(points, height)
    readonly property var lastPoint: points.length > 0 ? points[points.length - 1] : null

    function toPointList(list) {
      var out = []
      for (var i = 0; i < list.length; i++) out.push(Qt.point(list[i].x, list[i].y))
      return out
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Util.alpha(root.fg, 0.04)
      border.width: 1
      border.color: Util.alpha(root.fg, 0.07)
    }

    Repeater {
      model: [0.25, 0.5, 0.75]
      delegate: Rectangle {
        required property var modelData
        x: 1
        width: spark.width - 2
        height: 1
        y: Math.round(spark.pad + (1 - modelData) * (spark.height - 2 * spark.pad))
        color: Util.alpha(root.fg, 0.06)
      }
    }

    Shape {
      anchors.fill: parent
      antialiasing: true
      layer.enabled: true
      layer.samples: 4
      visible: spark.points.length > 1

      ShapePath {
        strokeWidth: 0
        strokeColor: "transparent"
        fillColor: Util.alpha(spark.lineColor, 0.16)
        startX: spark.area.length > 0 ? spark.area[0].x : 0
        startY: spark.area.length > 0 ? spark.area[0].y : 0
        PathPolyline { path: spark.toPointList(spark.area) }
      }

      ShapePath {
        strokeWidth: Math.max(1.5, Style.spaceReal(1.5))
        strokeColor: spark.lineColor
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: spark.points.length > 0 ? spark.points[0].x : 0
        startY: spark.points.length > 0 ? spark.points[0].y : 0
        PathPolyline { path: spark.toPointList(spark.points) }
      }
    }

    Rectangle {
      visible: spark.lastPoint !== null
      width: Style.space(6)
      height: width
      radius: width / 2
      color: spark.lineColor
      x: spark.lastPoint ? spark.lastPoint.x - width / 2 : 0
      y: spark.lastPoint ? spark.lastPoint.y - width / 2 : 0
      Behavior on color { ColorAnimation { duration: 240 } }
    }

    Text {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.margins: Style.space(5)
      textFormat: Text.PlainText
      text: root.historySec + "S"
      color: Util.alpha(root.fg, 0.35)
      font.family: root.uiFont
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1
    }
  }

  // Per-core meters: one slender vertical bar per logical core, up to sixteen
  // to a row, filling upward with load. The model is a count so bars persist
  // across ticks and animate instead of being rebuilt every second.
  component CoreGrid: Grid {
    id: grid
    property var cores: []

    columns: Model.meterColumns(cores.length)
    rowSpacing: Style.space(8)
    columnSpacing: Style.space(3)
    readonly property real cell: columns > 0 ? (width - columnSpacing * (columns - 1)) / columns : 0

    Repeater {
      model: grid.cores.length
      delegate: Item {
        id: coreCell
        required property int index
        readonly property real load: Util.clamp(grid.cores[index], 0, 100)
        readonly property string cellLevel: Model.levelFor(load, root.warnPercent, root.criticalPercent)
        readonly property color meterColor: cellLevel === "critical" ? root.urgent : root.accent

        width: grid.cell
        height: Style.space(46)

        Rectangle {
          id: meterTrack
          anchors.top: parent.top
          anchors.bottom: coreLabel.top
          anchors.bottomMargin: Style.space(3)
          anchors.horizontalCenter: parent.horizontalCenter
          width: Math.max(Style.space(4), Math.min(Style.space(10), Math.round(parent.width * 0.5)))
          radius: width / 2
          color: root.track

          Rectangle {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width
            // A loaded core always shows at least a rounded nub.
            height: coreCell.load > 0 ? Math.max(parent.width, parent.height * coreCell.load / 100) : 0
            radius: parent.radius
            color: coreCell.meterColor
            opacity: 0.35 + 0.65 * coreCell.load / 100

            Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 250 } }
          }
        }

        Text {
          id: coreLabel
          anchors.bottom: parent.bottom
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: (coreCell.index + 1 < 10 ? "0" : "") + (coreCell.index + 1)
          color: coreCell.load >= root.warnPercent ? coreCell.meterColor : root.dim
          font.family: root.uiFont
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: heatMouse
          anchors.fill: parent
          hoverEnabled: true
        }

        PanelToolTip {
          visible: heatMouse.containsMouse
          text: "Core " + (coreCell.index + 1) + " · " + Math.round(coreCell.load) + "%"
          fontFamily: root.uiFont
        }
      }
    }
  }

  // Track with a solid `used` segment and a translucent `cached` segment.
  component SegmentBar: Item {
    property var fractions: ({ used: 0, cached: 0 })
    property color fill: root.accent

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height
      radius: height / 2
      width: parent.width * Util.clamp((fractions.used || 0) + (fractions.cached || 0), 0, 1)
      color: Util.alpha(fill, 0.35)
      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
    }

    Rectangle {
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height
      radius: height / 2
      width: parent.width * Util.clamp(fractions.used || 0, 0, 1)
      color: fill
      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }

  component Legend: Row {
    property color swatch: root.fg
    property string label: ""
    spacing: Style.space(5)

    Rectangle {
      width: Style.space(8)
      height: width
      radius: Style.space(2)
      color: swatch
      anchors.verticalCenter: parent.verticalCenter
      Behavior on color { ColorAnimation { duration: 240 } }
    }

    Text {
      textFormat: Text.PlainText
      text: label
      color: root.dim
      font.family: root.uiFont
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  component StatTile: BorderSurface {
    id: tile
    property string icon: ""
    property string label: ""
    property string value: ""
    property string sub: ""
    property real fraction: -1
    property color valueColor: root.fg

    implicitHeight: tileColumn.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: Style.normalFillFor(root.fg, root.accent)
    borderSpec: Border.controlSpec("normal", root.fg, root.accent)

    Column {
      id: tileColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(3)

      Row {
        width: parent.width
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          text: tile.icon
          color: root.dim
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width - parent.spacing - parent.children[0].implicitWidth
          text: tile.label.toUpperCase()
          color: root.dim
          font.family: root.uiFont
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.2
          elide: Text.ElideRight
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: tile.value
        color: tile.valueColor
        font.family: root.uiFont
        font.pixelSize: Style.font.subtitle
        font.bold: true
        elide: Text.ElideRight
        Behavior on color { ColorAnimation { duration: 240 } }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: tile.sub !== ""
        text: tile.sub
        color: root.dim
        font.family: root.uiFont
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Item {
        visible: tile.fraction >= 0
        width: parent.width
        implicitHeight: Style.space(4) + Style.space(6)

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Style.space(4)
          radius: height / 2
          color: root.track

          Rectangle {
            anchors.left: parent.left
            height: parent.height
            radius: parent.radius
            width: Math.max(height, parent.width * Util.clamp(tile.fraction, 0, 1))
            color: tile.valueColor
            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 240 } }
          }
        }
      }
    }
  }

  component ProcessRow: CursorSurface {
    id: row
    property int rowIndex: 0
    readonly property var proc: root.processes[rowIndex] || ({})
    readonly property bool armed: root.armedPid !== 0 && root.armedPid === proc.pid
    readonly property bool mine: proc.mine === true
    readonly property string procLevel: Model.levelFor(proc.cpuPercent, root.warnPercent, root.criticalPercent)

    width: column.width
    implicitHeight: Style.spacing.popupRowHeight + Style.space(8)
    foreground: root.fg
    accent: root.accent
    hasCursor: root.cursorActive && root.cursorIndex === rowIndex

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onEntered: root.pointCursor(row.rowIndex)
      onClicked: root.pointCursor(row.rowIndex)
    }

    Item {
      anchors.fill: parent
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.space(4)

      Column {
        anchors.left: parent.left
        anchors.right: cpuColumn.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: row.armed
            ? (root.armedMode === "kill" ? "Force kill " : "End ") + (row.proc.name || "") + "?"
            : (row.proc.name || "")
          color: row.armed ? root.urgent : (row.mine ? root.fg : root.dim)
          font.family: root.uiFont
          font.pixelSize: Style.font.body
          font.bold: row.armed
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: "PID " + (row.proc.pid || "") + (row.mine ? "" : " · system")
          color: root.dim
          font.family: root.uiFont
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Row {
        id: cpuColumn
        anchors.right: memText.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)

        Rectangle {
          width: Style.space(40)
          height: Style.space(4)
          radius: height / 2
          color: root.track
          anchors.verticalCenter: parent.verticalCenter

          Rectangle {
            anchors.left: parent.left
            height: parent.height
            radius: parent.radius
            width: parent.width * Util.clamp(row.proc.cpuPercent, 0, 100) / 100
            color: root.levelColor(row.procLevel)
            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 240 } }
          }
        }

        Text {
          width: Style.space(46)
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: (Number(row.proc.cpuPercent) || 0).toFixed(1) + "%"
          color: root.levelColor(row.procLevel)
          font.family: root.uiFont
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
          Behavior on color { ColorAnimation { duration: 240 } }
        }
      }

      Text {
        id: memText
        width: Style.space(58)
        anchors.right: actionButton.left
        anchors.rightMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        text: Model.formatBytes(row.proc.rssBytes)
        color: root.dim
        font.family: root.uiFont
        font.pixelSize: Style.font.bodySmall
      }

      PanelActionButton {
        id: actionButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        iconText: row.armed ? "󰄬" : "󰅖"
        foreground: row.armed ? root.urgent : root.dim
        hoverColor: root.urgent
        fontFamily: root.uiFont
        enabled: row.mine
        tooltipText: !row.mine ? "Owned by another user" : (row.armed ? "Click again to confirm" : "End process (x)")
        onClicked: root.requestSignal(row.rowIndex, "term")
      }
    }
  }
}
