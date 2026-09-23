-- fractal.lua — Hyprland glue for the fractal layout (Lua config API, Hyprland 0.56+).
--
--   local fractal = require("hypr.fractal").setup({ name = "fractal" })
--   hl.workspace_rule({ workspace = "9", layout = "lua:fractal" })
--   hl.bind("SUPER + CTRL + UP", hl.dsp.layout("zoom-out"))
--
-- Commands arrive through the layout-message dispatcher (hl.dsp.layout("...")),
-- which Hyprland routes to the layout of the *active* workspace, so keybinds and
-- `hyprctl dispatch 'hl.dsp.layout("zoom-in")'` both work. State is saved per
-- workspace under $XDG_STATE_HOME/fractal-wm and a rendered status under
-- $XDG_RUNTIME_DIR/fractal-wm for CLIs and shell widgets.

local modname = ...
local T = require((type(modname) == "string" and modname or "hypr.fractal"):gsub("fractal$", "fractal_tree"))

local HOME = os.getenv("HOME") or ""
local STATE_DIR = (os.getenv("XDG_STATE_HOME") or (HOME .. "/.local/state")) .. "/fractal-wm"
local RUNTIME_DIR = (os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/fractal-wm"
local OFFSCREEN = 20000 -- hidden windows are parked this far right of the work area

local M = { name = "fractal", trees = {}, desktop = false, state_dir = STATE_DIR, runtime_dir = RUNTIME_DIR }

-- ------------------------------------------------------------------ files --

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function write_file(path, text)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(text)
  f:close()
  return true
end

local function log(fmt, ...)
  local f = io.open(STATE_DIR .. "/fractal.log", "a")
  if not f then return end
  f:write(os.date("%Y-%m-%d %H:%M:%S "), string.format(fmt, ...), "\n")
  f:close()
end
M.log = log

-- Hyprland hands numbers to Lua as floats (9.0); keep keys and file names integral.
local function ws_key(ws)
  local n = tonumber(ws)
  if n and n == math.floor(n) then return string.format("%d", n) end
  return tostring(ws)
end
M.ws_key = ws_key

local function state_path(ws) return string.format("%s/ws-%s.lua", STATE_DIR, ws_key(ws)) end

local function load_state(ws)
  local text = read_file(state_path(ws))
  if not text then return nil end
  local tree, err = T.deserialize(text)
  if not tree then log("workspace %s: state unreadable (%s), starting fresh", tostring(ws), tostring(err)) end
  return tree
end

local function save(ws, tree)
  write_file(state_path(ws), T.serialize(tree))
  write_file(string.format("%s/ws-%s.txt", RUNTIME_DIR, ws_key(ws)), T.render(tree) .. "\n")
  write_file(string.format("%s/ws-%s.json", RUNTIME_DIR, ws_key(ws)), T.to_json(tree, { workspace = tonumber(ws_key(ws)) or ws_key(ws) }) .. "\n")
end

-- ------------------------------------------------------------ hypr glue --

local function tree_for(ws)
  local tree = M.trees[ws]
  if not tree then
    tree = load_state(ws) or T.new({ desktop = M.desktop })
    M.trees[ws] = tree
  end
  return tree
end

local function ws_of(ctx)
  for _, t in ipairs(ctx.targets) do
    local w = t.window
    if w and w.workspace then return ws_key(w.workspace.id) end
  end
  local ok, a = pcall(hl.get_active_workspace)
  return ws_key((ok and a) and a.id or 0)
end

local function live_windows(ctx)
  local out = {}
  for _, t in ipairs(ctx.targets) do
    local w = t.window
    if w and w.address then
      local label = w.class
      if not label or label == "" then label = w.title end
      out[#out + 1] = { address = w.address, label = label or "" }
    end
  end
  return out
end

-- Track what Hyprland considers active. If the active window is in the tree
-- but outside the viewport, pull the camera back to the nearest node that
-- shows both, so keyboard focus never lands on an invisible window.
local function refresh_focus(tree)
  local ok, aw = pcall(hl.get_active_window)
  if not (ok and aw and aw.address) then return end
  local leaf = T.find_window(tree, aw.address)
  if not leaf then return end
  T.set_focus(tree, aw.address)
  if not T.contains(tree.viewport, leaf) then
    local n = tree.viewport
    while n and not T.contains(n, leaf) do n = n.parent end
    if n then T.zoom_to(tree, n) end
  end
end

local function apply(tree, ctx)
  local area = ctx.area
  local boxes = T.layout(tree, area)
  local parked = {
    x = area.x + area.w + OFFSCREEN,
    y = area.y,
    w = math.max(200, math.floor(area.w / 3)),
    h = math.max(150, math.floor(area.h / 3)),
  }
  for _, t in ipairs(ctx.targets) do
    local w = t.window
    local b = w and boxes[w.address] or nil
    t:place(b or parked)
  end
end

local function fallback(ctx)
  local n = #ctx.targets
  for i, t in ipairs(ctx.targets) do t:place(ctx:column(i, n)) end
end

local function focus_later(address)
  pcall(hl.timer, function()
    local win = hl.get_window("address:" .. address)
    if win then pcall(hl.dispatch, hl.dsp.focus({ window = win })) end
  end, { timeout = 20, type = "oneshot" })
end

local function notify(text)
  pcall(hl.exec_cmd, string.format("notify-send -a fractal -t 1500 %q", text))
end

-- -------------------------------------------------------------- commands --

local KINDS = { row = "row", h = "row", horizontal = "row", column = "column", v = "column", vertical = "column", col = "column", tabs = "tabs", tab = "tabs", t = "tabs" }
local DIRS = { left = "left", right = "right", up = "up", down = "down", l = "left", r = "right", u = "up", d = "down" }

local function where(tree)
  local parts = {}
  for _, n in ipairs(T.path(tree)) do parts[#parts + 1] = T.name(n) end
  return "viewport: " .. table.concat(parts, " > ") .. string.format("  (%s, depth %d)", tree.viewport.id, #parts - 1)
end

local HELP = [[
fractal layout commands (hl.dsp.layout("<cmd>") / fractal <cmd>):
  zoom-in (focused window becomes the top of the view) | zoom-step (one level) | zoom-out
  zoom-root | zoom-desktop | zoom <node-id|address>
  back | forward
  frame-save <name> | frame <name> | frame-delete <name> | frames
  split row|column|tabs      wrap the focused window so the next one opens beside it
  layout row|column|tabs|next  change the container around the focused window
  move left|right|up|down    move the focused window, i3-style
  tab next|prev              cycle a tabs container
  grow | shrink              change the focused window's share
  desktop on|off             add or remove the wallpaper leaf
  reset                      rebuild the tree from the live windows
  tree | status | help]]

local function handle(tree, msg)
  local words = {}
  for w in tostring(msg or ""):gmatch("%S+") do words[#words + 1] = w end
  local cmd = (words[1] or "help"):lower()
  local arg = words[2]
  local rest = table.concat(words, " ", 2)

  if cmd == "zoom-in" or cmd == "in" then
    return T.zoom_in(tree) and where(tree) or "already at a single window"
  elseif cmd == "zoom-step" then
    return T.zoom_step(tree) and where(tree) or "already at a single window"
  elseif cmd == "zoom-out" or cmd == "out" then
    return T.zoom_out(tree) and where(tree) or "already at the root"
  elseif cmd == "zoom-root" or cmd == "root" or cmd == "overview" then
    T.zoom_root(tree)
    return where(tree)
  elseif cmd == "zoom-desktop" then
    return T.zoom_desktop(tree) and where(tree) or "no desktop node (fractal desktop on)"
  elseif cmd == "zoom" then
    local node = arg and (T.find(tree, arg) or T.find_window(tree, arg))
    if not node then return "no such node: " .. tostring(arg) end
    T.zoom_to(tree, node)
    return where(tree)
  elseif cmd == "back" then
    return T.back(tree) and where(tree) or "no history"
  elseif cmd == "forward" then
    return T.forward(tree) and where(tree) or "nothing ahead"
  elseif cmd == "frame-save" then
    if rest == "" then return "usage: frame-save <name>" end
    local node = T.save_framing(tree, rest)
    return string.format("framing %q -> %s %s", rest, node.id, T.name(node))
  elseif cmd == "frame" then
    if rest == "" then return "usage: frame <name>" end
    return T.go_framing(tree, rest) and where(tree) or ("no framing named " .. rest)
  elseif cmd == "frame-delete" then
    tree.framings[rest] = nil
    return "deleted framing " .. rest
  elseif cmd == "frames" then
    local names = {}
    for k in pairs(tree.framings) do names[#names + 1] = k end
    table.sort(names)
    return #names > 0 and ("framings: " .. table.concat(names, ", ")) or "no framings"
  elseif cmd == "split" then
    local kind = KINDS[(arg or ""):lower()]
    if not kind then return "usage: split row|column|tabs" end
    return T.split(tree, kind) and ("split " .. kind) or "no focused window in view"
  elseif cmd == "layout" then
    local kind = KINDS[(arg or ""):lower()]
    if (arg or ""):lower() == "next" then
      local f = T.focused_node(tree)
      local container = (f and f ~= tree.viewport and T.contains(tree.viewport, f)) and f.parent or tree.viewport
      local order = { row = "column", column = "tabs", tabs = "row" }
      kind = container and order[container.kind] or "row"
    end
    if not kind then return "usage: layout row|column|tabs|next" end
    return T.set_layout(tree, kind) and ("layout " .. kind) or "nothing to change"
  elseif cmd == "move" then
    local dir = DIRS[(arg or ""):lower()]
    if not dir then return "usage: move left|right|up|down" end
    return T.move(tree, dir) and ("moved " .. dir) or "can't move that way"
  elseif cmd == "tab" then
    local delta = (arg == "prev" or arg == "previous") and -1 or 1
    return T.tab_cycle(tree, delta) and "tab switched" or "no tabs container in view"
  elseif cmd == "grow" then
    return T.resize(tree, 1.15) and "grew" or "nothing to resize"
  elseif cmd == "shrink" then
    return T.resize(tree, 1 / 1.15) and "shrank" or "nothing to resize"
  elseif cmd == "desktop" then
    local d = T.desktop_node(tree)
    if arg == "on" and not d then
      table.insert(tree.root.children, 1, T.node(tree, "desktop", { parent = tree.root }))
      return "desktop node added"
    elseif arg == "off" and d then
      T.remove_window = T.remove_window -- keep linter quiet
      if tree.viewport == d then tree.viewport = tree.root end
      for i, c in ipairs(tree.root.children) do if c == d then table.remove(tree.root.children, i) break end end
      return "desktop node removed"
    end
    return d and "desktop node is on" or "desktop node is off"
  elseif cmd == "reset" then
    return "reset"
  elseif cmd == "tree" or cmd == "status" then
    return T.render(tree)
  elseif cmd == "help" then
    return HELP
  end
  return "unknown command: " .. cmd .. "\n" .. HELP
end

-- --------------------------------------------------------------- provider --

function M.recalculate(ctx)
  local ok, err = pcall(function()
    if #ctx.targets == 0 then return end
    local ws = ws_of(ctx)
    local tree = tree_for(ws)
    T.sync(tree, live_windows(ctx), ctx.area)
    refresh_focus(tree)
    apply(tree, ctx)
    save(ws, tree)
  end)
  if not ok then
    log("recalculate error: %s", tostring(err))
    pcall(fallback, ctx)
  end
end

function M.layout_msg(ctx, msg)
  local reply
  local ok, err = pcall(function()
    local ws = ws_of(ctx)
    local tree = tree_for(ws)
    if tostring(msg):match("^%s*reset%s*$") then
      tree = T.new({ desktop = M.desktop })
      M.trees[ws] = tree
    end
    T.sync(tree, live_windows(ctx), ctx.area)
    refresh_focus(tree)
    local before = tree.focused
    reply = handle(tree, msg)
    apply(tree, ctx)
    save(ws, tree)
    write_file(RUNTIME_DIR .. "/last-reply.txt", tostring(reply) .. "\n")
    if tree.focused and tree.focused ~= before then focus_later(tree.focused) end
    if M.notify and reply and not reply:find("\n") then notify(reply) end
  end)
  if not ok then
    log("layout_msg %q error: %s", tostring(msg), tostring(err))
    write_file(RUNTIME_DIR .. "/last-reply.txt", "error: " .. tostring(err) .. "\n")
    return "fractal: " .. tostring(err)
  end
  -- A returned string reaches hyprctl as an error message, so replies go through
  -- $XDG_RUNTIME_DIR/fractal-wm/last-reply.txt (the `fractal` CLI prints it).
  M.last_reply = reply
  return true
end

-- ------------------------------------------------------------------ setup --

function M.setup(opts)
  opts = opts or {}
  M.name = opts.name or "fractal"
  M.desktop = opts.desktop == true
  M.notify = opts.notify ~= false
  pcall(os.execute, string.format("mkdir -p %q %q", STATE_DIR, RUNTIME_DIR))

  -- Hyprland refuses to register a layout name twice and Omarchy reloads keep
  -- the Lua state, so register once and hot-swap the implementation behind it.
  _G.__fractal = _G.__fractal or {}
  local G = _G.__fractal
  G.impl = M
  if not G.registered then
    hl.layout.register(M.name, {
      recalculate = function(ctx) return G.impl.recalculate(ctx) end,
      layout_msg = function(ctx, msg) return G.impl.layout_msg(ctx, msg) end,
    })
    G.registered = true
  end
  if G.sub then pcall(function() G.sub:remove() end) end
  G.sub = hl.on("window.active", function(w)
    pcall(function()
      if not (w and w.address and w.workspace) then return end
      local tree = M.trees[ws_key(w.workspace.id)]
      if tree and T.find_window(tree, w.address) then T.set_focus(tree, w.address) end
    end)
  end)

  -- Workspaces the CLI switched on (one id per line) come back after a reload.
  local enabled = read_file(STATE_DIR .. "/enabled.txt") or ""
  for ws in enabled:gmatch("%S+") do
    pcall(hl.workspace_rule, { workspace = ws, layout = "lua:" .. M.name })
  end
  log("setup: layout lua:%s ready", M.name)
  return M
end

return M
