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
local OFFSCREEN = 20000 -- hidden windows are parked this far right of the work area (park = "offscreen")

local M = { name = "fractal", trees = {}, desktop = false, park = "corner", park_inset = 12, state_dir = STATE_DIR, runtime_dir = RUNTIME_DIR }

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
      out[#out + 1] = { address = w.address, label = label or "", title = w.title or "" }
    end
  end
  return out
end

local function focus_later(address)
  pcall(hl.timer, function()
    local win = hl.get_window("address:" .. address)
    if win then pcall(hl.dispatch, hl.dsp.focus({ window = win })) end
  end, { timeout = 20, type = "oneshot" })
end

-- Track what Hyprland considers active. If the active window is in the tree
-- but outside the viewport, pull the camera back to the nearest node that
-- shows both, so keyboard focus never lands on an invisible window.
--
-- Exception: right after a zoom command, focus may still be settling (an
-- overlay closing hands focus back to the previously active window, for
-- instance). For a short grace period the intended window is re-focused
-- instead of dragging the viewport back out.
local function refresh_focus(tree)
  local ok, aw = pcall(hl.get_active_window)
  if not (ok and aw and aw.address) then return end
  local leaf = T.find_window(tree, aw.address)
  if not leaf then return end
  if tree.pending_focus and tree.pending_focus ~= aw.address then
    if T.find_window(tree, tree.pending_focus) then
      focus_later(tree.pending_focus)
      return
    end
    tree.pending_focus = nil
  end
  T.set_focus(tree, aw.address)
  if not T.contains(tree.viewport, leaf) then
    local n = tree.viewport
    while n and not T.contains(n, leaf) do n = n.parent end
    if n then T.zoom_to(tree, n) end
  elseif not T.is_visible(tree, leaf) then
    T.unhide(tree, leaf.address) -- hidden by a selection: bring it into the view
  end
end

local function settle_focus(tree, address)
  tree.pending_focus = address
  focus_later(address)
  pcall(hl.timer, function()
    if tree.pending_focus == address then tree.pending_focus = nil end
  end, { timeout = 400, type = "oneshot" })
end

-- Parked windows carry the tag "fractal-parked", which a window rule turns
-- fully transparent: they must overlap the monitor for Hyprland to render them
-- (thumbnails), but nothing of them may show. Tag changes are dispatched from
-- a timer, never from inside the layout pass.
M.TAG = "fractal-parked"

local function retag(tree, now_parked, all_addresses)
  local changes = {}
  if tree.parked == nil then
    -- First pass after a (re)load: nothing is known about existing tags, so
    -- state every window's tag once instead of trusting a diff.
    for a in pairs(all_addresses or now_parked) do changes[#changes + 1] = { a, now_parked[a] and "+" or "-" } end
  else
    for a in pairs(now_parked) do if not tree.parked[a] then changes[#changes + 1] = { a, "+" } end end
    for a in pairs(tree.parked) do if not now_parked[a] then changes[#changes + 1] = { a, "-" } end end
  end
  tree.parked = now_parked
  if #changes == 0 then return end
  pcall(hl.timer, function()
    for _, c in ipairs(changes) do
      local win = hl.get_window("address:" .. c[1])
      if win then pcall(hl.dispatch, hl.dsp.window.tag({ tag = c[2] .. M.TAG, window = win })) end
    end
  end, { timeout = 1, type = "oneshot" })
end
M.retag = retag

local function apply(tree, ctx)
  local area = ctx.area
  local boxes = T.layout(tree, area)
  local pw, ph = math.max(200, math.floor(area.w / 3)), math.max(150, math.floor(area.h / 3))
  -- Remember each window's last visible box: a parked window keeps that size,
  -- so its app does not reflow and the map's thumbnail still shows it as it was.
  tree.last_box = tree.last_box or {}
  for addr, b in pairs(boxes) do tree.last_box[addr] = { w = b.w, h = b.h } end
  local parked
  if M.park == "corner" then
    -- Hyprland only renders (and lets the shell capture) windows whose box
    -- touches their monitor. Park hidden windows so that a single pixel of
    -- content sits inside the monitor's top-left corner, under the bar:
    -- thumbnails keep working and nothing readable shows on screen.
    local mon = nil
    for _, t in ipairs(ctx.targets) do
      if t.window and t.window.monitor then mon = t.window.monitor break end
    end
    local mx, my = area.x - 5, area.y - 31
    if mon then mx, my = mon.x, mon.y end
    parked = { mx = mx, my = my, w = pw, h = ph, raw = true }
  elseif M.park == "top" then
    parked = { x = area.x, y = area.y - ph - 2, w = pw, h = ph }
  elseif M.park == "sliver" then
    parked = { x = area.x + area.w - 8, y = area.y, w = pw, h = ph }
  else
    parked = { x = area.x + area.w + OFFSCREEN, y = area.y, w = pw, h = ph }
  end
  local now_parked, all = {}, {}
  for _, t in ipairs(ctx.targets) do
    local w = t.window
    local b = w and boxes[w.address] or nil
    if w and w.address then all[w.address] = true end
    if b then
      t:place(b)
    else
      if w and w.address then now_parked[w.address] = true end
      if parked.raw then
        local last = w and tree.last_box[w.address] or nil
        local bw, bh = (last and last.w) or parked.w, (last and last.h) or parked.h
        -- exact geometry, no gaps: the corner overlap must be precise
        t:set_box({ x = parked.mx - bw + M.park_inset, y = parked.my - bh + M.park_inset, w = bw, h = bh })
      else
        t:place(parked)
      end
    end
  end
  retag(tree, now_parked, all)
end

local function fallback(ctx)
  local n = #ctx.targets
  for i, t in ipairs(ctx.targets) do t:place(ctx:column(i, n)) end
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
  local sel = ""
  if tree.mask then
    local shown, hidden = 0, #T.hidden_windows(tree)
    for _ in pairs(tree.mask) do shown = shown + 1 end
    sel = string.format("  [%d shown, %d hidden]", shown, hidden)
  end
  return "viewport: " .. table.concat(parts, " > ") .. string.format("  (%s, depth %d)%s", tree.viewport.id, #parts - 1, sel)
end

local HELP = [[
fractal layout commands (hl.dsp.layout("<cmd>") / fractal <cmd>):
  zoom-in (focused window becomes the top of the view) | zoom-step (one level) | zoom-out
  zoom-root | zoom-desktop | zoom <node-id|address>
  show <id> <id>...          view exactly these tiles (viewport = their common ancestor, rest hidden)
  hide [id] | unhide <id>    drop / bring back one tile in the current view
  show-all | hidden          clear the selection / list hidden tiles
  back | forward
  frame-save <name> | frame <name> | frame-delete <name> | frames   (framings keep selections)
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
  elseif cmd == "show" then
    if #words < 2 then return "usage: show <id|address> [more...]" end
    local ids = {}
    for i = 2, #words do ids[#ids + 1] = words[i] end
    return T.show(tree, ids) and where(tree) or "no such tiles"
  elseif cmd == "hide" then
    return T.hide(tree, arg) and where(tree) or "can't hide that (last visible tile, or not in view)"
  elseif cmd == "unhide" then
    if not arg then return "usage: unhide <id|address>" end
    return T.unhide(tree, arg) and where(tree) or "no such tile"
  elseif cmd == "show-all" then
    T.show_all(tree)
    return where(tree)
  elseif cmd == "hidden" then
    local names = {}
    for _, w in ipairs(T.hidden_windows(tree)) do names[#names + 1] = w.id .. " " .. T.name(w) end
    return #names > 0 and ("hidden: " .. table.concat(names, ", ")) or "nothing hidden"
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
    if tree.focused and tree.focused ~= before then settle_focus(tree, tree.focused) end
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
  M.park = opts.park or "corner"      -- corner (default) | offscreen
  M.park_inset = opts.park_inset or 12  -- set_box shaves ~5 px per side and terminals snap to cells: keep a few px inside
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

  -- Parked windows are made invisible by this rule (see retag).
  pcall(hl.window_rule, { name = "fractal-parked", match = { tag = M.TAG }, opacity = "0 0 0", no_shadow = true })

  -- Workspaces the CLI switched on (one id per line) come back after a reload.
  local enabled = read_file(STATE_DIR .. "/enabled.txt") or ""
  for ws in enabled:gmatch("%S+") do
    pcall(hl.workspace_rule, { workspace = ws, layout = "lua:" .. M.name })
  end
  log("setup: layout lua:%s ready", M.name)
  return M
end

return M
