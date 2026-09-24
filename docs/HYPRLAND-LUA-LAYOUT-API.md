# Notes on Hyprland's Lua custom-layout API (0.56.2)

What the wiki did not say and the probes did. Useful for anyone writing a layout with `hl.layout.register`.

- the layout is referenced as `lua:<name>`; `hl.workspace_rule({ workspace = "9", layout = "lua:fractal" })`;
- `ctx.area` is the work area minus reserved bar and gaps_out; `target:place(box)` applies gaps_in/borders
  itself; unplaced targets keep stale geometry, so hidden windows must be placed (offscreen) explicitly;
- `HL.Window.hidden` is read-only; `hl.layout.register` refuses a duplicate name and Omarchy reloads keep the VM,
  so register once and hot-swap; a string returned from `layout_msg` reaches `hyprctl` as an *error*, so replies
  go through a file; `hyprctl repl '<lua>'` prints values, `hyprctl eval` does not; numbers arrive as floats
  (`9.0`), normalise before using them as keys or file names; `hl.dsp.focus({ window = hl.get_window("address:0x…") })`
  works, the bare selector string did not.

Probing tips: `hyprctl repl '<lua>'` prints a return value, `hyprctl eval` only says `ok`; `/usr/share/hypr/stubs/hl.meta.lua`
lists every `hl.*` field with types (but not argument shapes); `HL.Window.hidden` is read-only.

Rendering and capture: Hyprland renders a window (and lets `hyprland-toplevel-export`, i.e. Quickshell's
`ScreencopyView`, capture it) only while its box intersects its monitor; windows on an *inactive* workspace still
render, windows placed fully off-screen do not. To hide a window and keep it capturable, park it overlapping the
monitor by a few pixels and make it transparent with a tag + `hl.window_rule({ match = { tag = "…" }, opacity = "0 0 0" })`;
tag with `hl.dsp.window.tag({ tag = "+name", window = win })`. `target:set_box()` still shaves about 5 px per side, and
terminals snap to cell sizes, so leave a 12 px margin. `hyprctl setprop` is gone in the Lua era ("unknown request").
