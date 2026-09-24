# fractal-wm — usage

A zoomable window tree for Hyprland 0.56+ on Omarchy, written against Hyprland's Lua custom-layout API
(`hl.layout.register`). No compositor plugin, no daemon: the whole engine runs inside Hyprland's config VM as
the layout `lua:fractal`, so windows stay tiled, animations are Hyprland's own, and every Omarchy update that
keeps the Lua API keeps this working.

## Files

| Path | Role |
|---|---|
| `lua/fractal_tree.lua` | pure tree model: nodes, viewport, zoom, history, framings, layout math, persistence (tested with `lua tests/test_tree.lua`) |
| `lua/fractal.lua` | Hyprland glue: registers the layout, syncs the tree with live windows, parks hidden windows offscreen, handles commands, saves state |
| `lua/fractal_keys.lua` | example bindings; **copied** to `~/.config/hypr/fractal_keys.lua` (edit that copy) |
| `bin/fractal` | CLI; symlinked to `~/.local/bin/fractal` |
| `tests/test_tree.lua`, `tests/test_glue.lua` | 26 offline tests, run with the system `lua` (5.5) |
| `reference/python/` | the Python model + unittest suite the Lua port was checked against; not used at runtime |

State: `~/.local/state/fractal-wm/` (`ws-<id>.lua` per workspace, `enabled.txt`, `fractal.log`);
live status: `$XDG_RUNTIME_DIR/fractal-wm/ws-<id>.txt|.json`, `last-reply.txt`.

## Notifications

Replies to commands (the viewport path after a zoom, "split column", ...) are written to
`$XDG_RUNTIME_DIR/fractal-wm/last-reply.txt` and printed by the `fractal` CLI. They are **not** shown as desktop
notifications unless you pass `notify = true` to `setup()` in your `fractal_keys.lua`. `fractal show`
(Super+Ctrl+Y) always uses a notification, on demand.

## Turning it on

```
fractal on        # this workspace uses lua:fractal (persists across reloads via enabled.txt)
fractal off       # back to dwindle
fractal toggle    # SUPER + CTRL + U
fractal tree      # the tree with <== viewport, (focused), [framing: name]
fractal show      # same, as a notification (SUPER + CTRL + Y)
```

## Model

Every tiled window on the workspace is a leaf; containers are `row`, `column` or `tabs`. A new window
**splits the focused tile along its larger dimension** (dwindle style): a wide tile becomes a row with the
newcomer on the right, a tall one a column with the newcomer below. Every insert adds a level, so the tree grows
deep by itself: `a | (b / (c | (d / e)))`.

A **view** is the viewport plus, optionally, a **selection**: the set of tiles that are visible. Without a selection
every tile under the viewport shows. With one, the other tiles are parked and their space goes to their visible
siblings, so `a | (x / (t | f))` with the selection {a, x} shows a and x side by side, x taking the whole right half.
Zooming clears the selection; framings remember it; new windows and newly focused windows join it.

The **viewport** is the node that fills the work area. **Zoom-in makes the focused window the top window**: the
viewport moves to the largest subtree in which that window is the first leaf, i.e. the window plus everything
that was split off from it; zooming again shows the window alone. Zoom-out climbs to the parent. Windows
outside the viewport are parked in the monitor's top-left corner, one pixel inside and fully transparent (tag
`fractal-parked` + an opacity rule): Hyprland only renders windows that touch a monitor, and the map's thumbnails need
them rendered. Hyprland has no per-window hide from Lua. Focusing a
parked window (alt-tab, urgent) pulls the viewport back to the nearest node that shows it.

## Commands

Any of these works as `fractal <cmd>`, as `hyprctl dispatch 'hl.dsp.layout("<cmd>")'`, or bound with
`hl.dsp.layout("<cmd>")`. They act on the active workspace's layout.

| Command | Effect | Default key |
|---|---|---|
| `zoom-in` | focused window becomes the top of the view (its subtree fills the screen) | SUPER+CTRL+DOWN, SUPER+CTRL+scroll down, 3-finger pinch out |
| `zoom-step` | one level only: the viewport's child holding the focused window | |
| `zoom-out` | viewport ← parent | SUPER+CTRL+UP, SUPER+CTRL+scroll up, 3-finger pinch in |
| `zoom-root` | overview | SUPER+CTRL+SHIFT+UP |
| `zoom-desktop` | the wallpaper leaf (only after `desktop on`) | SUPER+CTRL+SHIFT+DOWN |
| `zoom <id\|address>` | jump to a node from `fractal tree` | |
| `show <id> <id>...` | view exactly these tiles: viewport = their common ancestor, everything else under it hidden and its space given to the shown tiles | Fractal Map: shift-click or drag, then ⏎ |
| `hide [id]` | drop one tile (default: the focused one) from the current view | SUPER+CTRL+J |
| `unhide <id>` | bring a hidden tile back into the view | focus it (alt-tab) or click it in the map |
| `show-all` | clear the selection | SUPER+CTRL+SHIFT+J |
| `hidden` | list hidden tiles | |
| `back` / `forward` | viewport history (selections included) | SUPER+CTRL+SHIFT+LEFT / RIGHT |
| `frame-save <name>` / `frame <name>` / `frame-delete <name>` / `frames` | bookmarks to nodes | SUPER+CTRL+SHIFT+1..9 save, SUPER+CTRL+1..9 go |
| `split row\|column\|tabs` | wrap the focused window; the next window opens inside | SUPER+CTRL+SHIFT+H / V / T |
| `layout row\|column\|tabs\|next` | change the container around the focused window | SUPER+CTRL+SHIFT+L (next) |
| `move left\|right\|up\|down` | i3-style move | SUPER+CTRL+ALT+arrows |
| `tab next\|prev` | cycle a tabs container | SUPER+CTRL+G / SUPER+CTRL+ALT+G |
| `grow` / `shrink` | ±15 % share | SUPER+CTRL+EQUAL / MINUS |
| `desktop on\|off` | add/remove the wallpaper leaf at the root | |
| `reset` | rebuild the tree from the live windows | |
| `tree` / `status` / `help` | text | |

Framings and the tree survive `hyprctl reload` and daemon-free restarts of the module; they do not survive a
Hyprland restart (window addresses change), the tree is rebuilt from whatever windows exist.

## Known limits (Phase 0)

- No tab bar: `tabs` containers show only the active window; cycle with `tab next`.
- Hidden windows are parked transparent in a corner, not unmapped. `hl.dsp.focus({direction=...})` can reach them;
  the viewport then pulls back (or the selection grows) to show them, which is the intended fallback.
- No mouse docking / drag to a side yet. `move` and `split` are the keyboard substitutes.
- Zoom is a geometry change animated by Hyprland, not a camera zoom. A live-thumbnail map (layer B) would be a
  Quickshell plugin reading `$XDG_RUNTIME_DIR/fractal-wm/ws-<id>.json`.
- One tree per workspace, one workspace per monitor at a time; nothing multi-monitor specific has been tested.

## Development

```
lua tests/test_tree.lua && TMPDIR=/tmp lua tests/test_glue.lua
hyprctl reload && hyprctl configerrors      # picks up lua/ changes (module is hot-swapped behind one registration)
fractal log                                 # engine errors, if any
```

Hyprland refuses to register a layout name twice and Omarchy reloads keep the Lua VM, so `fractal.lua` registers
once and swaps the implementation table behind the registration on every reload.
