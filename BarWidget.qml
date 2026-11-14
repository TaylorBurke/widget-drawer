import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons

// Bar widget (kind: "bar-widget"). One icon that holds the widgets you have
// parked. The popup lists parked widgets (click to put back on the bar); icons
// are parked by dragging them onto it. Every change shells out to
// bin/drawerctl with an argv array, so the CLI stays the single place that
// reads and writes shell.json.
BarWidget {
  id: root
  moduleName: "taylorburke.widget-drawer"

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, ""))
  readonly property string ctl: pluginDir + "bin/drawerctl"

  property bool popupOpen: false
  function close() { popupOpen = false }

  // Mirrors of `drawerctl list`.
  property var onBar: []
  property var parked: []
  property string lastError: ""

  implicitWidth: glyph.implicitWidth + Style.space(14)
  implicitHeight: barSize

  function refresh() { listProc.running = true }

  property var pending: []
  function run(args) {
    pending.push([ctl].concat(args))
    if (!actionProc.running) next()
  }
  function next() {
    if (pending.length === 0) return
    actionProc.command = pending.shift()
    actionProc.running = true
  }

  Process {
    id: listProc
    command: [root.ctl, "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        // The CLI prints one short JSON line; anything huge is not ours to parse.
        if (text.length > 262144) { root.lastError = "Bar layout listing was too large"; return }
        try {
          var data = JSON.parse(text)
          root.onBar = data.bar || []
          root.parked = data.parked || []
        } catch (e) {
          root.lastError = "Couldn't read the bar layout"
        }
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      onStreamFinished: root.lastError = text.trim().slice(0, 300)
    }
    onStarted: root.lastError = ""
    onExited: { root.refresh(); root.next() }
  }

  // Drag-to-park. Omarchy's bar owns the whole drag and gives plugins no drop
  // target, but it does let you drop a widget into the tray's drawer section.
  // Anything that lands there gets moved into the drawer. Re-checked after the
  // drag ends too, in case the layout write lands after the last change.
  readonly property var trayEntries: (root.bar && root.bar.layoutConfig && root.bar.layoutConfig.tray) || []
  readonly property bool autoPark: root.setting("autoPark", true) !== false
  readonly property bool dragActive: !!root.bar && root.bar.traySectionDragActive === true

  function parkTray() {
    if (!autoPark || dragActive) return
    var waiting = trayEntries.filter(function(e) {
      return (typeof e === "object" ? e.id : e) !== root.moduleName
    })
    if (waiting.length > 0) root.run(["park-tray"])
  }
  // Dropping onto the popup card is outside the bar strip, so the bar treats
  // it as "drag off to remove" and deletes the widget. If the popup was open
  // during the drag, the widget is parked instead, from the entry saved when
  // the drag began (so its settings come back too).
  property var dragSnapshot: null
  property bool popupSeenDuringDrag: false
  property int adoptTries: 0

  function layoutEntries(layout) {
    var out = ({})
    for (var section in (layout || {})) {
      var list = layout[section]
      if (!Array.isArray(list)) continue
      for (var i = 0; i < list.length; i++) {
        var id = typeof list[i] === "object" ? list[i].id : list[i]
        if (id && id !== root.moduleName) out[id] = list[i]
      }
      // Widgets already parked are not removals.
      for (var j = 0; j < list.length; j++) {
        if (typeof list[j] === "object" && list[j].id === root.moduleName)
          (list[j].parked || []).forEach(function(p) { out["parked:" + (typeof p === "object" ? p.id : p)] = true })
      }
    }
    return out
  }

  function checkRemoved() {
    var before = dragSnapshot
    if (!before) { adoptTimer.stop(); return }
    var now = layoutEntries(root.bar ? root.bar.layoutConfig : null)
    var gone = Object.keys(before).filter(function(id) {
      return id.indexOf("parked:") !== 0 && now[id] === undefined && now["parked:" + id] === undefined
    })
    if (gone.length > 0) {
      adoptTimer.stop()
      dragSnapshot = null
      if (autoPark && popupSeenDuringDrag && (!cursorOk || releasedOverCard))
        gone.forEach(function(id) { root.run(["adopt", JSON.stringify(before[id])]) })
      return
    }
    if (++adoptTries >= 6) { adoptTimer.stop(); dragSnapshot = null }
  }

  // The bar holds the mouse grab for the whole drag, so the card gets no hover
  // events. Ask Hyprland where the cursor is instead, while a drag is live and
  // the popup is open. The bar window covers its whole screen, so the popup's
  // anchor rect is in screen coordinates (plus the screen's own origin).
  property bool overCard: false
  property bool dragPanelUp: false
  property bool releasedOverCard: false
  property bool cursorOk: false

  function checkCursor(raw) {
    var pos
    try { pos = JSON.parse(raw) } catch (e) { return }
    if (typeof pos.x !== "number" || typeof pos.y !== "number") return
    cursorOk = true
    var screen = popup.popupScreen
    var left = (screen ? screen.x : 0) + popup.anchor.rect.x
    var top = (screen ? screen.y : 0) + popup.anchor.rect.y
    var slack = Style.space(6)
    overCard = dragPanelUp
      && pos.x >= left - slack && pos.x <= left + popup.implicitWidth + slack
      && pos.y >= top - slack && pos.y <= top + popup.implicitHeight + slack
  }

  Process {
    id: cursorProc
    command: ["hyprctl", "cursorpos", "-j"]
    stdout: StdioCollector { onStreamFinished: root.checkCursor(text) }
  }
  Timer {
    interval: 50
    repeat: true
    running: root.dragPanelUp
    onTriggered: if (!cursorProc.running) cursorProc.running = true
  }

  onTrayEntriesChanged: parkTray()
  onDragActiveChanged: {
    if (dragActive) {
      dragSnapshot = layoutEntries(root.bar ? root.bar.layoutConfig : null)
      popupSeenDuringDrag = popupOpen
      dragPanelUp = popupOpen
      releasedOverCard = false
      adoptTries = 0
    } else {
      releasedOverCard = overCard
      overCard = false
      dragPanelUp = false
      parkSettle.restart()
      if (dragSnapshot) adoptTimer.restart()
    }
  }
  onPopupOpenChanged: {
    if (dragActive && popupOpen) popupSeenDuringDrag = true
    if (!popupOpen) lingerTimer.restart()
  }
  // Keeps the popup mapped through its fade-out, which PopupCard would otherwise do itself.
  Timer { id: lingerTimer; interval: 160 }
  onAutoParkChanged: parkTray()
  Timer { id: parkSettle; interval: 400; onTriggered: root.parkTray() }
  Timer { id: adoptTimer; interval: 500; repeat: true; onTriggered: root.checkRemoved() }

  // Deadlines: list, park and restore are quick CLI calls. If one hangs,
  // kill it rather than leave the queue wedged behind it.
  Timer {
    interval: 5000
    running: listProc.running
    onTriggered: listProc.running = false
  }
  Timer {
    interval: 10000
    running: actionProc.running
    onTriggered: actionProc.running = false
  }

  // Keep the icon and tooltip honest if shell.json is edited elsewhere.
  Timer {
    interval: 30000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Text {
    id: glyph
    anchors.centerIn: parent
    textFormat: Text.PlainText
    text: root.parked.length > 0 ? "󰏗" : "󰏖"   // md-package_variant_closed / md-package_variant
    color: root.bar ? root.bar.barForeground : Color.foreground
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  readonly property bool tooltipHovered: mouseArea.containsMouse

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: { root.popupOpen = !root.popupOpen; if (root.popupOpen) root.refresh() }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.parked.length === 1
      ? "Widget drawer: 1 parked widget" : "Widget drawer: " + root.parked.length + " parked widgets")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  component Tile: Button {
    foreground: root.bar.foreground
    bordered: true
    fontSize: Style.font.bodySmall
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
  }

  // The card body, shared by the popup and by the drag panel below.
  component DrawerBody: Column {
    spacing: Style.space(10)

    Text {
      textFormat: Text.PlainText
      text: "Widget Drawer"
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    // The drop zone: lights up while a dragged icon is over the card.
    Rectangle {
      id: zone
      width: parent.width
      height: zoneColumn.implicitHeight + Style.space(20)
      radius: Style.cornerRadius
      color: root.overCard ? Qt.alpha(root.bar.foreground, 0.14) : "transparent"
      border.width: 1
      border.color: root.overCard ? root.bar.foreground : Qt.alpha(root.bar.foreground, root.dragActive ? 0.55 : 0.2)
      Behavior on color { ColorAnimation { duration: Style.duration(120) } }
      Behavior on border.color { ColorAnimation { duration: Style.duration(120) } }

      Column {
        id: zoneColumn
        x: Style.space(10)
        y: Style.space(10)
        width: parent.width - Style.space(20)
        spacing: Style.space(8)

        PanelSectionHeader {
          text: root.overCard ? "Release to park" : "Parked"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
        }

        Text {
          visible: root.parked.length === 0
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "Nothing parked yet."
          color: Qt.darker(root.bar.foreground, 1.6)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        Flow {
          visible: root.parked.length > 0
          width: parent.width
          spacing: Style.space(6)
          Repeater {
            model: root.parked
            Tile {
              required property var modelData
              iconText: modelData.icon || "󰁝"
              text: modelData.name
              tooltipText: "Put " + modelData.name + " back on the bar"
              onClicked: root.run(["restore", modelData.id])
            }
          }
        }
      }
    }

    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Drag and drop icons from the bar onto this drawer to park them. Click a parked icon to put it back."
      color: Qt.darker(root.bar.foreground, 1.6)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      visible: root.lastError !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: root.lastError
      color: Color.urgent
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    // Hidden while a drag is over it: the popup would paint over the drag ghost.
    // The drag panel stands in for it; see below.
    visible: root.dragPanelUp ? false : (open || lingerTimer.running)
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    DrawerBody {
      id: column
      anchors.fill: parent
    }
  }

  // Hyprland draws a layer surface's popups above every other layer, including
  // the Overlay layer the bar's drag ghost lives on, so the ghost vanished behind
  // the popup. While a drag is live the popup is hidden and this panel, on the
  // Top layer under the ghost, takes its place at the same spot. It takes no
  // input, so it can't disturb the bar's drag.
  PanelWindow {
    id: dragPanel
    visible: root.dragPanelUp && screen !== null
    screen: popup.popupScreen
    anchors { top: true; left: true }
    margins {
      left: Math.round(popup.anchor.rect.x)
      top: Math.round(popup.anchor.rect.y)
    }
    implicitWidth: popup.implicitWidth
    implicitHeight: popup.implicitHeight
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.namespace: "widget-drawer-drag"
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region {}

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Color.popups.background
      border.width: Math.max(1, Style.space(2))
      border.color: Color.popups.border

      Item {
        anchors.fill: parent
        anchors.margins: popup.padding + Math.max(1, Style.space(2))
        DrawerBody { anchors.fill: parent }
      }
    }
  }
}
