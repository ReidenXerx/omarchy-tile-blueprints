import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "BlueprintModel.js" as Model

// The blueprint editor: a full-screen overlay with one canvas per workspace, drawn in the
// screen's own proportions, where each tile says which apps live in it.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null
  property bool opened: false

  readonly property string helper: localPath("bin/tile-blueprints")
  readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
    + "/omarchy/tile-blueprints.json"

  function localPath(rel) {
    return decodeURIComponent(String(Qt.resolvedUrl(rel)).replace("file://", ""))
  }

  // ---------------------------------------------------------------- theme

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color accent: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily

  // ---------------------------------------------------------------- state

  property var saved: ({ version: 1, workspaces: {} })
  property var draft: ({ version: 1, workspaces: {} })
  property int workspace: 1
  property string selected: "t1"
  property bool dirty: false
  property bool confirmDiscard: false
  property string status: ""

  property var apps: []
  property bool pickerOpen: false
  property string pickerQuery: ""
  property int pickerIndex: 0

  readonly property var current: draft.workspaces[String(workspace)] || Model.defaultWorkspace()
  readonly property var geometry: Model.layout(current.root, { x: 0, y: 0, w: canvas.width, h: canvas.height })
  readonly property var selectedTile: Model.findLeaf(current.root, selected)
  readonly property var pickerApps: filterApps(apps, pickerQuery)

  // ---------------------------------------------------------------- shell contract

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) { payload = {} }
    root.opened = true
    configFile.reload()
    root.draft = Model.clone(root.saved)
    root.dirty = false
    root.confirmDiscard = false
    root.pickerOpen = false
    root.status = ""
    if (Number(payload.workspace) >= 1) root.showWorkspace(Number(payload.workspace))
    else { root.showWorkspace(root.workspace); activeWorkspaceProc.running = true }
    appsProc.running = true
    Qt.callLater(function() { keys.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.pickerOpen = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "reidenxerx.tile-blueprints")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---------------------------------------------------------------- data

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.loadSaved(text())
    onLoadFailed: root.loadSaved("")
  }

  function loadSaved(raw) {
    var parsed = null
    try { parsed = raw ? JSON.parse(raw) : null } catch (e) { parsed = null }
    root.saved = Model.normalizeFile(parsed)
    if (!root.dirty) {
      root.draft = Model.clone(root.saved)
      root.showWorkspace(root.workspace)
    }
  }

  Process {
    id: appsProc
    command: [root.helper, "apps"]
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.apps = JSON.parse(text) || [] } catch (e) { root.apps = [] }
      }
    }
  }

  Process {
    id: activeWorkspaceProc
    command: ["hyprctl", "-j", "activeworkspace"]
    stdout: StdioCollector {
      onStreamFinished: {
        var ws = null
        try { ws = JSON.parse(text) } catch (e) { ws = null }
        if (ws && Number(ws.id) >= 1 && Number(ws.id) <= 10) root.showWorkspace(Number(ws.id))
      }
    }
  }

  Process {
    id: captureProc
    stdout: StdioCollector { onStreamFinished: root.finishCapture(text) }
  }

  // ---------------------------------------------------------------- edits

  function showWorkspace(n) {
    root.workspace = n
    var tiles = Model.order(root.current.root)
    if (tiles.indexOf(root.selected) < 0) root.selected = tiles[0]
    root.pickerOpen = false
  }

  function commit(ws, nextSelected, message) {
    var next = Model.clone(root.draft)
    next.workspaces[String(root.workspace)] = ws
    root.draft = next
    if (nextSelected) root.selected = nextSelected
    root.dirty = true
    root.confirmDiscard = false
    root.status = message || ""
  }

  function editRoot(newRoot, nextSelected, message) {
    var ws = Model.clone(root.current)
    ws.root = newRoot
    root.commit(ws, nextSelected, message)
  }

  function splitSelected(dir) {
    var r = Model.split(root.current.root, root.selected, dir)
    root.editRoot(r.root, r.id)
  }

  function removeSelected() {
    if (Model.isLeaf(root.current.root)) { root.status = "A blueprint keeps at least one tile"; return }
    var r = Model.remove(root.current.root, root.selected)
    root.editRoot(r.root, r.id)
  }

  function growSelected(axis, delta) {
    root.editRoot(Model.grow(root.current.root, root.selected, axis, delta), root.selected)
  }

  function moveSelection(dx, dy) {
    root.selected = Model.neighbour(root.current.root, root.selected, dx, dy)
  }

  function cycleSelection(delta) {
    var tiles = Model.order(root.current.root)
    var i = tiles.indexOf(root.selected)
    root.selected = tiles[(i + delta + tiles.length) % tiles.length]
  }

  function assignApp(app) {
    if (!app) return
    root.editRoot(Model.assign(root.current.root, root.selected, app), root.selected,
                  (app.name || app["class"]) + " now opens in this tile")
    root.pickerOpen = false
    keys.forceActiveFocus()
  }

  function removeApp(tileId, cls) {
    root.editRoot(Model.unassign(root.current.root, tileId, cls), tileId)
  }

  function removeLastApp() {
    var tile = root.selectedTile
    if (tile && tile.apps.length > 0) root.removeApp(tile.id, tile.apps[tile.apps.length - 1]["class"])
  }

  function toggleFlag(flag) {
    var ws = Model.clone(root.current)
    ws[flag] = !ws[flag]
    root.commit(ws, root.selected, flag === "launch"
      ? (ws.launch ? "Apps here launch at login" : "Apps here no longer launch at login")
      : (ws.pin ? "Apps here always open on this workspace" : "Apps here open wherever you launch them"))
  }

  function clearWorkspace() {
    root.commit(Model.defaultWorkspace(), "t1", "Workspace " + root.workspace + " cleared")
  }

  function startCapture() {
    root.status = "Capturing workspace " + root.workspace + "…"
    captureProc.command = [root.helper, "windows", String(root.workspace)]
    captureProc.running = true
  }

  function finishCapture(raw) {
    var windows = []
    try { windows = JSON.parse(raw) || [] } catch (e) { windows = [] }
    if (windows.length === 0) { root.status = "No tiled windows on workspace " + root.workspace + " to capture"; return }
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i]
      minX = Math.min(minX, w.x); minY = Math.min(minY, w.y)
      maxX = Math.max(maxX, w.x + w.w); maxY = Math.max(maxY, w.y + w.h)
    }
    var tree = Model.capture(windows, { x: minX, y: minY, w: maxX - minX, h: maxY - minY })
    var ws = Model.clone(root.current)
    ws.root = Model.normalize(tree)
    root.commit(ws, Model.order(ws.root)[0],
                "Captured " + windows.length + " window" + (windows.length === 1 ? "" : "s") + " from workspace " + root.workspace)
  }

  function save() {
    var out = { version: 1, workspaces: {} }
    for (var key in root.draft.workspaces) {
      if (Model.isMeaningful(root.draft.workspaces[key])) out.workspaces[key] = root.draft.workspaces[key]
    }
    Quickshell.execDetached([root.helper, "write", JSON.stringify(out)])
    root.saved = Model.clone(out)
    root.draft = Model.clone(out)
    root.showWorkspace(root.workspace)
    root.dirty = false
    root.confirmDiscard = false
    root.status = "Saved and applied"
  }

  function requestClose() {
    if (root.pickerOpen) { root.pickerOpen = false; keys.forceActiveFocus(); return }
    if (root.dirty && !root.confirmDiscard) {
      root.confirmDiscard = true
      root.status = "Unsaved changes: Esc again to discard, Ctrl+S to save"
      return
    }
    root.dismiss()
  }

  function openPicker() {
    root.pickerQuery = ""
    root.pickerIndex = 0
    root.pickerOpen = true
    if (root.apps.length === 0) appsProc.running = true
    Qt.callLater(function() { pickerSearch.text = ""; pickerSearch.forceActiveFocus() })
  }

  function filterApps(list, query) {
    var q = String(query || "").trim().toLowerCase()
    if (!q) return list
    return list.filter(function(a) {
      return String(a.name).toLowerCase().indexOf(q) >= 0 || String(a["class"]).toLowerCase().indexOf(q) >= 0
    })
  }

  function workspaceHasBlueprint(n) {
    return Model.isMeaningful(root.draft.workspaces[String(n)])
  }

  function percent(value, total) {
    return total > 0 ? Math.round(value / total * 100) + "%" : ""
  }

  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var k = event.key
    var step = 0.05
    var handled = true

    if (k === Qt.Key_Escape) root.requestClose()
    else if (ctrl && k === Qt.Key_S) root.save()
    else if (ctrl && (k === Qt.Key_Delete || k === Qt.Key_Backspace)) root.clearWorkspace()
    else if (k >= Qt.Key_1 && k <= Qt.Key_9 && !ctrl) root.showWorkspace(k - Qt.Key_0)
    else if (k === Qt.Key_0 && !ctrl) root.showWorkspace(10)
    else if (shift && (k === Qt.Key_Right || k === Qt.Key_L)) root.growSelected("h", step)
    else if (shift && (k === Qt.Key_Left || k === Qt.Key_H)) root.growSelected("h", -step)
    else if (shift && (k === Qt.Key_Down || k === Qt.Key_J)) root.growSelected("v", step)
    else if (shift && (k === Qt.Key_Up || k === Qt.Key_K)) root.growSelected("v", -step)
    else if (k === Qt.Key_Right || k === Qt.Key_L) root.moveSelection(1, 0)
    else if (k === Qt.Key_Left || k === Qt.Key_H) root.moveSelection(-1, 0)
    else if (k === Qt.Key_Down || k === Qt.Key_J) root.moveSelection(0, 1)
    else if (k === Qt.Key_Up || k === Qt.Key_K) root.moveSelection(0, -1)
    else if (k === Qt.Key_Tab) root.cycleSelection(1)
    else if (k === Qt.Key_Backtab) root.cycleSelection(-1)
    else if (k === Qt.Key_Bar || k === Qt.Key_Backslash || k === Qt.Key_V) root.splitSelected("h")
    else if (k === Qt.Key_Minus || k === Qt.Key_S) root.splitSelected("v")
    else if (k === Qt.Key_X || k === Qt.Key_Delete) root.removeSelected()
    else if (k === Qt.Key_A || k === Qt.Key_Return || k === Qt.Key_Enter) root.openPicker()
    else if (k === Qt.Key_Backspace) root.removeLastApp()
    else if (k === Qt.Key_C) root.startCapture()
    else if (k === Qt.Key_P) root.toggleFlag("pin")
    else if (k === Qt.Key_O) root.toggleFlag("launch")
    else handled = false

    if (handled) event.accepted = true
  }

  // ---------------------------------------------------------------- ui

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-tile-blueprints"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: root.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.requestClose() }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(1080), panel.width - Style.gapsOut * 4)
      height: Math.min(Style.space(760), panel.height - Style.gapsOut * 4)
      radius: root.cornerRadius
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: keys.forceActiveFocus() }

      Item {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { root.handleKey(event) }
      }

      Column {
        id: content
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.lg

        // ------------------------------------------------ header
        Item {
          width: parent.width
          height: Style.space(34)

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Tile blueprints"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xs

            Repeater {
              model: 10
              delegate: Rectangle {
                id: wsTab
                required property int index
                readonly property int number: index + 1
                readonly property bool active: root.workspace === number
                width: Style.space(34)
                height: Style.space(30)
                radius: root.cornerRadius
                color: active ? root.selectedBackground : "transparent"
                border.width: active ? Math.max(1, Style.space(1)) : 0
                border.color: root.accent

                Text {
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: wsTab.number === 10 ? "10" : String(wsTab.number)
                  color: wsTab.active ? root.accent : root.foreground
                  opacity: wsTab.active || root.workspaceHasBlueprint(wsTab.number) ? 1 : 0.45
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                }

                Rectangle {
                  visible: root.workspaceHasBlueprint(wsTab.number)
                  anchors.horizontalCenter: parent.horizontalCenter
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.space(3)
                  width: Style.space(4); height: width; radius: width / 2
                  color: root.accent
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.showWorkspace(wsTab.number); keys.forceActiveFocus() }
                }
              }
            }
          }
        }

        // ------------------------------------------------ canvas + picker
        Item {
          id: stage
          width: parent.width
          height: content.height - Style.space(34) - footer.height - content.spacing * 2

          readonly property real pickerWidth: root.pickerOpen ? Style.space(300) : 0
          readonly property real aspect: panel.width > 0 && panel.height > 0 ? panel.width / panel.height : 16 / 10

          Item {
            id: canvasFrame
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width - stage.pickerWidth - (root.pickerOpen ? Style.spacing.lg : 0)

            Rectangle {
              id: canvas
              anchors.centerIn: parent
              width: Math.min(parent.width, parent.height * stage.aspect)
              height: width / stage.aspect
              radius: root.cornerRadius
              color: Util.alpha(root.foreground, 0.04)
              border.width: Math.max(1, Style.space(1))
              border.color: Util.alpha(root.foreground, 0.12)

              Repeater {
                model: root.geometry.tiles

                delegate: Rectangle {
                  id: tile
                  required property var modelData
                  readonly property bool isSelected: modelData.id === root.selected
                  readonly property real gap: Style.space(4)

                  x: modelData.x + gap
                  y: modelData.y + gap
                  width: Math.max(0, modelData.w - gap * 2)
                  height: Math.max(0, modelData.h - gap * 2)
                  radius: root.cornerRadius
                  color: isSelected ? root.selectedBackground : Util.alpha(root.foreground, 0.06)
                  border.width: isSelected ? Math.max(2, Style.space(2)) : Math.max(1, Style.space(1))
                  border.color: isSelected ? root.accent : Util.alpha(root.foreground, 0.18)

                  MouseArea {
                    anchors.fill: parent
                    onClicked: { root.selected = tile.modelData.id; keys.forceActiveFocus() }
                    onDoubleClicked: { root.selected = tile.modelData.id; root.openPicker() }
                  }

                  Text {
                    anchors.top: parent.top
                    anchors.right: parent.right
                    anchors.margins: Style.spacing.md
                    textFormat: Text.PlainText
                    text: root.percent(tile.modelData.w, canvas.width) + " × " + root.percent(tile.modelData.h, canvas.height)
                    color: root.foreground
                    opacity: 0.45
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    visible: tile.width > Style.space(90)
                  }

                  Column {
                    anchors.centerIn: parent
                    width: parent.width - Style.spacing.lg * 2
                    spacing: Style.spacing.sm

                    Repeater {
                      model: tile.modelData.apps

                      delegate: Rectangle {
                        id: chip
                        required property var modelData
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(parent.width, chipText.implicitWidth + chipX.width + Style.spacing.lg * 2)
                        height: Style.space(26)
                        radius: height / 2
                        color: Util.alpha(root.accent, 0.18)

                        Text {
                          id: chipText
                          anchors.left: parent.left
                          anchors.leftMargin: Style.spacing.lg
                          anchors.right: chipX.left
                          anchors.verticalCenter: parent.verticalCenter
                          textFormat: Text.PlainText
                          text: chip.modelData.name || chip.modelData["class"]
                          color: root.foreground
                          elide: Text.ElideRight
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                        }

                        Text {
                          id: chipX
                          anchors.right: parent.right
                          anchors.rightMargin: Style.spacing.md
                          anchors.verticalCenter: parent.verticalCenter
                          textFormat: Text.PlainText
                          text: "×"
                          color: root.foreground
                          opacity: 0.6
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.title

                          MouseArea {
                            anchors.fill: parent
                            anchors.margins: -Style.space(4)
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.removeApp(tile.modelData.id, chip.modelData["class"])
                          }
                        }
                      }
                    }

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      width: parent.width
                      horizontalAlignment: Text.AlignHCenter
                      wrapMode: Text.WordWrap
                      textFormat: Text.PlainText
                      text: tile.modelData.apps.length === 0
                        ? (tile.isSelected ? "Empty · A to add an app" : "Empty")
                        : (tile.isSelected ? "A to add another" : "")
                      visible: text !== ""
                      color: root.foreground
                      opacity: 0.5
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              // Dividers: drag to set the split between two neighbouring tiles.
              Repeater {
                model: root.geometry.dividers

                delegate: Item {
                  id: divider
                  required property var modelData
                  readonly property bool across: modelData.dir === "h"
                  readonly property real grip: Style.space(10)

                  x: across ? modelData.at - grip / 2 : modelData.split.x
                  y: across ? modelData.split.y : modelData.at - grip / 2
                  width: across ? grip : modelData.split.w
                  height: across ? modelData.split.h : grip

                  Rectangle {
                    anchors.centerIn: parent
                    width: divider.across ? Math.max(2, Style.space(2)) : parent.width * 0.3
                    height: divider.across ? parent.height * 0.3 : Math.max(2, Style.space(2))
                    radius: Math.max(1, Style.space(1))
                    color: root.accent
                    opacity: dragArea.containsMouse || dragArea.pressed ? 0.9 : 0
                  }

                  MouseArea {
                    id: dragArea
                    anchors.fill: parent
                    hoverEnabled: true
                    preventStealing: true
                    cursorShape: divider.across ? Qt.SplitHCursor : Qt.SplitVCursor
                    onPositionChanged: function(mouse) {
                      if (!pressed) return
                      var p = mapToItem(canvas, mouse.x, mouse.y)
                      var s = divider.modelData.split
                      var fraction = divider.across ? (p.x - s.x) / s.w : (p.y - s.y) / s.h
                      root.editRoot(Model.moveDivider(root.current.root, divider.modelData.path, divider.modelData.index, fraction), root.selected)
                    }
                    onReleased: keys.forceActiveFocus()
                  }
                }
              }
            }
          }

          // ------------------------------------------------ app picker
          Rectangle {
            id: picker
            visible: root.pickerOpen
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: stage.pickerWidth
            radius: root.cornerRadius
            color: Util.alpha(root.foreground, 0.05)
            border.width: Math.max(1, Style.space(1))
            border.color: Util.alpha(root.foreground, 0.12)

            Column {
              anchors.fill: parent
              anchors.margins: Style.spacing.lg
              spacing: Style.spacing.md

              Rectangle {
                width: parent.width
                height: Style.space(32)
                radius: root.cornerRadius
                color: Util.alpha(root.foreground, 0.07)

                TextInput {
                  id: pickerSearch
                  anchors.fill: parent
                  anchors.leftMargin: Style.spacing.lg
                  anchors.rightMargin: Style.spacing.lg
                  verticalAlignment: TextInput.AlignVCenter
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  clip: true
                  onTextChanged: { root.pickerQuery = text; root.pickerIndex = 0 }
                  Keys.priority: Keys.BeforeItem
                  Keys.onPressed: function(event) {
                    var count = root.pickerApps.length
                    if (event.key === Qt.Key_Escape) { root.pickerOpen = false; keys.forceActiveFocus() }
                    else if (event.key === Qt.Key_Down) { root.pickerIndex = Math.min(count - 1, root.pickerIndex + 1); appList.positionViewAtIndex(root.pickerIndex, ListView.Contain) }
                    else if (event.key === Qt.Key_Up) { root.pickerIndex = Math.max(0, root.pickerIndex - 1); appList.positionViewAtIndex(root.pickerIndex, ListView.Contain) }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.assignApp(root.pickerApps[root.pickerIndex])
                    else return
                    event.accepted = true
                  }

                  Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    visible: pickerSearch.text === ""
                    textFormat: Text.PlainText
                    text: "App for this tile…"
                    color: root.foreground
                    opacity: 0.45
                    font: pickerSearch.font
                  }
                }
              }

              ListView {
                id: appList
                width: parent.width
                height: parent.height - Style.space(32) - parent.spacing
                clip: true
                model: root.pickerApps
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                  id: appRow
                  required property var modelData
                  required property int index
                  width: ListView.view.width
                  height: Style.space(40)
                  radius: root.cornerRadius
                  color: index === root.pickerIndex ? root.selectedBackground : "transparent"

                  Column {
                    anchors.left: parent.left
                    anchors.right: runningDot.left
                    anchors.leftMargin: Style.spacing.lg
                    anchors.rightMargin: Style.spacing.md
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: appRow.modelData.name
                      elide: Text.ElideRight
                      color: appRow.index === root.pickerIndex ? root.accent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: appRow.modelData["class"]
                      elide: Text.ElideRight
                      color: root.foreground
                      opacity: 0.45
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Rectangle {
                    id: runningDot
                    anchors.right: parent.right
                    anchors.rightMargin: Style.spacing.lg
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(6); height: width; radius: width / 2
                    color: root.accent
                    opacity: appRow.modelData.running ? 0.9 : 0
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.pickerIndex = appRow.index
                    onClicked: root.assignApp(appRow.modelData)
                  }
                }
              }
            }
          }
        }

        // ------------------------------------------------ footer
        Item {
          id: footer
          width: parent.width
          height: Style.space(48)

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Style.normalBorderWidth
            color: Util.alpha(root.border, 0.28)
          }

          Column {
            anchors.left: parent.left
            anchors.right: flags.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: Style.spacing.xs
            spacing: Style.spacing.xxs

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: root.status !== "" ? root.status
                : (root.dirty ? "Unsaved changes · Ctrl+S saves and applies" : "Workspace " + root.workspace)
              color: root.status !== "" || root.dirty ? root.accent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: "| split beside · - split below · X remove · Shift+arrows resize · A add app · C capture this workspace · 1–0 workspace"
              color: root.foreground
              opacity: 0.5
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            id: flags
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: Style.spacing.xs
            spacing: Style.spacing.md

            Repeater {
              model: [
                { flag: "pin", label: "P  pin to workspace" },
                { flag: "launch", label: "O  open at login" }
              ]

              delegate: Rectangle {
                id: flagChip
                required property var modelData
                readonly property bool on: root.current[modelData.flag] !== false
                width: flagText.implicitWidth + Style.spacing.lg * 2
                height: Style.space(28)
                radius: height / 2
                color: on ? Util.alpha(root.accent, 0.18) : "transparent"
                border.width: Math.max(1, Style.space(1))
                border.color: on ? root.accent : Util.alpha(root.foreground, 0.2)

                Text {
                  id: flagText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: flagChip.modelData.label
                  color: flagChip.on ? root.foreground : Util.alpha(root.foreground, 0.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: { root.toggleFlag(flagChip.modelData.flag); keys.forceActiveFocus() }
                }
              }
            }
          }
        }
      }
    }
  }
}
