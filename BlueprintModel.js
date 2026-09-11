.pragma library

// Blueprint trees and the edits the editor makes on them. Pure functions with no QML, so
// tests/model-test.js runs them under node. Every edit returns a new tree.
//
// A split is { dir: "h" | "v", sizes: [..fractions..], children: [..nodes..] } -- "h" lays
// children left to right, "v" top to bottom. A leaf (a tile) is
// { id: "t3", apps: [{ class, name, desktop }] }. The same shape is what the Lua layout
// engine reads, so what the editor draws is what Hyprland does.

var MIN_SIZE = 0.08

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function isLeaf(node) {
  return !!node && !Array.isArray(node.children)
}

function newLeaf(id) {
  return { id: id, apps: [] }
}

function leaves(node, out) {
  out = out || []
  if (!node) return out
  if (isLeaf(node)) out.push(node)
  else for (var i = 0; i < node.children.length; i++) leaves(node.children[i], out)
  return out
}

function nextId(root) {
  var max = 0
  var all = leaves(root)
  for (var i = 0; i < all.length; i++) {
    var n = parseInt(String(all[i].id || "").replace(/^t/, ""), 10)
    if (n > max) max = n
  }
  return "t" + (max + 1)
}

// Path of child indices from root to the leaf with this id, or null.
function pathTo(node, id, path) {
  path = path || []
  if (isLeaf(node)) return node.id === id ? path : null
  for (var i = 0; i < node.children.length; i++) {
    var found = pathTo(node.children[i], id, path.concat([i]))
    if (found) return found
  }
  return null
}

function nodeAt(root, path) {
  var node = root
  for (var i = 0; i < path.length; i++) node = node.children[path[i]]
  return node
}

function findLeaf(root, id) {
  var path = pathTo(root, id)
  return path ? nodeAt(root, path) : null
}

function normalizeSizes(sizes, count) {
  var out = []
  var total = 0
  for (var i = 0; i < count; i++) {
    var v = Number(sizes && sizes[i])
    out.push(v > 0 ? v : 1 / count)
    total += out[i]
  }
  for (var j = 0; j < count; j++) out[j] = out[j] / total
  return out
}

// Repair a tree read from disk: sizes that add to 1, splits with at least two children,
// every leaf with an id and an apps list, no class claimed by two tiles.
function normalize(node) {
  var root = normalizeNode(clone(node || newLeaf("t1")))
  var seen = {}
  var all = leaves(root)
  var used = {}
  for (var i = 0; i < all.length; i++) {
    if (!all[i].id || used[all[i].id]) all[i].id = null
    else used[all[i].id] = true
  }
  for (var k = 0; k < all.length; k++) {
    if (!all[k].id) { all[k].id = nextId(root) }
    var apps = []
    for (var a = 0; a < all[k].apps.length; a++) {
      var app = all[k].apps[a]
      var key = String(app && app["class"] || "").toLowerCase()
      if (!key || seen[key]) continue
      seen[key] = true
      apps.push({ "class": String(app["class"]), name: String(app.name || app["class"]), desktop: String(app.desktop || "") })
    }
    all[k].apps = apps
  }
  return root
}

function normalizeNode(node) {
  if (!node || typeof node !== "object") return newLeaf(null)
  if (!Array.isArray(node.children)) {
    return { id: node.id ? String(node.id) : null, apps: Array.isArray(node.apps) ? node.apps : [] }
  }
  var children = node.children.map(normalizeNode)
  if (children.length === 0) return newLeaf(null)
  if (children.length === 1) return children[0]
  return { dir: node.dir === "v" ? "v" : "h", sizes: normalizeSizes(node.sizes, children.length), children: children }
}

// ------------------------------------------------------------------ edits

// Split a tile in two along dir. When the parent already runs the same way, the new tile
// becomes a sibling instead of nesting a new split, so repeated splits stay one row.
function split(root, id, dir) {
  var tree = clone(root)
  var path = pathTo(tree, id)
  if (!path) return { root: root, id: id }
  var fresh = newLeaf(nextId(tree))
  dir = dir === "v" ? "v" : "h"

  if (path.length > 0) {
    var parent = nodeAt(tree, path.slice(0, -1))
    var index = path[path.length - 1]
    if (parent.dir === dir) {
      var half = parent.sizes[index] / 2
      parent.sizes.splice(index, 1, half, half)
      parent.children.splice(index + 1, 0, fresh)
      return { root: tree, id: fresh.id }
    }
  }
  var leaf = nodeAt(tree, path)
  var replacement = { dir: dir, sizes: [0.5, 0.5], children: [leaf, fresh] }
  if (path.length === 0) return { root: replacement, id: fresh.id }
  nodeAt(tree, path.slice(0, -1)).children[path[path.length - 1]] = replacement
  return { root: tree, id: fresh.id }
}

