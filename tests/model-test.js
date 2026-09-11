#!/usr/bin/env node
// node tests/model-test.js — runs BlueprintModel.js outside QML.
"use strict"
const fs = require("fs")
const path = require("path")
const vm = require("vm")
const assert = require("assert")

const root = path.resolve(__dirname, "..")
const source = fs.readFileSync(path.join(root, "BlueprintModel.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const ctx = {}
vm.runInNewContext(source + "\nthis.M = { MIN_SIZE, clone, isLeaf, newLeaf, leaves, nextId, pathTo, nodeAt, findLeaf, normalize, split, remove, grow, moveDivider, assign, unassign, order, layout, neighbour, capture, defaultWorkspace, normalizeFile, appCount, isMeaningful, tileLabel }", ctx)
const M = ctx.M

// vm-context objects carry that context's prototypes; compare plain copies.
const plain = v => JSON.parse(JSON.stringify(v))
const eq = (a, b, msg) => assert.deepStrictEqual(plain(a), plain(b), msg)
const near = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-6, `${msg || ""} ${a} != ${b}`)

let passed = 0
const failures = []
function test(name, fn) {
  try { fn(); passed++ } catch (e) { failures.push(name + "\n    " + e.message) }
}

const app = (cls, name) => ({ class: cls, name: name || cls, desktop: "" })

test("split a lone tile nests a split", () => {
  const r = M.split(M.newLeaf("t1"), "t1", "h")
  eq(r.root, { dir: "h", sizes: [0.5, 0.5], children: [{ id: "t1", apps: [] }, { id: "t2", apps: [] }] })
  assert.strictEqual(r.id, "t2")
})

test("splitting again the same way adds a sibling, not a nested split", () => {
  let r = M.split(M.newLeaf("t1"), "t1", "h")
  r = M.split(r.root, "t2", "h")
  assert.strictEqual(r.root.children.length, 3)
  eq(r.root.sizes, [0.5, 0.25, 0.25])
})

test("splitting across the parent nests", () => {
  let r = M.split(M.newLeaf("t1"), "t1", "h")
  r = M.split(r.root, "t2", "v")
  assert.strictEqual(r.root.children[1].dir, "v")
  eq(M.order(r.root), ["t1", "t2", "t3"])
})

test("split does not mutate its input", () => {
  const before = M.newLeaf("t1")
  M.split(before, "t1", "h")
  eq(before, { id: "t1", apps: [] })
})

test("remove gives space to siblings and collapses single-child splits", () => {
  let r = M.split(M.newLeaf("t1"), "t1", "h")
  r = M.split(r.root, "t2", "v")            // t1 | (t2 / t3)
  const removed = M.remove(r.root, "t3")    // t1 | t2
  eq(M.order(removed.root), ["t1", "t2"])
  assert.strictEqual(removed.root.dir, "h")
  assert.ok(M.isLeaf(removed.root.children[1]), "right side collapsed to a tile")
  assert.strictEqual(removed.id, "t2")
})

test("removing the last tile is refused", () => {
  const lone = M.newLeaf("t1")
  eq(M.remove(lone, "t1").root, lone)
})

test("remove renormalizes sizes", () => {
  let r = M.split(M.newLeaf("t1"), "t1", "h")
  r = M.split(r.root, "t2", "h")            // 0.5 0.25 0.25
  const out = M.remove(r.root, "t1").root
  eq(out.sizes, [0.5, 0.5])
})

test("grow moves space from the neighbour and clamps", () => {
  const r = M.split(M.newLeaf("t1"), "t1", "h").root
  const g = M.grow(r, "t1", "h", 0.1)
  near(g.sizes[0], 0.6); near(g.sizes[1], 0.4)
  const max = M.grow(r, "t1", "h", 5)
  near(max.sizes[1], M.MIN_SIZE)
})

test("grow on an axis with no split is a no-op", () => {
  const r = M.split(M.newLeaf("t1"), "t1", "h").root
  eq(M.grow(r, "t1", "v", 0.1), r)
})

test("grow finds the nearest split running that way", () => {
  let r = M.split(M.newLeaf("t1"), "t1", "h")
  r = M.split(r.root, "t2", "v")            // t1 | (t2 / t3)
  const g = M.grow(r.root, "t3", "h", -0.2) // t3's width comes from the outer h split
  near(g.sizes[1], 0.3)
})

test("moveDivider sets the fraction and keeps the pair's sum", () => {
  let r = M.split(M.newLeaf("t1"), "t1", "h")
  r = M.split(r.root, "t2", "h")            // 0.5 0.25 0.25
  const d = M.moveDivider(r.root, [], 1, 0.9)
  near(d.sizes[1], 0.4); near(d.sizes[2], 0.1); near(d.sizes[0], 0.5)
})

test("assign keeps a class in one tile only", () => {
  let t = M.split(M.newLeaf("t1"), "t1", "h").root
  t = M.assign(t, "t1", app("foot", "Foot"))
  t = M.assign(t, "t2", app("FOOT", "Foot"))
  eq(M.findLeaf(t, "t1").apps, [])
  assert.strictEqual(M.findLeaf(t, "t2").apps.length, 1)
})

test("unassign removes by class, case-insensitively", () => {
  let t = M.assign(M.newLeaf("t1"), "t1", app("org.telegram.desktop", "Telegram"))
  t = M.unassign(t, "t1", "ORG.TELEGRAM.DESKTOP")
  eq(t.apps, [])
})

test("layout tiles cover the box exactly", () => {
  let r = M.split(M.newLeaf("t1"), "t1", "h")
  r = M.split(r.root, "t2", "v")
  const g = M.layout(r.root, { x: 0, y: 0, w: 1000, h: 600 })
  const area = g.tiles.reduce((s, t) => s + t.w * t.h, 0)
  near(area, 600000)
  assert.strictEqual(g.dividers.length, 2)
  near(g.dividers[0].at, 500)
})

test("neighbour navigation", () => {
  let r = M.split(M.newLeaf("t1"), "t1", "h")
  r = M.split(r.root, "t2", "v")            // t1 | (t2 / t3)
  assert.strictEqual(M.neighbour(r.root, "t1", 1, 0), "t2")
  assert.strictEqual(M.neighbour(r.root, "t2", 0, 1), "t3")
  assert.strictEqual(M.neighbour(r.root, "t3", -1, 0), "t1")
  assert.strictEqual(M.neighbour(r.root, "t1", -1, 0), "t1")
})

test("capture: main window left, two stacked right", () => {
  const wins = [
    { class: "code", x: 12, y: 39, w: 939, h: 949 },
    { class: "foot", x: 965, y: 39, w: 623, h: 468 },
    { class: "org.telegram.desktop", x: 965, y: 521, w: 623, h: 467 },
  ]
  const tree = M.capture(wins, { x: 12, y: 39, w: 1576, h: 949 })
  assert.strictEqual(tree.dir, "h")
  near(Math.round(tree.sizes[0] * 100) / 100, 0.6)
  assert.strictEqual(tree.children[1].dir, "v")
  eq(tree.children[0].apps.map(a => a.class), ["code"])
  eq(tree.children[1].children.map(c => c.apps[0].class), ["foot", "org.telegram.desktop"])
})

test("capture: overlapping windows share a tile", () => {
  const wins = [
    { class: "a", x: 0, y: 0, w: 800, h: 800 },
    { class: "b", x: 400, y: 400, w: 800, h: 800 },
  ]
  const tree = M.capture(wins, { x: 0, y: 0, w: 1200, h: 1200 })
  assert.ok(M.isLeaf(tree))
  eq(tree.apps.map(a => a.class), ["a", "b"])
})

test("capture of nothing is one empty tile", () => {
  eq(M.capture([], { x: 0, y: 0, w: 10, h: 10 }), { id: "t1", apps: [] })
})

test("normalize repairs a hand-edited tree", () => {
  const t = M.normalize({ dir: "x", sizes: [3, 1], children: [
    { apps: [app("foot")] },
    { children: [{ id: "t1", apps: [app("FOOT"), app("code")] }] },
  ] })
  assert.strictEqual(t.dir, "h")
  near(t.sizes[0], 0.75)
  assert.ok(M.isLeaf(t.children[1]), "single-child split collapsed")
  const classes = M.leaves(t).flatMap(l => l.apps.map(a => a.class.toLowerCase()))
  eq(classes, ["foot", "code"])
  const ids = M.leaves(t).map(l => l.id)
  assert.strictEqual(new Set(ids).size, ids.length)
})

test("normalizeFile keeps numeric workspaces and defaults the flags", () => {
  const f = M.normalizeFile({ workspaces: { "2": { root: M.newLeaf("t1") }, "web": {}, "3": { root: M.newLeaf("t1"), launch: false } } })
  eq(Object.keys(f.workspaces), ["2", "3"])
  assert.strictEqual(f.workspaces["2"].pin, true)
  assert.strictEqual(f.workspaces["3"].launch, false)
})

test("isMeaningful ignores an untouched workspace", () => {
  assert.strictEqual(M.isMeaningful(M.defaultWorkspace()), false)
  const ws = M.defaultWorkspace(); ws.root = M.assign(ws.root, "t1", app("foot"))
  assert.strictEqual(M.isMeaningful(ws), true)
})

test("tileLabel lists names", () => {
  assert.strictEqual(M.tileLabel({ apps: [app("a", "Alpha"), app("b", "Beta")] }), "Alpha, Beta")
  assert.strictEqual(M.tileLabel({ apps: [] }), "")
})

console.log(`${passed} passed, ${failures.length} failed`)
for (const f of failures) console.log("  FAIL " + f)
process.exit(failures.length ? 1 : 0)
