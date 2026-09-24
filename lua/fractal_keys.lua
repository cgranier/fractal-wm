-- fractal_keys.lua — load the fractal layout and bind it. Personal config;
-- copied (not symlinked) to ~/.config/hypr/fractal_keys.lua so you can edit it.
--
-- Everything sits on SUPER + CTRL because Omarchy already uses SUPER + ALT for
-- window groups. Check collisions with: omarchy menu keybindings --print (or hyprctl binds)
--
--   SUPER + CTRL + DOWN / UP            zoom in / zoom out (also SUPER + CTRL + scroll)
--   SUPER + CTRL + SHIFT + UP / DOWN    overview (root) / desktop node
--   SUPER + CTRL + SHIFT + LEFT / RIGHT back / forward through viewports
--   SUPER + CTRL + ALT + arrows         move the focused window in the tree
--   SUPER + CTRL + SHIFT + H / V / T    split: next window opens in a row / column / tabs
--   SUPER + CTRL + SHIFT + L            cycle the container kind around the focused window
--   SUPER + CTRL + G  /  + ALT + G      next / previous tab
--   SUPER + CTRL + J  /  + SHIFT + J     hide the focused tile from the view / show all again
--   SUPER + CTRL + EQUAL / MINUS        grow / shrink the focused window's share
--   SUPER + CTRL + 1..9                 jump to saved framing 1..9
--   SUPER + CTRL + SHIFT + 1..9         save the current view as framing 1..9
--   SUPER + CTRL + U                    toggle the fractal layout on this workspace
--   SUPER + CTRL + Y                    Fractal Map overlay (Omarchy) / tree as a notification
--   3-finger pinch (hyprgrass)          zoom out (pinch in) / zoom in (pinch out)

local fractal = require("hypr.fractal").setup({
  name = "fractal",   -- workspaces use it as layout = "lua:fractal"
  desktop = false,    -- Omarchy has no desktop icons; `fractal desktop on` adds the wallpaper leaf
  notify = false,     -- true: one-line replies (viewport path etc.) pop up as notifications
})

local function cmd(msg) return hl.dsp.layout(msg) end

-- Omarchy's o.bind registers the description for its keybinding menu; plain
-- Hyprland only has hl.bind, so fall back to it when `o` is not around.
local bind = (o and o.bind) and function(keys, description, dispatcher)
  o.bind(keys, description, dispatcher)
end or function(keys, description, dispatcher)
  if type(dispatcher) == "string" then dispatcher = hl.dsp.exec_cmd(dispatcher) end
  hl.bind(keys, dispatcher, { description = description })
end

bind("SUPER + CTRL + DOWN", "Fractal: zoom in", cmd("zoom-in"))
bind("SUPER + CTRL + UP", "Fractal: zoom out", cmd("zoom-out"))
bind("SUPER + CTRL + mouse_down", "Fractal: zoom in", cmd("zoom-in"))
bind("SUPER + CTRL + mouse_up", "Fractal: zoom out", cmd("zoom-out"))
bind("SUPER + CTRL + SHIFT + UP", "Fractal: overview", cmd("zoom-root"))
bind("SUPER + CTRL + SHIFT + DOWN", "Fractal: desktop", cmd("zoom-desktop"))
bind("SUPER + CTRL + SHIFT + LEFT", "Fractal: back", cmd("back"))
bind("SUPER + CTRL + SHIFT + RIGHT", "Fractal: forward", cmd("forward"))

bind("SUPER + CTRL + ALT + LEFT", "Fractal: move window left", cmd("move left"))
bind("SUPER + CTRL + ALT + RIGHT", "Fractal: move window right", cmd("move right"))
bind("SUPER + CTRL + ALT + UP", "Fractal: move window up", cmd("move up"))
bind("SUPER + CTRL + ALT + DOWN", "Fractal: move window down", cmd("move down"))

bind("SUPER + CTRL + SHIFT + H", "Fractal: split row", cmd("split row"))
bind("SUPER + CTRL + SHIFT + V", "Fractal: split column", cmd("split column"))
bind("SUPER + CTRL + SHIFT + T", "Fractal: split tabs", cmd("split tabs"))
bind("SUPER + CTRL + SHIFT + L", "Fractal: cycle container kind", cmd("layout next"))
bind("SUPER + CTRL + G", "Fractal: next tab", cmd("tab next"))
bind("SUPER + CTRL + ALT + G", "Fractal: previous tab", cmd("tab prev"))
bind("SUPER + CTRL + J", "Fractal: hide this tile from the view", cmd("hide"))
bind("SUPER + CTRL + SHIFT + J", "Fractal: show all tiles again", cmd("show-all"))
bind("SUPER + CTRL + EQUAL", "Fractal: grow window", cmd("grow"))
bind("SUPER + CTRL + MINUS", "Fractal: shrink window", cmd("shrink"))

for i = 1, 9 do
  bind("SUPER + CTRL + " .. i, "Fractal: framing " .. i, cmd("frame " .. i))
  bind("SUPER + CTRL + SHIFT + " .. i, "Fractal: save framing " .. i, cmd("frame-save " .. i))
end

bind("SUPER + CTRL + U", "Fractal: toggle layout on workspace", "fractal toggle")
-- With the Omarchy shell, SUPER + CTRL + Y opens the Fractal Map overlay (cgranier.fractalmap);
-- elsewhere it shows the tree as a notification.
if o and o.bind then
  bind("SUPER + CTRL + Y", "Fractal: map", "omarchy-shell shell toggle cgranier.fractalmap '{}'")
else
  bind("SUPER + CTRL + Y", "Fractal: show tree", "fractal show")
end

if hl.plugin.hyprgrass then
  local hg = hl.plugin.hyprgrass
  hg.bind({ pattern = { kind = "pinch", fingers = 3, direction = "pinchin" }, action = cmd("zoom-out") })
  hg.bind({ pattern = { kind = "pinch", fingers = 3, direction = "pinchout" }, action = cmd("zoom-in") })
end

return fractal
