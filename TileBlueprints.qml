import Quickshell
import Quickshell.Io
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
  readonly property int maxMonitors: 16   // matches the helper's ceiling
  readonly property int maxWindows: 256
  readonly property int maxFloating: 16   // matches the helper's ceiling
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
  property string status: ""

  // The saved blueprints arrive from the helper; nothing is saved before they have.
  property bool configLoaded: false
  property string configError: ""
  property bool saving: false
  property string pendingSave: ""
  property bool closeAfterSave: false

  property var apps: []
  // The connected displays, from the helper: { name, description, rule, width, height, workspace }.
  property var monitors: []
  property bool pickerOpen: false
  property string pickerQuery: ""
  property int pickerIndex: 0

  // Asked before the editor closes with unsaved changes.
  property bool promptOpen: false

  // Drag and drop: the app being dragged ({ class, name, desktop }), the tile it came from ("" for
  // the app list), what is under the pointer, and what letting go there would do.
  property var dragApp: null
  property string dragFrom: ""
  property var dragHit: null
  property var dropTarget: null
  property string dropKind: ""
  property bool dragShift: false
  property real dragX: 0
  property real dragY: 0

  readonly property var current: draft.workspaces[String(workspace)] || Model.defaultWorkspace()
  readonly property string monitorLabel: Model.monitorLabel(current.monitor, monitors)
  readonly property var geometry: Model.layout(current.root, { x: 0, y: 0, w: view ? view.canvasWidth : 0, h: view ? view.canvasHeight : 0 })
  readonly property var selectedTile: Model.findLeaf(current.root, selected)
  readonly property var pickerApps: filterApps(apps, pickerQuery)

  // Workspaces whose blueprint saving would change. Until the saved blueprints arrive the draft is
  // only a placeholder, so nothing counts yet.
  readonly property var changes: configLoaded ? Model.changedWorkspaces(saved, draft) : []
  readonly property bool hasChanges: changes.length > 0
  readonly property string promptText: (changes.length === 1
    ? "Workspace " + changes[0] + " has changes that are not saved yet."
    : "Workspaces " + Model.listNumbers(changes) + " have changes that are not saved yet.")
    + " Saving applies them right away."

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
    root.closeAfterSave = false
    root.pickerOpen = false
    root.promptOpen = false
    root.cancelDrag()
    root.status = ""
    var requested = Math.floor(Number(payload.workspace))
    if (requested >= 1 && requested <= 10) root.showWorkspace(requested)
    else { root.showWorkspace(root.workspace); root.runHelper(activeWorkspaceProc, activeWorkspaceWatchdog, ["active-workspace"]) }
    root.runHelper(configProc, configWatchdog, ["config"])
    root.runHelper(appsProc, appsWatchdog, ["apps"])
    root.runHelper(monitorsProc, monitorsWatchdog, ["monitors"])
    Qt.callLater(function() { root.focusKeys() })
  }

  // The shell calls this to close the editor from outside: its key pressed again, `shell hide`.
  // With unsaved changes the editor stays open and asks first. It can, because the overlay is kept
  // loaded (keepLoaded in the manifest) and the shell reads `opened` to see whether it is open.
  function close() {
    if (root.opened && root.hasChanges) {
      root.askToSave()
      return
    }
    root.opened = false
    root.pickerOpen = false
    root.promptOpen = false
    root.cancelDrag()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "reidenxerx.tile-blueprints")
  }

  function focusKeys() {
    if (root.view) root.view.focusKeys()
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
    id: monitorsProc
    stdout: StdioCollector { id: monitorsOut; waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode, exitStatus) {
      var list = []
      if (root.helperOk(monitorsWatchdog, exitCode, exitStatus)) {
        try { list = JSON.parse(root.helperText(monitorsOut)) } catch (e) { list = [] }
      }
      // No displays listed (Hyprland busy): the chip then offers only "any display".
      root.monitors = Array.isArray(list) ? list.slice(0, root.maxMonitors) : []
    }
  }
  Watchdog { id: monitorsWatchdog; target: monitorsProc; limit: 10000 }

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
      root.focusKeys()
      return
    }
    root.editRoot(next, root.selected, (app.name || app["class"]) + " now opens in this tile")
    root.pickerOpen = false
    root.focusKeys()
  }

  // How an app opens on this workspace: normal, full screen, full width. Clicking the badge
  // on a card walks the three, and a snapshot fills it in from what was actually on screen.
  function cycleState(tileId, app) {
    if (!app) return
    var next = Model.nextState(String(app.state || ""))
    var name = app.name || app["class"]
    root.editRoot(Model.withState(root.current.root, tileId, app["class"], next), tileId,
                  next === "" ? name + " opens normally" : name + " opens " + Model.stateLabel(next))
  }

  // Floating windows a snapshot recorded. The editor lists them and can drop one; their
  // place and size come from the workspace itself, so there is nothing to drag here.
  function floatingWindows() {
    var list = root.current && root.current.floating
    return Array.isArray(list) ? list : []
  }

  function removeFloating(index) {
    var list = root.floatingWindows()
    if (index < 0 || index >= list.length) return
    var ws = Model.clone(root.current)
    var kept = []
    for (var i = 0; i < list.length; i++) { if (i !== index) kept.push(list[i]) }
    if (kept.length > 0) ws.floating = kept
    else delete ws.floating
    root.commit(ws, root.selected, (list[index].name || list[index]["class"]) + " will not be placed any more")
  }

  function removeApp(tileId, cls) {
    root.editRoot(Model.unassign(root.current.root, tileId, cls), tileId)
  }

  function removeLastApp() {
    var tile = root.selectedTile
    if (tile && tile.apps.length > 0) root.removeApp(tile.id, tile.apps[tile.apps.length - 1]["class"])
  }

  // ---------------------------------------------------------------- drag and drop

  function beginDrag(app, fromTile) {
    var cls = app ? String(app["class"] || "") : ""
    if (root.promptOpen || !root.configLoaded || !cls) return false
    root.dragApp = { "class": cls, name: String(app.name || cls), desktop: String(app.desktop || "") }
    root.dragFrom = fromTile || ""
    root.dragHit = null
    root.dragShift = false
    root.refreshDrop()
    return true
  }

  function moveDrag(hit, x, y, shift) {
    if (!root.dragApp) return
    root.dragX = x
    root.dragY = y
    root.dragHit = hit
    root.dragShift = shift
    root.refreshDrop()
  }

  function setDragShift(on) {
    if (!root.dragApp || root.dragShift === on) return
    root.dragShift = on
    root.refreshDrop()
  }

  // Over an app: swap with it, unless Shift is held or the app came from the list. Anywhere else
  // on a tile: put it there.
  function refreshDrop() {
    var hit = root.dragHit
    var swap = !!hit && hit.onClass !== "" && !root.dragShift && root.dragFrom !== ""
    root.dropTarget = hit ? { tile: hit.tile, onClass: swap ? hit.onClass : "", mode: swap ? "swap" : "add" } : null
    var drag = { app: root.dragApp, from: root.dragFrom }
    root.dropKind = root.dropTarget ? Model.drop(root.current.root, drag, root.dropTarget).kind : ""
    root.status = Model.dropLabel(root.current.root, drag, root.dropTarget)
  }

  function cancelDrag() {
    if (!root.dragApp) return
    root.dragApp = null
    root.dragFrom = ""
    root.dragHit = null
    root.dropTarget = null
    root.dropKind = ""
    root.status = ""
  }

  // Ends the drag at once and hands back what to drop: { drag, target }, or null. It is taken at the
  // release, so nothing that happens before the drop is applied (Shift let go) can change it.
  function takeDrop() {
    var drop = root.dragApp && root.dropTarget ? { drag: { app: root.dragApp, from: root.dragFrom }, target: root.dropTarget } : null
    root.cancelDrag()
    return drop
  }

  function applyDrop(drop) {
    if (!drop) return
    var result = Model.drop(root.current.root, drop.drag, drop.target)
    if (result.kind === "") return
    var problem = root.limitProblem(result.root)
    if (problem) { root.status = "Cannot move: " + problem; return }
    var name = drop.drag.app.name
    root.editRoot(result.root, drop.target.tile,
                  result.kind === "swap" ? name + " and " + result.other + " swapped tiles"
                    : result.kind === "move" ? name + " moved to this tile" : name + " now opens in this tile")
  }

  function toggleFlag(flag) {
    var ws = Model.clone(root.current)
    ws[flag] = !ws[flag]
    root.commit(ws, root.selected, flag === "launch"
      ? (ws.launch ? "Apps here launch at login" : "Apps here no longer launch at login")
      : (ws.pin ? "Apps here always open on this workspace" : "Apps here open wherever you launch them"))
  }

  // The display this workspace's blueprint opens on, cycled: any display, then each connected
  // one. Empty means no rule at all, which leaves Hyprland to place it as it always did.
  function cycleMonitor() {
    var ws = Model.clone(root.current)
    var next = Model.nextMonitor(ws.monitor, root.monitors)
    if (next === "") delete ws.monitor
    else ws.monitor = next
    root.commit(ws, root.selected, next === ""
      ? "Workspace " + root.workspace + " opens on whichever display it is on"
      : "Workspace " + root.workspace + " opens on " + Model.monitorLabel(next, root.monitors))
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

  // One window from the helper's listing, or null: geometry it could not vouch for is
  // dropped rather than guessed at.
  function captureWindow(item) {
    if (!item || !isFinite(item.x) || !isFinite(item.y) || !(Number(item.w) > 0) || !(Number(item.h) > 0)) return null
    var out = { "class": String(item["class"] || ""), name: String(item.name || ""), desktop: String(item.desktop || ""),
                x: Number(item.x), y: Number(item.y), w: Number(item.w), h: Number(item.h) }
    if (item.state === "fullscreen" || item.state === "maximized") out.state = item.state
    if (item.pinned === true) out.pinned = true
    return out
  }

  function finishCapture(raw, capturedWorkspace) {
    if (capturedWorkspace !== root.workspace) { root.status = ""; return }
    var parsed = null
    try { parsed = JSON.parse(raw) } catch (e) { parsed = null }
    // The helper used to print a bare array of tiled windows and now prints both lists.
    var tiled = Array.isArray(parsed) ? parsed : (parsed && Array.isArray(parsed.tiled) ? parsed.tiled : [])
    var loose = parsed && Array.isArray(parsed.floating) ? parsed.floating : []
    var windows = []
    for (var n = 0; n < tiled.length && windows.length < root.maxWindows; n++) {
      var one = root.captureWindow(tiled[n])
      if (one) windows.push(one)
    }
    var floating = []
    for (var f = 0; f < loose.length && floating.length < root.maxFloating; f++) {
      var other = root.captureWindow(loose[f])
      if (other) floating.push(other)
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
    if (floating.length > 0) ws.floating = floating
    else delete ws.floating
    var note = "Captured " + windows.length + " window" + (windows.length === 1 ? "" : "s")
    if (floating.length > 0) note += " and " + floating.length + " floating"
    root.commit(ws, Model.order(ws.root)[0], note + " from workspace " + root.workspace)
  }

  function save() {
    if (!root.configLoaded) {
      root.status = root.configError !== "" ? "Not saved: could not read the saved blueprints: " + root.configError
                                            : "Still reading the saved blueprints…"
      return false
    }
    var out = { version: 1, workspaces: {} }
    for (var key in root.draft.workspaces) {
      if (Model.isMeaningful(root.draft.workspaces[key])) out.workspaces[key] = root.draft.workspaces[key]
    }
    var payload = JSON.stringify(out)
    if (payload.length > root.maxDocument) { root.status = "Not saved: the blueprints are too large"; return false }
    root.saved = Model.clone(out)
    root.draft = Model.clone(out)
    root.showWorkspace(root.workspace)
    root.dirty = false
    root.status = "Saving…"
    if (saveProc.running) root.pendingSave = payload
    else root.startSave(payload)
    return true
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
    if (root.dragApp) { root.cancelDrag(); return }
    if (root.promptOpen) { root.answerPrompt("cancel"); return }
    if (root.pickerOpen) { root.pickerOpen = false; root.focusKeys(); return }
    // Wait for a save to be handed over, so a failure still shows. A second Esc closes anyway.
    if (root.saving && !root.closeAfterSave) { root.closeAfterSave = true; root.status = "Closing once saved… (Esc again to close now)"; return }
    if (root.saving) { root.dismiss(); return }
    if (root.hasChanges) { root.askToSave(); return }
    root.dismiss()
  }

  function askToSave() {
    root.cancelDrag()
    root.pickerOpen = false
    root.promptOpen = true
    root.focusKeys()
  }

  // The answer to the save question: "save" saves and closes once it is saved, "discard" drops
  // the changes and closes, "cancel" goes back to editing.
  function answerPrompt(action) {
    if (!root.promptOpen) return
    root.promptOpen = false
    if (action === "save") {
      root.closeAfterSave = true
      if (!root.save()) root.closeAfterSave = false
    } else if (action === "discard") {
      root.draft = Model.clone(root.saved)
      root.dirty = false
      root.status = ""
      root.dismiss()
    } else {
      root.focusKeys()
    }
  }

  function openPicker() {
    root.pickerQuery = ""
    root.pickerIndex = 0
    root.pickerOpen = true
    if (root.apps.length === 0) appsProc.running = true
    Qt.callLater(function() { if (root.view) root.view.focusPickerSearch() })
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

    // While the save question is up, only its answers count.
    if (root.promptOpen) {
      if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_S) root.answerPrompt("save")
      else if (k === Qt.Key_D || k === Qt.Key_N) root.answerPrompt("discard")
      else if (k === Qt.Key_Escape || k === Qt.Key_K) root.answerPrompt("cancel")
      event.accepted = true
      return
    }
    // During a drag Shift switches between swapping and sharing a tile, Esc cancels, and nothing
    // else may change the tiles under the pointer.
    if (root.dragApp) {
      if (k === Qt.Key_Shift) root.setDragShift(true)
      else if (k === Qt.Key_Escape) root.cancelDrag()
      event.accepted = true
      return
    }
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
    else if (k === Qt.Key_M) root.cycleMonitor()
    else handled = false

    if (handled) event.accepted = true
  }

  // ---------------------------------------------------------------- ui

  // The window and the card live in their own files. The window is loaded with setSource because a
  // layer-shell window cannot load at all in the offscreen probe, which sets headless and hosts
  // EditorCard.qml itself. EditorCard sets `view` to itself.
  property bool headless: false
  property var view: null

  Loader {
    id: panelLoader
    Component.onCompleted: {
      if (!root.headless) setSource("EditorPanel.qml", { controller: root })
    }
  }
}
