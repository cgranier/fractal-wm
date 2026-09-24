// Pure model for the Fractal Map overlay: turns the status JSON written by the
// fractal-wm layout ($XDG_RUNTIME_DIR/fractal-wm/ws-<id>.json) into a flat list
// of rectangles to draw. No Quickshell here, so `node --test` covers it.
.pragma library

function parseStatus(text) {
  if (!text) return null
  var s
  try { s = JSON.parse(text) } catch (e) { return null }
  if (!s || typeof s !== "object" || !s.tree) return null
  return s
}

// Walk the tree once and index parents.
function index(tree) {
  var byId = {}
  var parentOf = {}
  function walk(node, parent) {
    byId[node.id] = node
    parentOf[node.id] = parent ? parent.id : null
    for (var i = 0; i < (node.children || []).length; i++) walk(node.children[i], node)
  }
  walk(tree, null)
  return { byId: byId, parentOf: parentOf }
}

function isContainer(node) {
  return node.kind === "row" || node.kind === "column" || node.kind === "tabs"
}

function firstWindow(node) {
  if (node.kind === "window") return node
  var kids = node.children || []
  if (node.kind === "tabs" && kids.length) {
    var a = Math.min(Math.max(1, node.active || 1), kids.length) - 1
    return firstWindow(kids[a])
  }
  for (var i = 0; i < kids.length; i++) {
    var f = firstWindow(kids[i])
    if (f) return f
  }
  return null
}

// Flatten the tree into rectangles inside `box` ({x,y,w,h}). Containers keep a
// `pad` inset per level so their border stays visible and clickable; windows
// get a small `gap`. `viewportId` marks which subtree is on screen now.
function flatten(status, box, opts) {
  opts = opts || {}
  var pad = opts.pad === undefined ? 6 : opts.pad
  var gap = opts.gap === undefined ? 3 : opts.gap
  var tree = status.tree
  var idx = index(tree)
  var viewportId = status.viewport
  var rects = []

  function place(node, b, depth, inView) {
    var mine = inView || node.id === viewportId
    var isWin = node.kind === "window"
    var rect = {
      id: node.id, kind: node.kind, name: node.name || node.kind, address: node.address || "", title: node.title || "",
      depth: depth, x: b.x, y: b.y, w: Math.max(1, b.w), h: Math.max(1, b.h),
      isWindow: isWin, isDesktop: node.kind === "desktop",
      viewport: node.id === viewportId, focused: !!node.focused, framing: node.framing || "",
      parentId: idx.parentOf[node.id], inViewport: mine,
      children: (node.children || []).length
    }
    if (isWin || node.kind === "desktop") {
      rect.x += gap; rect.y += gap; rect.w = Math.max(1, rect.w - 2 * gap); rect.h = Math.max(1, rect.h - 2 * gap)
      rects.push(rect)
      return
    }
    rects.push(rect)
    var kids = node.children || []
    if (!kids.length) return
    var inner = { x: b.x + pad, y: b.y + pad, w: Math.max(1, b.w - 2 * pad), h: Math.max(1, b.h - 2 * pad) }
    var total = 0
    for (var i = 0; i < kids.length; i++) total += (kids[i].weight || 1)
    var offset = 0
    var horizontal = node.kind !== "column"   // row and tabs run left to right
    for (var j = 0; j < kids.length; j++) {
      var share = (kids[j].weight || 1) / total
      var cb = horizontal
        ? { x: inner.x + offset * inner.w, y: inner.y, w: share * inner.w, h: inner.h }
        : { x: inner.x, y: inner.y + offset * inner.h, w: inner.w, h: share * inner.h }
      place(kids[j], cb, depth + 1, mine)
      offset += share
    }
  }

  place(tree, box, 0, false)
  return rects
}

function parentId(status, id) {
  return index(status.tree).parentOf[id] || null
}

function nodeById(status, id) {
  return index(status.tree).byId[id] || null
}

// Fit a map of the monitor's aspect ratio into the available card area.
function fitBox(availW, availH, aspect) {
  var w = availW
  var h = w / aspect
  if (h > availH) { h = availH; w = h * aspect }
  return { x: (availW - w) / 2, y: (availH - h) / 2, w: w, h: h }
}

// Short label for a window rectangle: class, plus a trimmed title if there is room.
function label(rect, maxChars) {
  var name = rect.name || rect.kind
  if (name.length > maxChars) name = name.slice(0, Math.max(1, maxChars - 1)) + "…"
  return name
}

// Font size that fits the rectangle: never below `min`, never above `max`.
function fontFor(rect, min, max) {
  var byH = rect.h / 3.2
  var byW = rect.w / Math.max(6, (rect.name || rect.kind).length * 0.62)
  return Math.max(min, Math.min(max, byH, byW))
}

// Drop windows that no longer exist (the layout only rewrites the file while
// the workspace has windows, so an emptied workspace leaves a stale tree).
// `live` is a set of addresses. Containers left empty disappear too.
function prune(status, live) {
  if (!status || !live) return status
  function keep(node) {
    if (node.kind === "window") return live[node.address] === true
    if (node.kind === "desktop") return true
    var kids = []
    for (var i = 0; i < (node.children || []).length; i++) {
      var c = node.children[i]
      if (keep(c)) kids.push(c)
    }
    node.children = kids
    return kids.length > 0 || node.id === status.tree.id
  }
  var copy = JSON.parse(JSON.stringify(status))
  keep(copy.tree)
  var windows = 0
  ;(function count(n) { if (n.kind === "window") windows++; for (var i = 0; i < (n.children || []).length; i++) count(n.children[i]) })(copy.tree)
  copy.windows = windows
  return copy
}

// Addresses of the tiled windows on one workspace, from `hyprctl clients -j`.
function liveAddresses(clientsJson, workspaceId) {
  var live = {}
  var clients
  try { clients = JSON.parse(clientsJson || "[]") } catch (e) { return live }
  for (var i = 0; i < clients.length; i++) {
    var c = clients[i]
    if (c && c.workspace && c.workspace.id === workspaceId && !c.floating) live[c.address] = true
  }
  return live
}
