-- fractal_tree.lua — pure tree model for fractal window management.
--
-- One tree per workspace. Leaves are windows (or an optional "desktop" leaf);
-- interior nodes are containers: row, column, tabs. Any node can be the
-- *viewport*: the node whose box is mapped onto the work area. Everything
-- outside the viewport's subtree is hidden. No Hyprland calls here, so the
-- whole file runs under plain `lua` for tests.

local T = {}

T.CONTAINERS = { row = true, column = true, tabs = true }
local HORIZONTAL = { left = true, right = true }
local MIN_WEIGHT, MAX_WEIGHT = 0.2, 5.0
local HISTORY = 50

-- ---------------------------------------------------------------- helpers --

local seeded = false
local function new_id(tree)
  if not seeded then
    math.randomseed(os.time() + math.floor((os.clock() * 1e6) % 1e6))
    seeded = true
  end
  while true do
    local id = string.format("%04x", math.random(0, 0xffff))
    if not (tree and tree.root and T.find(tree, id)) then return id end
  end
end

local function is_container(n) return T.CONTAINERS[n.kind] == true end

local function index_of(parent, child)
  for i, c in ipairs(parent.children) do
    if c == child then return i end
  end
end

local function add(parent, child, index)
  child.parent = parent
  if index then table.insert(parent.children, index, child) else table.insert(parent.children, child) end
  if parent.kind == "tabs" then parent.active = index_of(parent, child) end
  return child
end

