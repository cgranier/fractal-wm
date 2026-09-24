import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Fractal Map: a clickable picture of the fractal-wm window tree for the
// active workspace. The tree is a spatial subdivision, so the map is the
// overview layout in miniature: click a window or a container to make it the
// viewport, right-click to zoom to its parent, breadcrumb and framings on top.
// Data comes from the JSON the layout writes on every change; commands go
// through the same layout-message dispatcher the keybindings use.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property int workspaceId: -1
  property string workspaceLayout: ""
  property var status: null            // parsed ws-<id>.json, or null
  property var rects: []
  property string hoverId: ""
  property bool closeOnPick: true
  property string notice: ""

  readonly property string pluginId: (manifest && manifest.id) || "cgranier.fractalmap"
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/fractal-wm"
  readonly property string layoutName: "lua:fractal"
  readonly property bool isFractal: workspaceLayout === layoutName

  readonly property string fontFamily: Style.font.menuFamily
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color dim: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.45)
  readonly property color faint: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.10)
  readonly property color accent: Color.accent
  readonly property color selected: Color.menu.selectedBackground
  readonly property color selectedText: Color.menu.selectedText
  readonly property var borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.space(2)))

  // ---- Lifecycle -----------------------------------------------------------
  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    notice = ""
    hoverId = ""
    clientsJson = ""
    if (payload.workspace !== undefined) {
      workspaceId = parseInt(payload.workspace)
      workspaceLayout = layoutName
      clients.running = true
    } else {
      workspaceId = -1
      activeWorkspace.running = true
    }
    opened = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() { opened = false }

  function dismiss() {
    close()
    if (shell && typeof shell.hide === "function") shell.hide(pluginId)
  }

  function toggle() { if (opened) dismiss(); else open("{}") }

  // ---- Commands -------------------------------------------------------------
  function layoutMsg(msg) {
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.layout(\"" + msg.replace(/"/g, "") + "\")"])
  }

  function zoomTo(id) {
    if (!id) return
    layoutMsg("zoom " + id)
    if (closeOnPick) dismiss()
  }

  function enableHere() {
    if (workspaceId < 0) return
    Quickshell.execDetached(["hyprctl", "eval",
      "hl.workspace_rule({ workspace = \"" + workspaceId + "\", layout = \"" + layoutName + "\" })"])
    workspaceLayout = layoutName
    notice = "Workspace " + workspaceId + " now uses " + layoutName + ". Run `fractal on` once to keep it across reloads."
    refreshTimer.restart()
  }

  function refresh() {
    if (workspaceId < 0) return
    statusFile.reload()
  }

  property string clientsJson: ""

  function applyStatus(text) {
    var parsed = Model.parseStatus(text)
    if (parsed && clientsJson !== "") parsed = Model.prune(parsed, Model.liveAddresses(clientsJson, workspaceId))
    status = parsed
    relayout()
  }

  function relayout() {
    if (!status) { rects = []; return }
    rects = Model.flatten(status, { x: 0, y: 0, w: mapArea.width, h: mapArea.height },
      { pad: Style.space(6), gap: Style.space(3) })
  }

  function handleKey(event) {
    if (event.key === Qt.Key_Escape) { dismiss(); return }
    if (event.key === Qt.Key_Up) { layoutMsg("zoom-out"); return }
    if (event.key === Qt.Key_Down) { layoutMsg("zoom-in"); return }
    if (event.key === Qt.Key_Home) { layoutMsg("zoom-root"); return }
    if (event.key === Qt.Key_Left) { layoutMsg("back"); return }
    if (event.key === Qt.Key_Right) { layoutMsg("forward"); return }
    if (event.key >= Qt.Key_1 && event.key <= Qt.Key_9) { layoutMsg("frame " + (event.key - Qt.Key_0)); return }
    if (event.key === Qt.Key_R) { refresh(); return }
  }

  // ---- Wiring -------------------------------------------------------------
  IpcHandler {
    target: "cgranier.fractalmap"
    function isOpen(): string { return root.opened ? "true" : "false" }
    function workspace(): string { return String(root.workspaceId) }
    function rects(): string { return JSON.stringify(root.rects.map(function(r) { return { id: r.id, kind: r.kind, name: r.name, x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.w), h: Math.round(r.h), viewport: r.viewport, focused: r.focused } })) }
    function refresh(): string { root.refresh(); return "ok" }
    function debug(): string {
      var live = Model.liveAddresses(root.clientsJson, root.workspaceId)
      return JSON.stringify({ workspace: root.workspaceId, layout: root.workspaceLayout, clientsBytes: root.clientsJson.length,
        live: Object.keys(live), windows: root.status ? root.status.windows : null,
        titles: root.rects.filter(function(r) { return r.isWindow }).map(function(r) { return r.name + "|" + r.title }) })
    }
  }

  // hyprctl answers in milliseconds; if it ever hangs, give up rather than
  // hold a process open behind the overlay.
  Timer {
    id: processDeadline
    interval: 3000
    repeat: false
    running: activeWorkspace.running || clients.running
    onTriggered: { activeWorkspace.running = false; clients.running = false }
  }

  Process {
    id: activeWorkspace
    running: false
    command: ["hyprctl", "activeworkspace", "-j"]
    stdout: StdioCollector { id: wsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      var ws = null
      try { ws = JSON.parse(String(wsStdout.text || "{}")) } catch (e) { ws = null }
      root.workspaceId = ws && ws.id !== undefined ? ws.id : -1
      root.workspaceLayout = ws && ws.tiledLayout ? String(ws.tiledLayout) : ""
      clients.running = true
    }
  }

  Process {
    id: clients
    running: false
    command: ["hyprctl", "clients", "-j"]
    stdout: StdioCollector { id: clientsStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.clientsJson = String(clientsStdout.text || "")
      // The file may already be loaded (its path binding fires first), and a
      // reload with unchanged content does not always re-emit loaded.
      root.applyStatus(statusFile.text())
      statusFile.reload()
    }
  }

  FileView {
    id: statusFile
    path: root.workspaceId >= 0 ? root.runtimeDir + "/ws-" + root.workspaceId + ".json" : ""
    watchChanges: root.opened
    printErrors: false
    blockLoading: false
    onLoaded: root.applyStatus(text())
    onLoadFailed: root.applyStatus("")
    onFileChanged: statusFile.reload()
  }

  Timer {
    id: refreshTimer
    interval: 400
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    interval: 120000
    repeat: false
    running: root.opened
    onTriggered: root.dismiss()
  }

  // ---- Surface ------------------------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "cgranier-fractalmap"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: Color.menu.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.dismiss() }

    BorderSurface {
      id: card
      width: Math.min(Math.round(panel.width * 0.78), panel.width - Style.gapsOut * 2)
      height: Math.min(Math.round(header.implicitHeight + Style.space(12) + mapHolder.height + footer.implicitHeight + Style.spacing.panelPadding * 2 + Style.space(12)), panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: keyCatcher.forceActiveFocus() }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { root.handleKey(event); event.accepted = true }
      }

      Column {
        id: body
        anchors.fill: parent
        spacing: Style.space(6)

        // Breadcrumb + framings
        Flow {
          id: header
          width: parent.width
          spacing: Style.space(6)

          Text {
            text: root.workspaceId >= 0 ? ("workspace " + root.workspaceId) : "workspace"
            color: root.dim
            font { family: root.fontFamily; pixelSize: Style.space(13) }
            anchors.verticalCenter: undefined
            height: Style.space(26); verticalAlignment: Text.AlignVCenter
          }

          Repeater {
            model: root.status ? root.status.path : []
            delegate: Rectangle {
              required property var modelData
              required property int index
              readonly property bool last: root.status && index === root.status.path.length - 1
              height: Style.space(26)
              width: crumb.implicitWidth + Style.space(18)
              radius: Style.space(6)
              color: last ? root.selected : (crumbArea.containsMouse ? root.faint : "transparent")
              border.width: 1
              border.color: last ? root.accent : Color.menu.border
              Text {
                id: crumb
                anchors.centerIn: parent
                text: (index > 0 ? "› " : "") + modelData.name
                color: last ? root.selectedText : root.foreground
                font { family: root.fontFamily; pixelSize: Style.space(13) }
              }
              MouseArea {
                id: crumbArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.zoomTo(modelData.id)
              }
            }
          }

          Item { width: Style.space(10); height: 1 }

          Repeater {
            model: root.status ? root.status.framings : []
            delegate: Rectangle {
              required property var modelData
              height: Style.space(26)
              width: frameLabel.implicitWidth + Style.space(18)
              radius: Style.space(13)
              color: frameArea.containsMouse ? root.faint : "transparent"
              border.width: 1
              border.color: root.accent
              Text {
                id: frameLabel
                anchors.centerIn: parent
                text: "⌖ " + modelData.name
                color: root.accent
                font { family: root.fontFamily; pixelSize: Style.space(12) }
              }
              MouseArea {
                id: frameArea
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.layoutMsg("frame " + modelData.name); if (root.closeOnPick) root.dismiss() }
              }
            }
          }
        }

        // The map
        Item {
          id: mapHolder
          width: parent.width
          height: Math.round(width * (panel.height / Math.max(1, panel.width)) * 0.92)

          Item {
            id: mapArea
            anchors.fill: parent
            onWidthChanged: root.relayout()
            onHeightChanged: root.relayout()

            Repeater {
              model: root.rects
              delegate: Rectangle {
                required property var modelData
                readonly property bool hovered: root.hoverId === modelData.id
                readonly property bool isWin: modelData.isWindow
                x: modelData.x; y: modelData.y; width: modelData.w; height: modelData.h
                radius: isWin ? Style.space(4) : Style.space(6)
                color: isWin
                  ? (modelData.focused ? root.selected : (hovered ? root.faint : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, modelData.inViewport ? 0.05 : 0.02)))
                  : (hovered ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.08) : "transparent")
                border.width: modelData.viewport ? Math.max(2, Style.space(2)) : (hovered ? 2 : 1)
                border.color: modelData.viewport ? root.accent : (hovered ? root.accent : (modelData.inViewport ? Color.menu.border : root.faint))
                opacity: modelData.inViewport ? 1.0 : 0.55

                // Container tag, top-left inside the pad
                Text {
                  visible: !parent.isWin && parent.width > Style.space(40) && parent.height > Style.space(16)
                  x: Style.space(4); y: 0
                  text: modelData.kind + (modelData.framing ? "  ⌖ " + modelData.framing : "")
                  color: modelData.viewport ? root.accent : root.dim
                  font { family: root.fontFamily; pixelSize: Style.space(9) }
                }

                // Window label
                Text {
                  visible: parent.isWin && parent.width > Style.space(14) && parent.height > Style.space(10)
                  anchors.centerIn: parent
                  width: parent.width - Style.space(6)
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  text: modelData.isDesktop ? "desktop" : Model.label(modelData, Math.max(3, Math.floor(parent.width / Math.max(6, font.pixelSize * 0.6))))
                  color: modelData.focused ? root.selectedText : (modelData.inViewport ? root.foreground : root.dim)
                  font { family: root.fontFamily; pixelSize: Model.fontFor(modelData, Style.space(9), Style.space(16)) }
                }

                Text {
                  visible: parent.isWin && modelData.title !== "" && modelData.title !== modelData.name && parent.width > Style.space(90) && parent.height > Style.space(44)
                  anchors { horizontalCenter: parent.horizontalCenter; top: parent.verticalCenter; topMargin: Style.space(10) }
                  width: parent.width - Style.space(12)
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideMiddle
                  text: modelData.title
                  color: root.dim
                  font { family: root.fontFamily; pixelSize: Style.space(10) }
                }

                Text {
                  visible: parent.isWin && modelData.focused && parent.width > Style.space(40) && parent.height > Style.space(28)
                  anchors { right: parent.right; bottom: parent.bottom; margins: Style.space(4) }
                  text: "focused"
                  color: root.selectedText
                  font { family: root.fontFamily; pixelSize: Style.space(9) }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.hoverId = modelData.id
                  onExited: if (root.hoverId === modelData.id) root.hoverId = modelData.parentId || ""
                  onClicked: function(mouse) {
                    if (mouse.button === Qt.RightButton) root.zoomTo(modelData.parentId || modelData.id)
                    else root.zoomTo(modelData.id)
                  }
                }
              }
            }

            // Empty / not-fractal states
            Column {
              anchors.centerIn: parent
              spacing: Style.space(10)
              visible: !root.isFractal || !root.status || root.status.windows === 0
              width: parent.width * 0.7
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: !root.isFractal
                  ? ("Workspace " + root.workspaceId + " uses " + (root.workspaceLayout || "another layout") + ", not the fractal layout.")
                  : "No tree yet for this workspace. Open a window and the map fills in."
                color: root.foreground
                font { family: root.fontFamily; pixelSize: Style.space(14) }
              }
              Rectangle {
                visible: !root.isFractal && root.workspaceId >= 0
                anchors.horizontalCenter: parent.horizontalCenter
                width: enableLabel.implicitWidth + Style.space(28)
                height: Style.space(32)
                radius: Style.space(8)
                color: enableArea.containsMouse ? root.selected : "transparent"
                border.width: 1
                border.color: root.accent
                Text {
                  id: enableLabel
                  anchors.centerIn: parent
                  text: "Use the fractal layout here"
                  color: root.accent
                  font { family: root.fontFamily; pixelSize: Style.space(13) }
                }
                MouseArea {
                  id: enableArea
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.enableHere()
                }
              }
            }
          }
        }

        Text {
          id: footer
          width: parent.width
          wrapMode: Text.WordWrap
          text: root.notice !== "" ? root.notice
            : "click: zoom there  ·  right-click: zoom to its parent  ·  ↑ ↓ zoom out / in  ·  ← → back / forward  ·  Home: overview  ·  1–9: framings  ·  Esc: close"
          color: root.dim
          font { family: root.fontFamily; pixelSize: Style.space(11) }
        }
      }
    }
  }
}