// Remove a tile; its space goes to its siblings and a split left with one child collapses.
// Returns the id to select next.
function remove(root, id) {
  var tree = clone(root)
  var path = pathTo(tree, id)
  if (!path || path.length === 0) return { root: root, id: id }
  var parentPath = path.slice(0, -1)
  var parent = nodeAt(tree, parentPath)
  var index = path[path.length - 1]
  parent.children.splice(index, 1)
  parent.sizes.splice(index, 1)
  parent.sizes = normalizeSizes(parent.sizes, parent.children.length)
  var neighbour = parent.children[Math.min(index, parent.children.length - 1)]
  if (parent.children.length === 1) {
    var only = parent.children[0]
    if (parentPath.length === 0) tree = only
    else nodeAt(tree, parentPath.slice(0, -1)).children[parentPath[parentPath.length - 1]] = only
  }
  return { root: tree, id: leaves(neighbour)[0].id }
}

// Grow (delta > 0) or shrink a tile along axis "h" (width) or "v" (height), taking the
// space from its neighbour in the nearest split that runs that way.
function grow(root, id, axis, delta) {
  var tree = clone(root)
  var path = pathTo(tree, id)
  if (!path) return root
  for (var depth = path.length - 1; depth >= 0; depth--) {
    var split = nodeAt(tree, path.slice(0, depth))
    if (split.dir !== axis) continue
    var i = path[depth]
    var j = i + 1 < split.children.length ? i + 1 : i - 1
    var pair = split.sizes[i] + split.sizes[j]
    var next = Math.max(MIN_SIZE, Math.min(pair - MIN_SIZE, split.sizes[i] + delta))
    split.sizes[i] = next
    split.sizes[j] = pair - next
    return tree
  }
  return root
}

// Drag the divider between children index and index+1 of the split at splitPath to
// fraction (0..1 across that split's own box).
function moveDivider(root, splitPath, index, fraction) {
  var tree = clone(root)
  var split = nodeAt(tree, splitPath)
  if (isLeaf(split) || index < 0 || index + 1 >= split.children.length) return root
  var before = 0
  for (var i = 0; i < index; i++) before += split.sizes[i]
  var pair = split.sizes[index] + split.sizes[index + 1]
  var next = Math.max(MIN_SIZE, Math.min(pair - MIN_SIZE, fraction - before))
  split.sizes[index] = next
  split.sizes[index + 1] = pair - next
  return tree
}

// Give an app to a tile. A class can live in one tile only -- the layout sends a window to
// the first tile that lists it -- so it is taken out of any other tile first.
function assign(root, id, app) {
  var tree = clone(root)
  var key = String(app && app["class"] || "").toLowerCase()
  if (!key) return root
  var all = leaves(tree)
  for (var i = 0; i < all.length; i++) {
    all[i].apps = all[i].apps.filter(function(a) { return String(a["class"]).toLowerCase() !== key })
  }
  var leaf = findLeaf(tree, id)
  if (!leaf) return root
  leaf.apps.push({ "class": String(app["class"]), name: String(app.name || app["class"]), desktop: String(app.desktop || "") })
  return tree
}

function unassign(root, id, cls) {
  var tree = clone(root)
  var leaf = findLeaf(tree, id)
  if (!leaf) return root
  var key = String(cls).toLowerCase()
  leaf.apps = leaf.apps.filter(function(a) { return String(a["class"]).toLowerCase() !== key })
  return tree
}

// Every tile's id in reading order, for Tab/arrow navigation.
function order(root) {
  return leaves(root).map(function(l) { return l.id })
}

// ------------------------------------------------------------------ geometry

// Rectangles for drawing: one per tile, plus one per divider with what dragging it moves.
function layout(root, box) {
  var out = { tiles: [], dividers: [] }
  walk(root, box, [], out)
  return out
}

function walk(node, box, path, out) {
  if (isLeaf(node)) {
    out.tiles.push({ id: node.id, apps: node.apps, x: box.x, y: box.y, w: box.w, h: box.h })
    return
  }
  var offset = 0
  var span = node.dir === "h" ? box.w : box.h
  for (var i = 0; i < node.children.length; i++) {
    var size = i === node.children.length - 1 ? span - offset : span * node.sizes[i]
    var child = node.dir === "h"
      ? { x: box.x + offset, y: box.y, w: size, h: box.h }
      : { x: box.x, y: box.y + offset, w: box.w, h: size }
    walk(node.children[i], child, path.concat([i]), out)
    offset += size
    if (i < node.children.length - 1) {
      out.dividers.push({ path: path, index: i, dir: node.dir,
                          split: { x: box.x, y: box.y, w: box.w, h: box.h },
                          at: node.dir === "h" ? box.x + offset : box.y + offset })
    }
  }
}

