import QtQuick
import Quickshell.Io
import qs.Ui
import qs.Commons

// Bar widget (kind: "bar-widget"). One icon that holds the widgets you have
// parked. The popup lists parked widgets (click to put back on the bar) and
// the widgets currently on the bar (click to park). Every change shells out to
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

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: "Widget Drawer"
        color: root.bar.foreground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      PanelSectionHeader {
        text: "Parked · click to put back on the bar"
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
            iconText: "󰁝"
            text: modelData.name
            tooltipText: modelData.id
            onClicked: root.run(["restore", modelData.id])
          }
        }
      }

      PanelSeparator { foreground: root.bar.foreground }

      PanelSectionHeader {
        text: "On the bar · click to park"
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
      }

      // One group per bar section, in bar order, so the tiles read like the bar.
      Repeater {
        model: [
          { key: "left", label: "Left" },
          { key: "center", label: "Center" },
          { key: "right", label: "Right" }
        ]

        Column {
          id: sectionGroup
          required property var modelData
          readonly property var widgets: root.onBar.filter(function(w) { return w.section === sectionGroup.modelData.key })

          visible: widgets.length > 0
          width: column.width
          spacing: Style.space(4)

          Text {
            textFormat: Text.PlainText
            text: sectionGroup.modelData.label
            color: Qt.darker(root.bar.foreground, 1.6)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: sectionGroup.widgets
              Tile {
                required property var modelData
                iconText: "󰁅"
                text: modelData.name
                tooltipText: modelData.id
                onClicked: root.run(["park", modelData.id])
              }
            }
          }
        }
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
  }
}
