const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

// Model.js is a QML JS library (.pragma library); evaluate it in a sandbox.
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "")
const ctx = {}
vm.runInNewContext(src + "\nthis.M = { parseStatus, flatten, parentId, nodeById, fitBox, label, fontFor, firstWindow, prune, liveAddresses, hit, windowsIn, windowsUnder, normalise }", ctx)
const M = ctx.M
const fixture = fs.readFileSync(path.join(__dirname, "fixture.json"), "utf8")

test("parseStatus rejects garbage and accepts the engine's JSON", () => {
  assert.equal(M.parseStatus(""), null)
  assert.equal(M.parseStatus("nope"), null)
  assert.equal(M.parseStatus('{"a":1}'), null)
  const s = M.parseStatus(fixture)
  assert.equal(s.viewport, "c0")
  assert.equal(s.workspace, 9)
})

test("flatten produces one rect per node with geometry by weight", () => {
  const s = M.parseStatus(fixture)
  const rects = M.flatten(s, { x: 0, y: 0, w: 1000, h: 600 }, { pad: 0, gap: 0 })
  assert.equal(rects.length, 9)
  const by = Object.fromEntries(rects.map(r => [r.id, r]))
  assert.deepEqual([by.w1.x, by.w1.w], [0, 500])
  assert.deepEqual([by.c0.x, by.c0.w], [500, 500])
  assert.deepEqual([by.w2.y, by.w2.h], [0, 300])         // column splits height
  assert.deepEqual([by.r1.y, by.r1.h], [300, 300])
  assert.equal(Math.round(by.w3.w), 125)                  // weight 1 of 4
  assert.equal(Math.round(by.t1.w), 375)                  // weight 3 of 4, tabs run as a row
  assert.equal(by.w4.parentId, "t1")
  assert.equal(by.root.parentId, null)
})

test("viewport and focus flags, containers before their children", () => {
  const s = M.parseStatus(fixture)
  const rects = M.flatten(s, { x: 0, y: 0, w: 1000, h: 600 })
  const by = Object.fromEntries(rects.map(r => [r.id, r]))
  assert.equal(by.c0.viewport, true)
  assert.equal(by.w1.inViewport, false)                   // parked
  assert.equal(by.w2.inViewport, true)
  assert.equal(by.w5.inViewport, true)
  assert.equal(by.w2.focused, true)
  assert.equal(by.c0.framing, "1")
  assert.ok(rects.findIndex(r => r.id === "c0") < rects.findIndex(r => r.id === "w2"))
})

test("padding and gaps shrink boxes but never below 1px", () => {
  const s = M.parseStatus(fixture)
  const rects = M.flatten(s, { x: 0, y: 0, w: 20, h: 10 }, { pad: 6, gap: 3 })
  for (const r of rects) { assert.ok(r.w >= 1 && r.h >= 1, r.id) }
  const w = M.flatten(s, { x: 0, y: 0, w: 1000, h: 600 }, { pad: 6, gap: 3 }).find(r => r.id === "w1")
  assert.deepEqual([w.x, w.y], [9, 9])                    // pad of root + gap
})

test("parentId, nodeById, firstWindow", () => {
  const s = M.parseStatus(fixture)
  assert.equal(M.parentId(s, "w4"), "t1")
  assert.equal(M.parentId(s, "root"), null)
  assert.equal(M.nodeById(s, "w3").address, "0x3")
  assert.equal(M.firstWindow(M.nodeById(s, "t1")).id, "w5")   // active tab 2
  assert.equal(M.firstWindow(M.nodeById(s, "c0")).id, "w2")
})

test("fitBox keeps the aspect ratio and centres", () => {
  assert.deepEqual(JSON.parse(JSON.stringify(M.fitBox(1000, 1000, 2))), { x: 0, y: 250, w: 1000, h: 500 })
  assert.deepEqual(JSON.parse(JSON.stringify(M.fitBox(1000, 200, 2))), { x: 300, y: 0, w: 400, h: 200 })
})