// The tile in direction dx/dy from the tile with this id: the nearest one whose edge touches
// and that overlaps most along the other axis.
function neighbour(root, id, dx, dy) {
  var tiles = layout(root, { x: 0, y: 0, w: 1, h: 1 }).tiles
  var from = null
  for (var i = 0; i < tiles.length; i++) if (tiles[i].id === id) from = tiles[i]
  if (!from) return id
  var best = null, bestScore = -1
  var eps = 1e-6
  for (var k = 0; k < tiles.length; k++) {
    var t = tiles[k]
    if (t.id === id) continue
    var touches = dx > 0 ? Math.abs(t.x - (from.x + from.w)) < eps
                : dx < 0 ? Math.abs(t.x + t.w - from.x) < eps
                : dy > 0 ? Math.abs(t.y - (from.y + from.h)) < eps
                : Math.abs(t.y + t.h - from.y) < eps
    if (!touches) continue
    var overlap = dx !== 0
      ? Math.min(from.y + from.h, t.y + t.h) - Math.max(from.y, t.y)
      : Math.min(from.x + from.w, t.x + t.w) - Math.max(from.x, t.x)
    if (overlap > eps && overlap > bestScore) { best = t; bestScore = overlap }
  }
  return best ? best.id : id
}

// ------------------------------------------------------------------ capture

// Turn the windows of a hand-arranged workspace into a blueprint with the same proportions.
// Windows are cut into columns or rows wherever a straight line separates them (a
// guillotine partition, which is exactly what a tiling layout can produce); a group that
// no straight line separates becomes one shared tile.
function capture(windows, area, tolerance) {
  var tol = tolerance === undefined ? 24 : tolerance
  var items = (windows || []).filter(function(w) { return w && w.w > 0 && w.h > 0 })
  if (items.length === 0) return newLeaf("t1")
  var counter = { n: 0 }
  return cut(items, area, tol, counter)
}

function groupsAlong(items, axis, tol) {
  var start = axis === "h" ? "x" : "y"
  var span = axis === "h" ? "w" : "h"
  var sorted = items.slice().sort(function(a, b) { return a[start] - b[start] })
  var groups = []
  var current = null, reach = -Infinity
  for (var i = 0; i < sorted.length; i++) {
    var it = sorted[i]
    if (current && it[start] >= reach - tol) { groups.push(current); current = null }
    if (!current) { current = { items: [], from: it[start], to: -Infinity } }
    current.items.push(it)
    reach = Math.max(reach, it[start] + it[span])
    current.to = reach
  }
  if (current) groups.push(current)
  return groups
}

function cut(items, box, tol, counter) {
  if (items.length > 1) {
    var axes = box.w >= box.h ? ["h", "v"] : ["v", "h"]
    for (var a = 0; a < axes.length; a++) {
      var axis = axes[a]
      var groups = groupsAlong(items, axis, tol)
      if (groups.length < 2) continue
      var origin = axis === "h" ? box.x : box.y
      var length = axis === "h" ? box.w : box.h
      var bounds = [origin]
      for (var g = 0; g < groups.length - 1; g++) bounds.push((groups[g].to + groups[g + 1].from) / 2)
      bounds.push(origin + length)
      var sizes = [], children = []
      for (var k = 0; k < groups.length; k++) {
        sizes.push(Math.max(0, bounds[k + 1] - bounds[k]) / length)
        var sub = axis === "h"
          ? { x: bounds[k], y: box.y, w: bounds[k + 1] - bounds[k], h: box.h }
          : { x: box.x, y: bounds[k], w: box.w, h: bounds[k + 1] - bounds[k] }
        children.push(cut(groups[k].items, sub, tol, counter))
      }
      return { dir: axis, sizes: normalizeSizes(sizes, sizes.length), children: children }
    }
  }
  counter.n++
  var leaf = newLeaf("t" + counter.n)
  var seen = {}
  for (var i = 0; i < items.length; i++) {
    var key = String(items[i]["class"] || "").toLowerCase()
    if (!key || seen[key]) continue
    seen[key] = true
    leaf.apps.push({ "class": items[i]["class"], name: items[i].name || items[i]["class"], desktop: items[i].desktop || "" })
  }
  return leaf
}

// ------------------------------------------------------------------ file

function defaultWorkspace() {
  return { root: newLeaf("t1"), launch: true, pin: true }
}

function normalizeFile(parsed) {
  var out = { version: 1, workspaces: {} }
  var src = parsed && typeof parsed === "object" && parsed.workspaces && typeof parsed.workspaces === "object"
    ? parsed.workspaces : {}
  for (var key in src) {
    if (!/^[0-9]+$/.test(key)) continue
    var ws = src[key] || {}
    out.workspaces[key] = {
      root: normalize(ws.root),
      launch: ws.launch !== false,
      pin: ws.pin !== false
    }
  }
  return out
}

function appCount(root) {
  return leaves(root).reduce(function(n, l) { return n + l.apps.length }, 0)
}

// A blueprint worth saving: more than one tile, or at least one app.
function isMeaningful(ws) {
  return !!ws && (!isLeaf(ws.root) || appCount(ws.root) > 0)
}

function tileLabel(tile) {
  if (!tile || !tile.apps || tile.apps.length === 0) return ""
  return tile.apps.map(function(a) { return a.name || a["class"] }).join(", ")
}
