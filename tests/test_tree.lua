-- Run: lua tests/test_tree.lua   (from the repo root)
package.path = "lua/?.lua;" .. package.path
local T = require("fractal_tree")

local passed, failed = 0, 0
local function eq(a, b, msg)
  if a ~= b then error(string.format("%s: expected %s, got %s", msg or "eq", tostring(b), tostring(a)), 2) end
end
local function keys(boxes) local ks = {} for k in pairs(boxes) do ks[#ks + 1] = k end table.sort(ks) return table.concat(ks, ",") end
local function addrs(node) local out = {} for _, c in ipairs(node.children) do out[#out + 1] = c.address or c.kind end return table.concat(out, ",") end
local function box(b) return string.format("%d,%d,%d,%d", b.x, b.y, b.w, b.h) end
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function make(t, ...) for _, a in ipairs({ ... }) do T.add_window(t, a, a:upper()) end end
local AREA = { x = 0, y = 0, w = 300, h = 100 }
local function leaf(t, a) return T.node(t, "window", { address = a, label = a:upper() }) end

local WIDE = { x = 0, y = 0, w = 1368, h = 886 }

test("windows split the focused tile along its larger dimension", function()
  local t = T.new()
  make(t, "a")
  eq(addrs(t.root), "a")
  T.add_window(t, "b", "B", WIDE)           -- a is wide -> row, side by side
  eq(t.root.kind, "row")
  eq(addrs(t.root), "a,b")
  T.add_window(t, "c", "C", WIDE)           -- b is 684x886, tall -> column under b
  eq(addrs(t.root), "a,column")
  eq(addrs(t.root.children[2]), "b,c")
  local l = T.layout(t, WIDE)
  eq(box(l.a), "0,0,684,886")
  eq(box(l.b), "684,0,684,443")
  eq(box(l.c), "684,443,684,443")
  T.add_window(t, "d", "D", WIDE)           -- c is 684x443, wide -> row inside the column
  eq(box(T.layout(t, WIDE).d), "1026,443,342,443")
end)

test("split follows the focused window, not the last one", function()
  local t = T.new()
  make(t, "a")
  T.add_window(t, "b", "B", WIDE)
  T.set_focus(t, "a")
  T.add_window(t, "c", "C", WIDE)           -- a is tall -> c goes under a
  eq(addrs(t.root), "column,b")
  eq(addrs(t.root.children[1]), "a,c")
end)

test("without an area the split is a row", function()
  local t = T.new({ desktop = true })
  make(t, "a", "b")
  eq(addrs(t.root), "desktop,row")
  eq(addrs(t.root.children[2]), "a,b")
end)

test("zoomed into a leaf wraps it", function()
  local t = T.new()
  make(t, "a", "b")
  T.set_focus(t, "a")
  T.zoom_in(t)
  eq(t.viewport.address, "a")
  T.add_window(t, "c")
  eq(t.viewport.kind, "row")
  eq(addrs(t.viewport), "a,c")
  eq(addrs(t.root), "row,b")
end)

test("zoomed into desktop wraps it", function()
  local t = T.new({ desktop = true })
  make(t, "a")
  T.zoom_desktop(t)
  T.add_window(t, "b")
  eq(t.viewport.kind, "row")
  eq(addrs(t.viewport), "desktop,b")
  eq(keys(T.layout(t, AREA)), "b")
end)

test("row splits by weight", function()
  local t = T.new()
  make(t, "a", "b")
  T.find_window(t, "b").weight = 3
  local l = T.layout(t, { x = 0, y = 0, w = 400, h = 100 })
  eq(box(l.a), "0,0,100,100")
  eq(box(l.b), "100,0,300,100")
end)

test("split forces the next orientation, then tabs", function()
  local t = T.new()
  T.attach(t.root, leaf(t, "a")); T.attach(t.root, leaf(t, "b")); T.attach(t.root, leaf(t, "c"))
  T.set_focus(t, "b")
  T.split(t, "column")
  T.add_window(t, "d", "D", AREA)      -- b's tile is 100x100; forced column
  local col = T.find_window(t, "d").parent
  eq(col.kind, "column")
  eq(addrs(col), "b,d")
  eq(t.next_split, nil)
  T.set_layout(t, "tabs")
  local l = T.layout(t, AREA)
  eq(keys(l), "a,c,d")
  eq(box(l.d), "100,0,100,100")
  T.tab_cycle(t, 1)
  l = T.layout(t, AREA)
  eq(keys(l), "a,b,c")
  eq(t.focused, "b")
end)

-- root row: a, column(b, d), c ; focused d
local function build()
  local t = T.new()
  T.attach(t.root, leaf(t, "a"))
  local col = T.attach(t.root, T.node(t, "column"))
  T.attach(col, leaf(t, "b"))
  T.attach(col, leaf(t, "d"))
  T.attach(t.root, leaf(t, "c"))
  t.focused = "d"
  return t
end

test("viewport subtree fills area, rest hidden", function()
  local t = build()
  T.set_focus(t, "b")
  T.zoom_in(t)
  eq(t.viewport.kind, "column")
  local l = T.layout(t, AREA)
  eq(keys(l), "b,d")
  eq(box(l.b), "0,0,300,50")
  eq(box(l.d), "0,50,300,50")
end)

test("zoom in/out/history", function()
  local t = build()
  local col = T.focused_node(t).parent
  T.set_focus(t, "b")
  eq(T.zoom_in(t), col)                      -- b is the top of the column
  T.set_focus(t, "d")
  eq(T.zoom_in(t), T.find_window(t, "d"))    -- d has nothing split off it
  eq(T.zoom_in(t), nil)
  eq(T.zoom_out(t), col)
  eq(T.back(t), T.find_window(t, "d"))
  eq(T.back(t), col)
  eq(T.back(t), t.root)
  eq(T.back(t), nil)
  eq(T.forward(t), col)
  eq(T.zoom_out(t), t.root)
  eq(#t.forward, 0)
end)

test("zoom-in walks up while the focused window stays on top", function()
  local t = T.new()
  for _, a in ipairs({ "a", "b", "c", "d", "e" }) do T.add_window(t, a, a:upper(), WIDE) end
  -- a | (b / (c | (d / e)))
  T.set_focus(t, "c")
  local vp = T.zoom_in(t)
  eq(vp.kind, "row")
  eq(keys(T.layout(t, WIDE)), "c,d,e")
  eq(T.zoom_in(t).address, "c")
  T.zoom_root(t)
  T.set_focus(t, "b")
  eq(keys(T.layout(t, WIDE)), "a,b,c,d,e")
  T.zoom_in(t)
  eq(keys(T.layout(t, WIDE)), "b,c,d,e")
  eq(T.zoom_step(t).address, "b")
end)

test("zoom moves focus into view", function()
  local t = build()
  T.set_focus(t, "a")
  local col = T.find_window(t, "d").parent
  T.zoom_to(t, col)
  eq(t.focused, "b")
end)

test("framings follow nodes and die with them", function()
  local t = build()
  local col = T.focused_node(t).parent
  T.zoom_to(t, col)
  T.save_framing(t, "work")
  T.zoom_root(t)
  eq(T.go_framing(t, "work"), col)
  T.remove_window(t, "b")
  eq(T.go_framing(t, "work"), T.find_window(t, "d"))
  T.remove_window(t, "d")
  eq(T.go_framing(t, "work"), nil)
  eq(next(t.framings), nil)
end)

test("closing the viewport leaf returns to parent", function()
  local t = build()
  T.zoom_in(t)
  eq(t.viewport.address, "d")
  T.remove_window(t, "d")
  eq(t.viewport, T.find_window(t, "b"))
  eq(t.focused, "b")
end)

test("removing all windows keeps root", function()
  local t = T.new({ desktop = true })
  make(t, "a", "b")
  T.remove_window(t, "a")
  T.remove_window(t, "b")
  eq(addrs(t.root), "desktop")
  eq(t.viewport, t.root)
end)

test("sync adds and removes", function()
  local t = build()
  T.sync(t, { { address = "a" }, { address = "d" }, { address = "e", label = "E" } }, AREA)
  eq(addrs(t.root), "a,row")           -- d (150x100, wide) split into row(d, e)
  eq(addrs(t.root.children[2]), "d,e")
  eq(T.find_window(t, "e").label, "E")
end)

test("swap within row", function()
  local t = T.new()
  T.attach(t.root, leaf(t, "a")); T.attach(t.root, leaf(t, "b")); T.attach(t.root, leaf(t, "c"))
  T.set_focus(t, "a")
  eq(T.move(t, "right"), true)
  eq(addrs(t.root), "b,a,c")
  eq(T.move(t, "left"), true)
  eq(T.move(t, "left"), false)
  eq(addrs(t.root), "a,b,c")
end)

test("move out of column into row", function()
  local t = build()
  T.set_focus(t, "d")
  eq(T.move(t, "right"), true)
  eq(addrs(t.root), "a,b,d,c")
end)

test("move perpendicular wraps root", function()
  local t = T.new()
  T.attach(t.root, leaf(t, "a")); T.attach(t.root, leaf(t, "b"))
  T.set_focus(t, "b")
  eq(T.move(t, "down"), true)
  eq(#t.root.children, 1)
  local col = t.root.children[1]
  eq(col.kind, "column")
  eq(addrs(col), "a,b")
  local l = T.layout(t, { x = 0, y = 0, w = 100, h = 200 })
  eq(box(l.a), "0,0,100,100")
  eq(box(l.b), "0,100,100,100")
end)

test("resize clamps", function()
  local t = T.new()
  T.attach(t.root, leaf(t, "a")); T.attach(t.root, leaf(t, "b")); t.focused = "b"
  for _ = 1, 40 do T.resize(t, 1.5) end
  eq(T.find_window(t, "b").weight, 5.0)
end)

test("serialize roundtrip", function()
  local t = T.new({ desktop = true })
  make(t, "a", "b", "c")
  T.set_focus(t, "b")
  T.split(t, "tabs")
  T.add_window(t, "d", "D", AREA)
  T.zoom_in(t)
  T.save_framing(t, "x")
  T.zoom_root(t)
  T.resize(t, 1.5)
  local s = T.serialize(t)
  local u = assert(T.deserialize(s))
  eq(T.serialize(u), s)
  eq(T.render(u), T.render(t))
  eq(keys(T.layout(u, AREA)), keys(T.layout(t, AREA)))
  assert(T.render(u):find("%[framing: x%]"))
  assert(T.to_json(u):find('"framing":"x"'))
end)

test("deserialize rejects garbage", function()
  eq(T.deserialize("return 42"), nil)
  eq(T.deserialize("this is not lua"), nil)
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
