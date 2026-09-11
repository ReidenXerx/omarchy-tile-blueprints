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

  // The helper runs under the system interpreter by absolute path, never through PATH.
  // It reads and writes every file and runs every program; this file only talks to it.
  readonly property string python: "/usr/bin/python3"
  readonly property string helper: localPath("bin/tile-blueprints")

  // Ceilings on what the editor accepts back (the helper bounds its own output well
  // below these) and on what it hands over. The tile limits match the helper's.
  readonly property int maxHelperOutput: 4 * 1024 * 1024
  readonly property int maxDocument: 512 * 1024
  readonly property int maxApps: 3000
  readonly property int maxWindows: 256
  readonly property int maxTiles: 64
  readonly property int maxAppsPerTile: 32
  readonly property int maxDepth: 16

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

  // The saved blueprints arrive from the helper; nothing is saved before they have.
  property bool configLoaded: false
  property string configError: ""
  property bool saving: false
  property string pendingSave: ""
  property bool closeAfterSave: false

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
    var raw = String(payloadJson || "{}")
    if (raw.length <= 4096) {
      try { payload = JSON.parse(raw) || {} } catch (e) { payload = {} }
    }
    root.opened = true
    root.configLoaded = false
    root.draft = Model.clone(root.saved)
    root.dirty = false
    root.confirmDiscard = false
    root.closeAfterSave = false
    root.pickerOpen = false
    root.status = ""
    var requested = Math.floor(Number(payload.workspace))
    if (requested >= 1 && requested <= 10) root.showWorkspace(requested)
    else { root.showWorkspace(root.workspace); root.runHelper(activeWorkspaceProc, activeWorkspaceWatchdog, ["active-workspace"]) }
    root.runHelper(configProc, configWatchdog, ["config"])
    root.runHelper(appsProc, appsWatchdog, ["apps"])
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

  // ---------------------------------------------------------------- helper

  // Stops a helper that overruns: SIGTERM, then SIGKILL two seconds later. The helper puts
  // shorter deadlines on everything it runs, so this only fires if it hangs.
  component Watchdog: Timer {
    property var target: null
    property int limit: 15000
    property bool terminating: false
    property bool fired: false
    repeat: false

    function arm() {
      terminating = false
      fired = false
      interval = limit
      restart()
    }

    // True when the process ended on its own, before the watchdog fired.
    function finish() {
      stop()
      var inTime = !fired
      terminating = false
      fired = false
      return inTime
    }

    onTriggered: {
      if (!target || !target.running) return
      fired = true
      if (!terminating) {
        terminating = true
        target.signal(15)
        interval = 2000
        restart()
      } else {
        target.signal(9)
      }
    }
  }

  function runHelper(proc, watchdog, args) {
    if (proc.running) return false
    proc.command = [root.python, root.helper].concat(args)
    proc.running = true
    watchdog.arm()
    return true
  }

  // Call once per exit: it also disarms the watchdog.
  function helperOk(watchdog, exitCode, exitStatus) {
    return watchdog.finish() && exitCode === 0 && Number(exitStatus || 0) === 0
  }

  function helperText(collector) {
    var text = String(collector.text || "")
    return text.length <= root.maxHelperOutput ? text : ""
  }

  function helperError(collector, fallback) {
    var line = String(collector.text || "").slice(0, 1024).split("\n")[0].replace(/^tile-blueprints: /, "")
    return line !== "" ? line.slice(0, 200) : fallback
  }

  // ---------------------------------------------------------------- data

  function loadSaved(raw) {
    var parsed = null
    try { parsed = raw ? JSON.parse(raw) : null } catch (e) { parsed = null }
    root.saved = Model.normalizeFile(parsed)
    // Until the first load the draft is only a placeholder, so it is replaced even if touched.
    if (!root.dirty || !root.configLoaded) {
      root.draft = Model.clone(root.saved)
      root.dirty = false
      root.showWorkspace(root.workspace)
    }
    root.configLoaded = true
    var problems = parsed && Array.isArray(parsed.problems) ? parsed.problems : []
    if (problems.length > 0 && root.status === "")
      root.status = "Skipped part of the saved blueprints: " + String(problems[0]).slice(0, 200)
  }

  Process {
    id: configProc
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    stderr: StdioCollector { id: configErr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var ok = root.helperOk(configWatchdog, exitCode, exitStatus)
      var text = ok ? root.helperText(configOut) : ""
      if (text !== "") {
        root.configError = ""
        root.loadSaved(text)
      } else {
        root.configError = root.helperError(configErr, "the helper did not finish")
        root.status = "Could not read the saved blueprints: " + root.configError
      }
    }
  }
  Watchdog { id: configWatchdog; target: configProc; limit: 10000 }

  Process {
    id: appsProc
    stdout: StdioCollector { id: appsOut; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var list = []
      if (root.helperOk(appsWatchdog, exitCode, exitStatus)) {
        try { list = JSON.parse(root.helperText(appsOut)) } catch (e) { list = [] }
      }
      root.apps = Array.isArray(list) ? list.slice(0, root.maxApps) : []
    }
  }
  Watchdog { id: appsWatchdog; target: appsProc; limit: 20000 }

  Process {
    id: activeWorkspaceProc
    stdout: StdioCollector { id: activeWorkspaceOut; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (!root.helperOk(activeWorkspaceWatchdog, exitCode, exitStatus)) return
      var ws = null
      try { ws = JSON.parse(root.helperText(activeWorkspaceOut)) } catch (e) { ws = null }
      var id = ws ? Number(ws.id) : NaN
      if (id >= 1 && id <= 10 && Math.floor(id) === id) root.showWorkspace(id)
    }
  }
  Watchdog { id: activeWorkspaceWatchdog; target: activeWorkspaceProc; limit: 10000 }

  Process {
    id: captureProc
    property int targetWorkspace: 0
    stdout: StdioCollector { id: captureOut; waitForEnd: true }
    stderr: StdioCollector { id: captureErr; waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      if (root.helperOk(captureWatchdog, exitCode, exitStatus))
        root.finishCapture(root.helperText(captureOut), captureProc.targetWorkspace)
      else
        root.status = "Could not capture: " + root.helperError(captureErr, "the helper did not finish")
    }
  }
  Watchdog { id: captureWatchdog; target: captureProc; limit: 20000 }

  // The document goes to the helper on stdin, never in argv. It is one line because
  // Process.write() cannot close stdin; the helper reads up to the newline.
  Process {
    id: saveProc
    property string payload: ""
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: saveErr; waitForEnd: true }
    onStarted: {
      saveProc.write(saveProc.payload + "\n")
      saveProc.payload = ""
    }
    onExited: function(exitCode, exitStatus) {
      var ok = root.helperOk(saveWatchdog, exitCode, exitStatus)
      root.finishSave(ok, ok ? "" : root.helperError(saveErr, "the helper did not finish"))
    }
  }
  Watchdog { id: saveWatchdog; target: saveProc; limit: 20000 }

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

  // Split levels of a tree (a lone tile is 0), for the helper's depth limit.
  function treeDepth(node) {
    if (Model.isLeaf(node)) return 0
    var deepest = 0
    for (var i = 0; i < node.children.length; i++) deepest = Math.max(deepest, root.treeDepth(node.children[i]))
    return deepest + 1
  }

  // Why the helper would refuse this tree, or "". Checked before an edit lands so a
  // blueprint never grows past what can be saved.
  function limitProblem(tree) {
    var tiles = Model.leaves(tree)
    if (tiles.length > root.maxTiles) return "a blueprint holds at most " + root.maxTiles + " tiles"
    if (root.treeDepth(tree) > root.maxDepth) return "splits nest at most " + root.maxDepth + " levels deep"
    for (var i = 0; i < tiles.length; i++) {
      if (tiles[i].apps.length > root.maxAppsPerTile) return "a tile holds at most " + root.maxAppsPerTile + " apps"
    }
    return ""
  }

  function splitSelected(dir) {
    var r = Model.split(root.current.root, root.selected, dir)
    var problem = root.limitProblem(r.root)
    if (problem) { root.status = "Cannot split: " + problem; return }
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
    var next = Model.assign(root.current.root, root.selected, app)
    var problem = root.limitProblem(next)
    if (problem) {
      root.status = "Cannot add: " + problem
      root.pickerOpen = false
      keys.forceActiveFocus()
      return
    }
    root.editRoot(next, root.selected, (app.name || app["class"]) + " now opens in this tile")
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
    if (captureProc.running) return
    captureProc.targetWorkspace = root.workspace
    root.status = "Capturing workspace " + root.workspace + "…"
    root.runHelper(captureProc, captureWatchdog, ["windows", String(root.workspace)])
  }

  function finishCapture(raw, capturedWorkspace) {
    if (capturedWorkspace !== root.workspace) { root.status = ""; return }
    var parsed = []
    try { parsed = JSON.parse(raw) } catch (e) { parsed = [] }
    var windows = []
    for (var n = 0; Array.isArray(parsed) && n < parsed.length && windows.length < root.maxWindows; n++) {
      var item = parsed[n]
      if (!item || !isFinite(item.x) || !isFinite(item.y) || !(Number(item.w) > 0) || !(Number(item.h) > 0)) continue
      windows.push({ "class": String(item["class"] || ""), name: String(item.name || ""), desktop: String(item.desktop || ""),
                     x: Number(item.x), y: Number(item.y), w: Number(item.w), h: Number(item.h) })
    }
    if (windows.length === 0) { root.status = "No tiled windows on workspace " + root.workspace + " to capture"; return }
    var minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
    for (var i = 0; i < windows.length; i++) {
      var w = windows[i]
      minX = Math.min(minX, w.x); minY = Math.min(minY, w.y)
      maxX = Math.max(maxX, w.x + w.w); maxY = Math.max(maxY, w.y + w.h)
    }
    var tree = Model.normalize(Model.capture(windows, { x: minX, y: minY, w: maxX - minX, h: maxY - minY }))
    var problem = root.limitProblem(tree)
    if (problem) { root.status = "Cannot capture: " + problem; return }
    var ws = Model.clone(root.current)
    ws.root = tree
    root.commit(ws, Model.order(ws.root)[0],
                "Captured " + windows.length + " window" + (windows.length === 1 ? "" : "s") + " from workspace " + root.workspace)
  }

  function save() {
    if (!root.configLoaded) {
      root.status = root.configError !== "" ? "Not saved: could not read the saved blueprints: " + root.configError
                                            : "Still reading the saved blueprints…"
      return
    }
    var out = { version: 1, workspaces: {} }
    for (var key in root.draft.workspaces) {
      if (Model.isMeaningful(root.draft.workspaces[key])) out.workspaces[key] = root.draft.workspaces[key]
    }
    var payload = JSON.stringify(out)
    if (payload.length > root.maxDocument) { root.status = "Not saved: the blueprints are too large"; return }
    root.saved = Model.clone(out)
    root.draft = Model.clone(out)
    root.showWorkspace(root.workspace)
    root.dirty = false
    root.confirmDiscard = false
    root.status = "Saving…"
    if (saveProc.running) root.pendingSave = payload
    else root.startSave(payload)
  }

  function startSave(payload) {
    saveProc.payload = payload
    root.saving = true
    if (!root.runHelper(saveProc, saveWatchdog, ["write", "--background"])) {
      saveProc.payload = ""
      root.saving = false
      root.dirty = true
      root.status = "Not saved: a save is still running, try again"
    }
  }

  function finishSave(ok, error) {
    root.saving = false
    if (root.pendingSave !== "") {
      var next = root.pendingSave
      root.pendingSave = ""
      root.saving = true
      Qt.callLater(function() { root.startSave(next) })
      return
    }
    if (!ok) {
      // Keep the edits: they are still in the draft, now marked unsaved again.
      root.dirty = true
      root.closeAfterSave = false
      root.status = "Not saved: " + error
      root.runHelper(configProc, configWatchdog, ["config"])
      return
    }
    root.status = "Saved and applying"
    if (root.closeAfterSave) {
      root.closeAfterSave = false
      root.dismiss()
    }
  }

  function requestClose() {
    if (root.pickerOpen) { root.pickerOpen = false; keys.forceActiveFocus(); return }
    // Closing unloads this overlay and its processes, so wait for the save to be handed
    // over. A second Esc closes anyway.
    if (root.saving && !root.closeAfterSave) { root.closeAfterSave = true; root.status = "Closing once saved… (Esc again to close now)"; return }
    if (root.saving) { root.dismiss(); return }
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

  // Icons and running state come from the app list; blueprints store only class, name and
  // desktop id, so a renamed icon theme never goes stale inside the saved file.
  readonly property var appIndex: {
    var map = {}
    for (var i = 0; i < apps.length; i++) {
      var a = apps[i]
      if (a.desktop) map["d:" + String(a.desktop).toLowerCase()] = a
      if (a["class"]) map["c:" + String(a["class"]).toLowerCase()] = a
    }
    return map
  }

  function appInfo(app) {
    if (!app) return null
    return root.appIndex["d:" + String(app.desktop || "").toLowerCase()]
      || root.appIndex["c:" + String(app["class"] || "").toLowerCase()] || null
  }

  function iconFor(app) {
    var info = root.appInfo(app)
    var icon = String((info && info.icon) || (app && app.icon) || "")
    var library = root.shell && root.shell.appLibrary
    if (library && typeof library.iconSource === "function") return library.iconSource(icon)
    // The helper only hands out themed names and absolute paths it has checked are
    // regular, size-capped image files owned by us under $HOME or by root.
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    var themed = icon ? Quickshell.iconPath(icon, true) : ""
    return themed || Quickshell.iconPath("application-x-executable", true)
  }

  function isRunning(app) {
    var info = root.appInfo(app)
    return !!(info && info.running)
  }

  // How the layout shares one tile between its apps: evenly, along the longer side.
  function cardBoxes(w, h, count) {
    var out = []
    if (count <= 0 || w <= 0 || h <= 0) return out
    var gap = Style.space(6)
    var across = w >= h
    var size = ((across ? w : h) - gap * (count - 1)) / count
    for (var i = 0; i < count; i++) {
      var offset = i * (size + gap)
      out.push(across ? { x: offset, y: 0, w: size, h: h } : { x: 0, y: offset, w: w, h: size })
    }
    return out
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

                  // A preview of what Hyprland will do with this tile: one window per app,
                  // sharing the tile evenly along its longer side.
                  Item {
                    id: cards
                    anchors.fill: parent
                    anchors.margins: Style.spacing.lg
                    anchors.bottomMargin: Style.spacing.sm + tileFoot.height + Style.spacing.sm
                    visible: tile.modelData.apps.length > 0

                    Repeater {
                      model: tile.modelData.apps

                      delegate: Rectangle {
                        id: card
                        required property var modelData
                        required property int index
                        readonly property var box: root.cardBoxes(cards.width, cards.height, tile.modelData.apps.length)[index]
                        readonly property int iconSide: Math.max(Style.space(20), Math.min(Style.space(64), Math.min(width, height) * 0.34))

                        x: box ? box.x : 0
                        y: box ? box.y : 0
                        width: box ? box.w : 0
                        height: box ? box.h : 0
                        radius: root.cornerRadius
                        color: Util.alpha(root.foreground, tile.isSelected ? 0.10 : 0.06)
                        border.width: Math.max(1, Style.space(1))
                        border.color: Util.alpha(root.foreground, cardHover.hovered ? 0.35 : 0.14)

                        HoverHandler { id: cardHover }

                        Column {
                          anchors.centerIn: parent
                          width: parent.width - Style.spacing.lg * 2
                          spacing: Style.spacing.sm

                          Image {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: card.iconSide
                            height: card.iconSide
                            sourceSize.width: card.iconSide * 2
                            sourceSize.height: card.iconSide * 2
                            source: root.iconFor(card.modelData)
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                            smooth: true
                          }

                          Text {
                            width: parent.width
                            visible: card.height >= Style.space(76)
                            horizontalAlignment: Text.AlignHCenter
                            textFormat: Text.PlainText
                            text: card.modelData.name || card.modelData["class"]
                            elide: Text.ElideRight
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.body
                          }

                          Text {
                            width: parent.width
                            visible: card.height >= Style.space(110) && card.width >= Style.space(110)
                            horizontalAlignment: Text.AlignHCenter
                            textFormat: Text.PlainText
                            text: card.modelData["class"]
                            elide: Text.ElideMiddle
                            color: root.foreground
                            opacity: 0.4
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }

                        Rectangle {
                          visible: root.isRunning(card.modelData)
                          anchors.left: parent.left
                          anchors.top: parent.top
                          anchors.margins: Style.spacing.md
                          width: Style.space(6); height: width; radius: width / 2
                          color: root.accent
                        }

                        Rectangle {
                          id: removeButton
                          visible: cardHover.hovered || tile.isSelected
                          anchors.right: parent.right
                          anchors.top: parent.top
                          anchors.margins: Style.spacing.sm
                          width: Style.space(22); height: width; radius: width / 2
                          color: removeArea.containsMouse ? Util.alpha(root.accent, 0.3) : "transparent"

                          Text {
                            anchors.centerIn: parent
                            textFormat: Text.PlainText
                            text: "×"
                            color: root.foreground
                            opacity: removeArea.containsMouse ? 1 : 0.6
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                          }

                          MouseArea {
                            id: removeArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.removeApp(tile.modelData.id, card.modelData["class"])
                          }
                        }
                      }
                    }
                  }

                  // Empty tile: a target to click.
                  Column {
                    anchors.centerIn: parent
                    visible: tile.modelData.apps.length === 0
                    spacing: Style.spacing.md

                    Rectangle {
                      anchors.horizontalCenter: parent.horizontalCenter
                      width: Style.space(44); height: width; radius: width / 2
                      color: plusArea.containsMouse ? Util.alpha(root.accent, 0.22) : Util.alpha(root.foreground, 0.07)
                      border.width: Math.max(1, Style.space(1))
                      border.color: tile.isSelected || plusArea.containsMouse ? root.accent : Util.alpha(root.foreground, 0.2)

                      Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: "+"
                        color: tile.isSelected ? root.accent : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.display
                      }

                      MouseArea {
                        id: plusArea
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.selected = tile.modelData.id; root.openPicker() }
                      }
                    }

                    Text {
                      anchors.horizontalCenter: parent.horizontalCenter
                      visible: tile.height >= Style.space(110)
                      textFormat: Text.PlainText
                      text: "Add app"
                      color: root.foreground
                      opacity: 0.55
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }

                  Item {
                    id: tileFoot
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.leftMargin: Style.spacing.lg
                    anchors.rightMargin: Style.spacing.lg
                    anchors.bottomMargin: Style.spacing.sm
                    height: Style.space(16)

                    Text {
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      visible: tile.isSelected && tile.modelData.apps.length > 0 && tile.width >= Style.space(220)
                      textFormat: Text.PlainText
                      text: "A  add another app"
                      color: root.accent
                      opacity: 0.75
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }

                    Text {
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      visible: tile.width >= Style.space(90)
                      textFormat: Text.PlainText
                      text: root.percent(tile.modelData.w, canvas.width) + " × " + root.percent(tile.modelData.h, canvas.height)
                      color: root.foreground
                      opacity: 0.45
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

                  Image {
                    id: appIcon
                    anchors.left: parent.left
                    anchors.leftMargin: Style.spacing.lg
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(24)
                    height: width
                    sourceSize.width: width * 2
                    sourceSize.height: height * 2
                    source: root.iconFor(appRow.modelData)
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    smooth: true
                  }

                  Column {
                    anchors.left: appIcon.right
                    anchors.right: runningDot.left
                    anchors.leftMargin: Style.spacing.md
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
