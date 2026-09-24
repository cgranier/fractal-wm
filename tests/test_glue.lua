-- Offline test of the Hyprland glue with a fake `hl`. Run: lua tests/test_glue.lua
local S = os.getenv("TMPDIR") or "/tmp"
local root = S .. "/fractal-glue-test"
os.execute(string.format("rm -rf %q && mkdir -p %q/hypr %q/state %q/run", root, root, root, root))
os.execute(string.format("ln -s %q/lua/fractal.lua %q/hypr/fractal.lua && ln -s %q/lua/fractal_tree.lua %q/hypr/fractal_tree.lua", os.getenv("PWD"), root, os.getenv("PWD"), root))
package.path = root .. "/?.lua;" .. package.path

-- Fake environment ---------------------------------------------------------
local calls = { dispatch = {}, timers = {}, rules = {} }
local active_window, active_ws = nil, { id = 9, name = "9" }
_G.hl = {
  get_active_window = function() return active_window end,
  get_active_workspace = function() return active_ws end,
  timer = function(fn, opts) calls.timers[#calls.timers + 1] = fn return {} end,
  dispatch = function(d) calls.dispatch[#calls.dispatch + 1] = d end,
  exec_cmd = function() end,
  dsp = { focus = function(t) return "focus:" .. tostring(t.window) end,
          window = { tag = function(t) return "tag:" .. tostring(t.tag) .. ":" .. tostring(t.window) end } },
  window_rule = function(spec) calls.rules[#calls.rules + 1] = spec end,
  get_window = function(sel) return sel end,
  layout = { register = function(name, provider) calls.registered = { name = name, provider = provider } end },
  on = function(event, fn) calls.on = fn return { remove = function() end } end,
  workspace_rule = function(spec) calls.rules[#calls.rules + 1] = spec end,
}

-- Redirect state dirs by faking env before requiring the module.
local real_getenv = os.getenv
os.getenv = function(k)
  if k == "XDG_STATE_HOME" then return root .. "/state" end
  if k == "XDG_RUNTIME_DIR" then return root .. "/run" end
  return real_getenv(k)
end

local M = require("hypr.fractal").setup({ notify = false })
local function reply() return _G.__fractal.impl.last_reply end
assert(calls.registered.name == "fractal", "registered under lua:fractal")
local provider = calls.registered.provider

local function win(addr, class) return { address = addr, class = class, title = class, workspace = { id = 9.0, name = "9" }, monitor = { x = 0, y = 0 } } end
local function ctx_for(windows, area)
  local ctx = { area = area or { x = 0, y = 0, w = 1200, h = 800 }, targets = {}, placed = {} }
  for i, w in ipairs(windows) do
    local t = { index = i, window = w, box = { x = 0, y = 0, w = 0, h = 0 } }
    t.place = function(self, b) ctx.placed[w.address] = b end
    t.set_box = function(self, b) ctx.placed[w.address] = b end
    ctx.targets[i] = t
  end
  ctx.column = function(self, i, n) return { x = (i - 1) * self.area.w / n, y = 0, w = self.area.w / n, h = self.area.h } end
  return ctx
end
local function fmt(b) return string.format("%d,%d,%d,%d", b.x, b.y, b.w, b.h) end

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then passed = passed + 1 else failed = failed + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end
local function eq(a, b, msg) if a ~= b then error(string.format("%s: expected %s, got %s", msg or "eq", tostring(b), tostring(a)), 2) end end

local A, B, C = win("0xa", "alacritty"), win("0xb", "chromium"), win("0xc", "nautilus")

test("first recalculate splits along the larger dimension: a | (b / c)", function()
  local ctx = ctx_for({ A, B, C })
  provider.recalculate(ctx)
  eq(fmt(ctx.placed["0xa"]), "0,0,600,800")
  eq(fmt(ctx.placed["0xb"]), "600,0,600,400")
  eq(fmt(ctx.placed["0xc"]), "600,400,600,400")
end)

test("split column forces the next split under the focused window", function()
  active_window = B
  local ctx = ctx_for({ A, B, C })
  provider.layout_msg(ctx, "split column")   -- b's tile is 600x400 (wide); force a column
  local D = win("0xd", "obsidian")
  ctx = ctx_for({ A, B, C, D })
  provider.recalculate(ctx)
  eq(fmt(ctx.placed["0xb"]), "600,0,600,200")
  eq(fmt(ctx.placed["0xd"]), "600,200,600,200")
  eq(fmt(ctx.placed["0xc"]), "600,400,600,400")
end)

test("zoom-in on b shows b as top window with d and c, parks a", function()
  local D = win("0xd", "obsidian")
  active_window = B
  local ctx = ctx_for({ A, B, C, D })
  provider.layout_msg(ctx, "zoom-in")
  assert(tostring(reply()):find("viewport: row > column"), reply())
  eq(fmt(ctx.placed["0xb"]), "0,0,1200,200")
  eq(fmt(ctx.placed["0xd"]), "0,200,1200,200")
  eq(fmt(ctx.placed["0xc"]), "0,400,1200,400")
  assert(ctx.placed["0xa"].x < 0, "a parked in the corner")
end)

test("state survives a fresh module instance (reload)", function()
  local f = io.open(root .. "/state/fractal-wm/ws-9.lua"); assert(f, "state file written"); f:close()
  package.loaded["hypr.fractal"] = nil
  package.loaded["hypr.fractal_tree"] = nil
  _G.__fractal = nil
  local M2 = require("hypr.fractal").setup({ notify = false })
  local D = win("0xd", "obsidian")
  local ctx = ctx_for({ A, B, C, D })
  calls.registered.provider.recalculate(ctx)
  eq(fmt(ctx.placed["0xb"]), "0,0,1200,200")
  assert(ctx.placed["0xa"].x < 0, "still zoomed after reload")
  provider = calls.registered.provider
end)

test("focusing a hidden window pulls the camera back", function()
  active_window = A
  local D = win("0xd", "obsidian")
  local ctx = ctx_for({ A, B, C, D })
  provider.recalculate(ctx)
  eq(fmt(ctx.placed["0xa"]), "0,0,600,800")
  eq(fmt(ctx.placed["0xb"]), "600,0,600,200")
end)

test("zoom-out from the root reports, back walks history, framings work", function()
  active_window = B
  local D = win("0xd", "obsidian")
  local ctx = ctx_for({ A, B, C, D })
  provider.layout_msg(ctx, "zoom-out"); eq(reply(), "already at the root")
  provider.layout_msg(ctx, "zoom-in")
  provider.layout_msg(ctx, "frame-save work")
  provider.layout_msg(ctx, "zoom-root")
  provider.layout_msg(ctx, "frames"); assert(tostring(reply()):find("work"))
  provider.layout_msg(ctx, "frame work"); assert(tostring(reply()):find("column"))
  provider.layout_msg(ctx, "back"); assert(tostring(reply()):find("viewport: row  "), "back to root")
  provider.layout_msg(ctx, "tree")
  assert(tostring(reply()):find("%[framing: work%]"), reply())
end)

test("closing windows prunes and unknown commands return help", function()
  local ctx = ctx_for({ A })
  provider.recalculate(ctx)
  eq(fmt(ctx.placed["0xa"]), "0,0,1200,800")
  provider.layout_msg(ctx, "bogus"); assert(tostring(reply()):find("unknown command"))
  local json = io.open(root .. "/run/fractal-wm/ws-9.json"):read("a")
  assert(json:find('"workspace":9'), json)
  eq(provider.layout_msg(ctx, "tree"), true, "layout_msg returns true, not the text")
end)

test("zooming schedules a focus change when focus leaves the view", function()
  local function run_timers()
    local fns = calls.timers
    calls.timers = {}
    for _, fn in ipairs(fns) do fn() end
  end
  local function focus_dispatches_since(n)
    local out = {}
    for i = n + 1, #calls.dispatch do
      if tostring(calls.dispatch[i]):find("^focus:") then out[#out + 1] = calls.dispatch[i] end
    end
    return out
  end
  local ctx = ctx_for({ A, B, C })
  active_window = A
  provider.recalculate(ctx)
  run_timers()
  local mark = #calls.dispatch
  provider.layout_msg(ctx, "zoom-in")            -- viewport = A, focus stays on A
  run_timers()
  eq(#focus_dispatches_since(mark), 0, "no focus change needed")
  provider.layout_msg(ctx, "zoom-out")
  active_window = A
  provider.layout_msg(ctx, "move right")          -- a | (b/c) -> (b/c) | a
  provider.layout_msg(ctx, "zoom b")              -- unknown id -> error text, no crash
  run_timers()
  mark = #calls.dispatch
  local target = require("hypr.fractal_tree").find_window(_G.__fractal.impl.trees["9"], "0xc")
  provider.layout_msg(ctx, "zoom " .. target.id)   -- viewport = C; focus must move to C
  run_timers()
  local focused = focus_dispatches_since(mark)
  eq(#focused, 1, "one focus change scheduled")
  eq(focused[1], "focus:address:0xc")
end)

test("a zoom survives focus briefly snapping back to the old window", function()
  local ctx = ctx_for({ A, B, C })
  active_window = A
  provider.recalculate(ctx)
  provider.layout_msg(ctx, "zoom-root")
  local tree = _G.__fractal.impl.trees["9"]
  local T = require("hypr.fractal_tree")
  local c = T.find_window(tree, "0xc")
  provider.layout_msg(ctx, "zoom " .. c.id)          -- viewport = C, focus should settle on C
  eq(tree.viewport, c)
  -- an overlay closes and Hyprland hands focus back to A before C is focused
  active_window = A
  provider.recalculate(ctx)
  eq(tree.viewport, c, "viewport must not be dragged back out during the grace period")
  -- the grace period ends (the fake timer runs its callbacks)
  for _, fn in ipairs(calls.timers) do fn() end
  calls.timers = {}
  active_window = A
  provider.recalculate(ctx)
  eq(tree.viewport, tree.root, "after the grace period a real focus change reveals the window")
end)


test("show a c hides b and gives its space away; focusing b brings it back", function()
  local ctx = ctx_for({ A, B, C })
  active_window = A
  provider.layout_msg(ctx, "reset")             -- fresh tree: a | (b / c)
  provider.recalculate(ctx)
  local T = require("hypr.fractal_tree")
  local tree = _G.__fractal.impl.trees["9"]
  provider.layout_msg(ctx, "show " .. T.find_window(tree, "0xa").id .. " 0xc")
  assert(tostring(reply()):find("1 hidden"), reply())
  eq(fmt(ctx.placed["0xa"]), "0,0,600,800")
  eq(fmt(ctx.placed["0xc"]), "600,0,600,800")   -- c takes b's share
  assert(ctx.placed["0xb"].x < 0, "b parked")
  for _, fn in ipairs(calls.timers) do fn() end
  assert(calls.dispatch[#calls.dispatch]:find("^tag:%+fractal%-parked:address:0xb"), "b tagged parked: " .. tostring(calls.dispatch[#calls.dispatch]))
  calls.timers = {}
  active_window = B                              -- user alt-tabs to the hidden b
  provider.recalculate(ctx)
  eq(fmt(ctx.placed["0xb"]), "600,0,600,400")
  eq(fmt(ctx.placed["0xc"]), "600,400,600,400")
  provider.layout_msg(ctx, "hide 0xa")
  eq(fmt(ctx.placed["0xb"]), "0,0,1200,400")
  provider.layout_msg(ctx, "show-all")
  eq(fmt(ctx.placed["0xa"]), "0,0,600,800")
end)

test("last visible sizes are forgotten when windows close", function()
  local D = win("0xd", "obsidian")
  local ctx = ctx_for({ A, B, C, D })
  active_window = A
  provider.layout_msg(ctx, "reset")
  provider.recalculate(ctx)
  local tree = _G.__fractal.impl.trees["9"]
  eq(tree.last_box["0xd"] ~= nil, true, "d remembered")
  ctx = ctx_for({ A, B, C })                      -- d closed
  provider.recalculate(ctx)
  eq(tree.last_box["0xd"], nil, "d forgotten")
  eq(tree.last_box["0xa"] ~= nil, true, "a still remembered")
end)

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