local function remove(parent, child)
  local idx = index_of(parent, child)
  if not idx then return end
  table.remove(parent.children, idx)
  child.parent = nil
  if parent.kind == "tabs" and #parent.children > 0 then
    parent.active = math.min(parent.active, #parent.children)
    if idx < parent.active then parent.active = parent.active - 1 end
  end
end

-- Swap `node` for `other` in the parent's list, keeping the slot weight.
local function replace_with(node, other)
  local parent = node.parent
  local idx = index_of(parent, node)
  parent.children[idx] = other
  other.parent = parent
  other.weight = node.weight
  node.parent = nil
end

local function contains(node, other)
  local n = other
  while n do
    if n == node then return true end
    n = n.parent
  end
  return false
end
T.contains = contains

local function walk(node, fn)
  fn(node)
  for _, c in ipairs(node.children) do walk(c, fn) end
end

local function active_child(n)
  if n.kind == "tabs" and #n.children > 0 then return n.children[math.min(n.active, #n.children)] end
end

local function first_window(n)
  if n.kind == "window" then return n end
  if n.kind == "tabs" then
    local c = active_child(n)
    return c and first_window(c) or nil
  end
  for _, c in ipairs(n.children) do
    local f = first_window(c)
    if f then return f end
  end
end
T.first_window = first_window
T.attach = add

function T.node(tree, kind, fields)
  local n = { kind = kind, id = new_id(tree), children = {}, weight = 1.0, active = 1 }
  for k, v in pairs(fields or {}) do n[k] = v end
  return n
end

function T.windows(node)
  local out = {}
  walk(node, function(n) if n.kind == "window" then out[#out + 1] = n end end)
  return out
end

function T.find(tree, id)
  local found
  walk(tree.root, function(n) if n.id == id then found = n end end)
  return found
end

function T.find_window(tree, address)
  local found
  walk(tree.root, function(n) if n.kind == "window" and n.address == address then found = n end end)
  return found
end

function T.desktop_node(tree)
  local found
  walk(tree.root, function(n) if n.kind == "desktop" then found = n end end)
  return found
end

local function focused_node(tree)
  return tree.focused and T.find_window(tree, tree.focused) or nil
end
T.focused_node = focused_node

local function in_viewport(tree, node)
  return node ~= nil and contains(tree.viewport, node)
end

local function focused_in_view(tree)
  local f = focused_node(tree)
  if in_viewport(tree, f) then return f end
end

function T.name(n)
  if n.kind == "window" then return (n.label ~= nil and n.label ~= "") and n.label or (n.address or "?") end
  if n.kind == "desktop" then return "Desktop" end
  return n.kind
end

-- ------------------------------------------------------------------ tree --

function T.new(opts)
  local tree = { back = {}, forward = {}, framings = {}, focused = nil }
  tree.root = T.node(tree, "row")
  if opts and opts.desktop then add(tree.root, T.node(tree, "desktop")) end
  tree.viewport = tree.root
  return tree
end

-- Drop empty containers and unwrap single-child ones (root excepted).
local function collapse(tree, node)
  while node ~= tree.root and is_container(node) do
    local parent = node.parent
    if not parent then return end
    if #node.children == 0 then
      if tree.viewport == node then tree.viewport = parent end
      remove(parent, node)
      for k, v in pairs(tree.framings) do if v == node.id then tree.framings[k] = nil end end
      node = parent
    elseif #node.children == 1 then
      local only = node.children[1]
      remove(node, only)
      replace_with(node, only)
      if tree.viewport == node then tree.viewport = only end
      for k, v in pairs(tree.framings) do if v == node.id then tree.framings[k] = only.id end end
      node = parent
    else
      break
    end
  end
end

-- Put `node` inside a new container of `kind` occupying node's old slot.
local function wrap(tree, node, kind)
  local container = T.node(tree, kind)
  if node == tree.root then
    for _, child in ipairs({ table.unpack(tree.root.children) }) do
      remove(tree.root, child)
      add(container, child)
    end
    add(tree.root, container)
    return container
  end
  replace_with(node, container)
  node.weight = 1.0
  add(container, node)
  return container
end

local function detach(tree, node)
  local parent = node.parent
  if not parent then return end
  remove(parent, node)
  local f = focused_node(tree)
  local lost_focus = f ~= nil and contains(node, f)
  if contains(node, tree.viewport) then tree.viewport = parent end
  local dead = {}
  walk(node, function(n) dead[n.id] = true end)
  for k, v in pairs(tree.framings) do if dead[v] then tree.framings[k] = nil end end
  collapse(tree, parent)
  if lost_focus or f == nil then
    local fw = first_window(tree.viewport)
    tree.focused = fw and fw.address or nil
  end
end

-- A new window splits the focused tile along its larger dimension (dwindle
-- style): the focused leaf is wrapped in a row (wider) or column (taller) and
-- the newcomer takes the second half. Every insert therefore adds a level, so
-- the tree grows deep on its own. `area` is the work area used to measure the
-- focused tile; without it the split defaults to a row.
function T.add_window(tree, address, label, area)
  local existing = T.find_window(tree, address)
  if existing then
    if label and label ~= "" then existing.label = label end
    return existing
  end
  local leaf = T.node(tree, "window", { address = address, label = label or "" })
  local target = focused_in_view(tree)
  if not target or target.kind ~= "window" then
    if not is_container(tree.viewport) then
      target = tree.viewport -- zoomed into one window or the desktop: split that
    else
      local last = T.windows(tree.viewport)
      target = last[#last]
    end
  end
  if not target then
    -- Nothing visible to split: fall back to the viewport container (or root).
    local host = is_container(tree.viewport) and tree.viewport or tree.root
    add(host, leaf)
  else
    local kind = "row"
    if area then
      local b = target.kind == "window" and T.layout(tree, area)[target.address] or area
      if b and b.h > b.w then kind = "column" end
    end
    -- `split <kind>` forces the orientation of the next split once.
    if tree.next_split then
      kind = tree.next_split
      tree.next_split = nil
    end
    local parent = target.parent
    if parent == tree.root and #parent.children == 1 then
      -- First split on a workspace: reuse the root instead of nesting a row in a row.
      parent.kind = kind
      add(parent, leaf)
    else
      local container = wrap(tree, target, kind)
      add(container, leaf)
      if tree.viewport == target then tree.viewport = container end
    end
  end
  tree.focused = address
  return leaf
end

function T.remove_window(tree, address)
  local leaf = T.find_window(tree, address)
  if not leaf then return false end
  detach(tree, leaf)
  return true
end

function T.set_focus(tree, address)
  local leaf = T.find_window(tree, address)
  if not leaf then return false end
  tree.focused = address
  local n = leaf
  while n.parent do
    if n.parent.kind == "tabs" then n.parent.active = index_of(n.parent, n) end
    n = n.parent
  end
  return true
end

-- Make the tree match the set of live windows: { {address=, label=}, ... } in order.
function T.sync(tree, live, area)
  local present = {}
  for _, entry in ipairs(live) do present[entry.address] = true end
  for _, leaf in ipairs(T.windows(tree.root)) do
    if not present[leaf.address] then detach(tree, leaf) end
  end
  for _, entry in ipairs(live) do
    local leaf = T.find_window(tree, entry.address)
    if not leaf then leaf = T.add_window(tree, entry.address, entry.label, area) end
    if entry.title ~= nil then leaf.title = entry.title end
  end
end

-- ------------------------------------------------------- viewport (zoom) --

local function push_history(tree)
  tree.back[#tree.back + 1] = tree.viewport.id
  tree.forward = {}
  while #tree.back > HISTORY do table.remove(tree.back, 1) end
end

function T.zoom_to(tree, node, record)
  if node ~= tree.viewport then
    if record ~= false then push_history(tree) end
    tree.viewport = node
  end
  if not focused_in_view(tree) then
    local fw = first_window(node)
    tree.focused = fw and fw.address or tree.focused
  end
  return node
end

-- Zoom in on the focused window: it becomes the "top" window of the view. The
-- viewport moves to the highest node below the current one in which the focused
-- window is the first (top-left) leaf, so the view shows that window plus
-- everything that was split off from it. Zooming again from there shows the
-- window alone.
function T.zoom_in(tree)
  local vp = tree.viewport
  if not is_container(vp) or #vp.children == 0 then return nil end
  local f = focused_in_view(tree)
  if not f then
    f = first_window(vp)
    if not f then return nil end
  end
  local n = f
  while n.parent and n.parent ~= vp do
    local p = n.parent
    local top = (p.kind == "tabs") and active_child(p) or p.children[1]
    if top ~= n then break end
    n = p
  end
  return T.zoom_to(tree, n)
end

-- One level at a time: the child of the viewport that holds the focused window.
function T.zoom_step(tree)
  local vp = tree.viewport
  if not is_container(vp) or #vp.children == 0 then return nil end
  local f = focused_node(tree)
  local target
  for _, c in ipairs(vp.children) do
    if f and contains(c, f) then target = c break end
  end
  target = target or active_child(vp) or vp.children[1]
  return T.zoom_to(tree, target)
end

function T.zoom_out(tree)
  if not tree.viewport.parent then return nil end
  return T.zoom_to(tree, tree.viewport.parent)
end

function T.zoom_root(tree) return T.zoom_to(tree, tree.root) end

function T.zoom_desktop(tree)
  local d = T.desktop_node(tree)
  return d and T.zoom_to(tree, d) or nil
end

function T.back(tree)
  while #tree.back > 0 do
    local node = T.find(tree, table.remove(tree.back))
    if node then
      tree.forward[#tree.forward + 1] = tree.viewport.id
      return T.zoom_to(tree, node, false)
    end
  end
end

function T.forward(tree)
  while #tree.forward > 0 do
    local node = T.find(tree, table.remove(tree.forward))
    if node then
      tree.back[#tree.back + 1] = tree.viewport.id
      return T.zoom_to(tree, node, false)
    end
  end
end

function T.save_framing(tree, name, node)
  node = node or tree.viewport
  tree.framings[name] = node.id
  return node
end

function T.go_framing(tree, name)
  local id = tree.framings[name]
  local node = id and T.find(tree, id)
  if not node then
    tree.framings[name] = nil
    return nil
  end
  return T.zoom_to(tree, node)
end

-- ------------------------------------------------------- structure edits --

-- Force the orientation of the next split (i3 semantics): the next window opens
-- in a container of this kind next to the focused one.
function T.split(tree, kind)
  assert(T.CONTAINERS[kind], "bad container kind " .. tostring(kind))
  tree.next_split = kind
  return kind
end

-- Change the kind of the container around the focused leaf (or the viewport itself).
function T.set_layout(tree, kind)
  assert(T.CONTAINERS[kind], "bad container kind " .. tostring(kind))
  local target = focused_in_view(tree)
  local container = (target and target ~= tree.viewport) and target.parent or tree.viewport
  if not container or not is_container(container) then return nil end
  container.kind = kind
  if kind == "tabs" and target and target.parent == container then container.active = index_of(container, target) end
  return container
end

-- Move the focused leaf one step, i3-style:
-- 1. swap with the neighbouring sibling when the parent already runs that way;
-- 2. otherwise climb to the nearest ancestor inside the viewport that runs that
--    way and step out beside the branch we came from;
-- 3. otherwise wrap the viewport in a container running that way and move out.
function T.move(tree, direction)
  local leaf = focused_in_view(tree)
  if not leaf or leaf == tree.viewport or not leaf.parent then return false end
  local want = HORIZONTAL[direction] and "row" or "column"
  local forward = direction == "right" or direction == "down"
  local parent = leaf.parent
  local function runs(c) return c.kind == want or (c.kind == "tabs" and want == "row") end

  if runs(parent) then
    local idx = index_of(parent, leaf)
    local nidx = idx + (forward and 1 or -1)
    if nidx >= 1 and nidx <= #parent.children then
      parent.children[idx], parent.children[nidx] = parent.children[nidx], parent.children[idx]
      if parent.kind == "tabs" then parent.active = nidx end
      return true
    end
  end

  local branch = leaf
  while branch ~= tree.viewport and branch.parent do
    local anc = branch.parent
    if anc.kind == want and branch ~= leaf then
      local idx = index_of(anc, branch)
      remove(parent, leaf)
      add(anc, leaf, forward and idx + 1 or idx)
      collapse(tree, parent)
      return true
    end
    branch = anc
  end

  local vp = tree.viewport
  if vp.kind == want and parent == vp then return false end
  if vp == tree.root and tree.root.kind == want then
    remove(parent, leaf)
    add(tree.root, leaf, forward and (#tree.root.children + 1) or 1)
    collapse(tree, parent)
    return true
  end
  remove(parent, leaf)
  local container = wrap(tree, vp, want)
  if vp ~= tree.root then tree.viewport = container end
  add(container, leaf, forward and (#container.children + 1) or 1)
  collapse(tree, parent)
  return true
end

function T.tab_cycle(tree, delta)
  local start = focused_in_view(tree) or tree.viewport
  local n = start
  local tabs
  while n do
    if n.kind == "tabs" and contains(tree.viewport, n) then tabs = n break end
    n = n.parent
  end
  if not tabs or #tabs.children == 0 then return nil end
  tabs.active = ((tabs.active - 1 + delta) % #tabs.children) + 1
  local child = tabs.children[tabs.active]
  local fw = first_window(child)
  if fw then tree.focused = fw.address end
  return child
end

function T.resize(tree, factor)
  local leaf = focused_in_view(tree)
  if not leaf or leaf == tree.viewport then return nil end
  leaf.weight = math.min(MAX_WEIGHT, math.max(MIN_WEIGHT, leaf.weight * factor))
  return leaf
end

-- ---------------------------------------------------------------- layout --

-- Returns { [address] = {x=,y=,w=,h=} } for the windows visible in the viewport.
-- Boxes are raw tile boxes (no gaps): the caller hands them to target:place(),
-- which applies gaps and borders the way the built-in layouts do.
function T.layout(tree, area)
  local boxes = {}
  local function place(node, b)
    if node.kind == "window" and node.address then
      boxes[node.address] = { x = b.x, y = b.y, w = b.w, h = b.h }
      return
    end
    if not is_container(node) or #node.children == 0 then return end
    if node.kind == "tabs" then
      local c = active_child(node)
      if c then place(c, b) end
      return
    end
    local total = 0
    for _, c in ipairs(node.children) do total = total + c.weight end
    local offset = 0
    for _, c in ipairs(node.children) do
      local share = c.weight / total
      if node.kind == "row" then
        place(c, { x = b.x + offset * b.w, y = b.y, w = share * b.w, h = b.h })
      else
        place(c, { x = b.x, y = b.y + offset * b.h, w = b.w, h = share * b.h })
      end
      offset = offset + share
    end
  end
  place(tree.viewport, { x = area.x, y = area.y, w = area.w, h = area.h })
  return boxes
end

-- ----------------------------------------------------------- persistence --

local function ser_node(n, out)
  out[#out + 1] = string.format("{kind=%q,id=%q,weight=%s", n.kind, n.id, tostring(n.weight))
  if n.kind == "window" then
    out[#out + 1] = string.format(",address=%q,label=%q", n.address or "", n.label or "")
  end
  if is_container(n) then
    out[#out + 1] = string.format(",active=%d,children={", n.active or 1)
    for _, c in ipairs(n.children) do
      ser_node(c, out)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  end
  out[#out + 1] = "}"
end

local function ser_list(list)
  local parts = {}
  for _, v in ipairs(list) do parts[#parts + 1] = string.format("%q", v) end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function ser_map(map)
  local parts = {}
  for k, v in pairs(map) do parts[#parts + 1] = string.format("[%q]=%q", k, v) end
  table.sort(parts)
  return "{" .. table.concat(parts, ",") .. "}"
end

function T.serialize(tree)
  local out = { "return {root=" }
  ser_node(tree.root, out)
  out[#out + 1] = string.format(",viewport=%q,focused=%s,back=%s,forward=%s,framings=%s}",
    tree.viewport.id,
    tree.focused and string.format("%q", tree.focused) or "nil",
    ser_list(tree.back), ser_list(tree.forward), ser_map(tree.framings))
  return table.concat(out)
end

local function link_parents(n)
  n.children = n.children or {}
  n.active = n.active or 1
  n.weight = n.weight or 1.0
  for _, c in ipairs(n.children) do
    c.parent = n
    link_parents(c)
  end
end

function T.deserialize(text)
  local fn, err = load(text, "fractal-state", "t", {})
  if not fn then return nil, err end
  local ok, d = pcall(fn)
  if not ok or type(d) ~= "table" or type(d.root) ~= "table" then return nil, "bad state" end
  local tree = { root = d.root, back = d.back or {}, forward = d.forward or {}, framings = d.framings or {}, focused = d.focused }
  link_parents(tree.root)
  tree.viewport = (d.viewport and T.find(tree, d.viewport)) or tree.root
  if tree.focused and not T.find_window(tree, tree.focused) then tree.focused = nil end
  return tree
end

-- --------------------------------------------------------------- display --

function T.path(tree, node)
  node = node or tree.viewport
  local out = {}
  local n = node
  while n do
    table.insert(out, 1, n)
    n = n.parent
  end
  return out
end

function T.render(tree)
  local lines = {}
  local names = {}
  for k, v in pairs(tree.framings) do names[v] = k end
  local f = focused_node(tree)
  local function rec(node, depth)
    local marks = ""
    if node == tree.viewport then marks = marks .. " <== viewport" end
    if node == f then marks = marks .. " (focused)" end
    if names[node.id] then marks = marks .. " [framing: " .. names[node.id] .. "]" end
    local extra = ""
    if node.kind == "tabs" then extra = " active=" .. tostring(node.active) end
    if node.weight ~= 1.0 then extra = extra .. string.format(" w=%.2f", node.weight) end
    lines[#lines + 1] = string.rep("  ", depth) .. node.id .. " " .. T.name(node) .. extra .. marks
    for _, c in ipairs(node.children) do rec(c, depth + 1) end
  end
  rec(tree.root, 0)
  return table.concat(lines, "\n")
end

-- Minimal JSON for the status file read by CLIs / a future shell widget.
local function json_str(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    return string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function json_node(n, tree, f, names)
  local parts = {
    '"id":' .. json_str(n.id),
    '"kind":' .. json_str(n.kind),
    '"name":' .. json_str(T.name(n)),
    '"weight":' .. string.format("%.3f", n.weight),
    '"viewport":' .. tostring(n == tree.viewport),
    '"focused":' .. tostring(n == f),
  }
  if n.address then parts[#parts + 1] = '"address":' .. json_str(n.address) end
  if n.title then parts[#parts + 1] = '"title":' .. json_str(n.title) end
  if names[n.id] then parts[#parts + 1] = '"framing":' .. json_str(names[n.id]) end
  if is_container(n) then
    if n.kind == "tabs" then parts[#parts + 1] = '"active":' .. tostring(n.active) end
    local kids = {}
    for _, c in ipairs(n.children) do kids[#kids + 1] = json_node(c, tree, f, names) end
    parts[#parts + 1] = '"children":[' .. table.concat(kids, ",") .. "]"
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function T.to_json(tree, extra)
  local names = {}
  for k, v in pairs(tree.framings) do names[v] = k end
  local f = focused_node(tree)
  local path = {}
  for _, n in ipairs(T.path(tree)) do path[#path + 1] = '{"id":' .. json_str(n.id) .. ',"name":' .. json_str(T.name(n)) .. "}" end
  local framings = {}
  local keys = {}
  for k in pairs(tree.framings) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do framings[#framings + 1] = '{"name":' .. json_str(k) .. ',"id":' .. json_str(tree.framings[k]) .. "}" end
  local parts = {
    '"viewport":' .. json_str(tree.viewport.id),
    '"path":[' .. table.concat(path, ",") .. "]",
    '"framings":[' .. table.concat(framings, ",") .. "]",
    '"canBack":' .. tostring(#tree.back > 0),
    '"canForward":' .. tostring(#tree.forward > 0),
    '"tree":' .. json_node(tree.root, tree, f, names),
  }
  for k, v in pairs(extra or {}) do
    parts[#parts + 1] = json_str(k) .. ":" .. (type(v) == "number" and tostring(v) or json_str(v))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

return T
