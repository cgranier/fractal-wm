# Fractal Map (Omarchy shell overlay)

A clickable map of the fractal-wm window tree for the workspace you are on. It ships in this repository: the
`manifest.json`, `Map.qml` and `Model.js` at the root make the whole repo an Omarchy shell plugin with the id
`cgranier.fractalmap`.

fractal-wm turns a Hyprland workspace into one tree of windows with a movable viewport. This plugin draws that tree
as nested rectangles, the overview in miniature, with the current viewport outlined and the focused window
highlighted. Click a window or a container and the viewport zooms there. The breadcrumb on top walks back up,
the chips on the right jump to saved framings.

## Requires

- Omarchy 4 with the Quattro shell (Quickshell).
- The fractal layout installed and switched on for the workspace (`fractal on`). Without it the overlay says so and
  offers a one-click switch.

## Install

```bash
omarchy plugin add https://github.com/cgranier/fractal-wm.git --enable
```

That clones the repository to `~/.config/omarchy/plugins/cgranier.fractalmap/`, so the Lua layout and the `fractal`
CLI are on disk too; the README's install steps can point their symlinks there.

Open it from a keybinding or the menu:

```lua
-- ~/.config/hypr/bindings.lua (or fractal_keys.lua)
o.bind("SUPER + CTRL + Y", "Fractal map", "omarchy-shell shell toggle cgranier.fractalmap '{}'")
```

```jsonc
// ~/.config/omarchy/extensions/omarchy-menu.jsonc
"window.fractalmap": {"icon":"󰕰","label":"Fractal Map","description":"Zoomable map of this workspace's window tree","action":"omarchy-shell shell toggle cgranier.fractalmap '{}'","aliases":["fractal","map"]},
```

## Use

Each tile shows a live thumbnail of its window (press T to toggle them) with the app name and title on top.

| Input | Effect |
|---|---|
| click a window or container, or ⏎ on the cursor | zoom the viewport there, close the map |
| arrows | move the cursor from tile to tile (the pointer moves it too) |
| space, shift-click, or drag a rectangle | select tiles; the Show button or ⏎ shows exactly those, from whatever branches |
| click while a selection exists | add or remove that tile |
| right-click | zoom to its parent |
| ⌫ / Delete | hide the cursor tile from the current view |
| Ctrl+A | select every tile |
| breadcrumb chip | zoom to that ancestor |
| ⌖ chip | jump to a saved framing; "show all" chip clears the workspace's selection |
| shift+↑ / shift+↓, − / = | zoom out / in (the map stays open and follows) |
| shift+← / shift+→ | back / forward through views |
| Home | overview |
| 1–9 | saved framing 1–9 |
| Esc | clear the selection, then close; click outside closes |

`omarchy-shell shell toggle cgranier.fractalmap '{"workspace": 3}'` opens the map for another workspace.

## How it works

The layout writes `$XDG_RUNTIME_DIR/fractal-wm/ws-<id>.json` on every change. The overlay reads it (and watches it
while open), checks the windows still exist with `hyprctl clients`, lays the tree out by weight in the monitor's
aspect ratio, and sends picks through `hyprctl dispatch 'hl.dsp.layout("zoom <id>")'`, the same path the
keybindings use. It runs no shell commands other than `hyprctl`. Thumbnails are live captures of each window through
Hyprland's toplevel export (Quickshell `ScreencopyView`), only for tiles large enough to show them, and only while
the map is open. The IPC target `cgranier.fractalmap` also exposes test hooks (`press`, `move`, `release`, `key`,
`apply`, `selection`, `rects`, `debug`) used to drive the overlay without a pointer.

`Model.js` is the pure part (parsing, pruning, layout); `node --test tests/model.test.js` covers it.

## Uninstall

```bash
omarchy plugin remove cgranier.fractalmap
```

Remove the keybinding and menu entry you added. The overlay writes nothing outside the plugin folder. If the layout's
symlinks point into the plugin folder, re-point or remove them too.