test("labels and font sizes stay within bounds", () => {
  assert.equal(M.label({ name: "a-very-long-window-class-name" }, 10), "a-very-lo…")
  assert.equal(M.label({ name: "nvim" }, 10), "nvim")
  const f = M.fontFor({ name: "nvim", w: 40, h: 20 }, 9, 18)
  assert.ok(f >= 9 && f <= 18)
  assert.equal(M.fontFor({ name: "x", w: 4000, h: 4000 }, 9, 18), 18)
})

test("prune drops dead windows and empty containers", () => {
  const s = M.parseStatus(fixture)
  const live = { "0x1": true, "0x3": true }
  const p = M.prune(s, live)
  const ids = M.flatten(p, { x: 0, y: 0, w: 100, h: 100 }).map(r => r.id).sort()
  assert.deepEqual(JSON.parse(JSON.stringify(ids)), ["c0", "r1", "root", "w1", "w3"])
  assert.equal(p.windows, 2)
  assert.equal(M.prune(s, {}).windows, 0)
  assert.equal(M.flatten(M.prune(s, {}), { x: 0, y: 0, w: 100, h: 100 }).length, 1)   // root survives
  assert.equal(M.flatten(s, { x: 0, y: 0, w: 100, h: 100 }).length, 9)                // original untouched
})

test("liveAddresses keeps tiled windows of one workspace", () => {
  const clients = JSON.stringify([
    { address: "0x1", workspace: { id: 9 }, floating: false },
    { address: "0x2", workspace: { id: 9 }, floating: true },
    { address: "0x3", workspace: { id: 1 }, floating: false },
  ])
  assert.deepEqual(JSON.parse(JSON.stringify(M.liveAddresses(clients, 9))), { "0x1": true })
  assert.deepEqual(JSON.parse(JSON.stringify(M.liveAddresses("garbage", 9))), {})
})

test("hit returns the deepest rect, windows over containers", () => {
  const s = M.parseStatus(fixture)
  const rects = M.flatten(s, { x: 0, y: 0, w: 1000, h: 600 }, { pad: 10, gap: 4 })
  assert.equal(M.hit(rects, 200, 300).id, "w1")
  assert.equal(M.hit(rects, 5, 5).id, "root")            // in the root's padding
  assert.equal(M.hit(rects, 505, 100).id, "c0")           // in c0 padding, left edge
  assert.equal(M.hit(rects, -5, 5), null)
})

test("windowsIn collects windows touching a marquee, in any drag direction", () => {
  const s = M.parseStatus(fixture)
  const rects = M.flatten(s, { x: 0, y: 0, w: 1000, h: 600 }, { pad: 0, gap: 0 })
  assert.deepEqual(JSON.parse(JSON.stringify(M.windowsIn(rects, { x: 100, y: 100, w: 600, h: 100 }).sort())), ["w1", "w2"])
  assert.deepEqual(JSON.parse(JSON.stringify(M.windowsIn(rects, { x: 700, y: 200, w: -600, h: -100 }).sort())), ["w1", "w2"])
  assert.deepEqual(JSON.parse(JSON.stringify(M.windowsIn(rects, { x: 990, y: 590, w: 5, h: 5 }))), ["w5"])
})

test("windowsUnder resolves containers to their windows", () => {
  const s = M.parseStatus(fixture)
  const rects = M.flatten(s, { x: 0, y: 0, w: 1000, h: 600 })
  assert.deepEqual(JSON.parse(JSON.stringify(M.windowsUnder(rects, "t1").sort())), ["w4", "w5"])
  assert.deepEqual(JSON.parse(JSON.stringify(M.windowsUnder(rects, "w1"))), ["w1"])
  assert.deepEqual(JSON.parse(JSON.stringify(M.normalise({ x: 10, y: 10, w: -4, h: -6 }))), { x: 6, y: 4, w: 4, h: 6 })
})

test("visible flag comes from the status, defaulting to true", () => {
  const s = M.parseStatus(fixture)
  s.tree.children[0].visible = false
  const rects = M.flatten(s, { x: 0, y: 0, w: 1000, h: 600 })
  const by = Object.fromEntries(rects.map(r => [r.id, r]))
  assert.equal(by.w1.visible, false)
  assert.equal(by.w2.visible, true)
})
