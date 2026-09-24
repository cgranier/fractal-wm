# fractal-wm

A zoomable window tree for [Hyprland](https://hypr.land) 0.56+, written as a Lua custom layout. Built for
[Omarchy](https://omarchy.org) 4, works anywhere Hyprland's Lua config does.

Every window on a workspace is a leaf in one tree. A new window splits the focused tile along its larger dimension,
dwindle style, so the tree grows deep on its own. The twist: the part of the tree that fills your screen, the
**viewport**, is not welded to the root. Zoom in and the focused window becomes the top of the view, with everything
that was split off from it; zoom in again and it fills the screen alone. Zoom out and the parent comes back. Save a
view as a named framing and jump to it later. The screen becomes a camera over a tree that can grow as deep as you
like.

The idea comes from Dan Fessler's 2026 post *"What happens when you make your Operating System fractal?"*, itself
inspired by Scott Jenson's talk *"Are we really going to use the same Desktop UX forever?"*. Background and the
original feasibility assessment: [docs/CONCEPT.md](docs/CONCEPT.md).

```
 viewport = root                       zoom in on B                    zoom in again
 ┌──────────┬───────────┐              ┌───────────────────────┐        ┌───────────────────────┐
 │          │     B     │              │           B           │        │                       │
 │    A     ├─────┬─────┤     ──►      ├───────────┬───────────┤   ──►  │           B           │
 │          │  C  │  D  │              │     C     │     D     │        │                       │
 └──────────┴─────┴─────┘              └───────────┴───────────┘        └───────────────────────┘
```

## Status

Early, usable prototype (September 2026). It runs daily on one machine. Expect rough edges and no tab bar.
Roadmap, in order: selecting which tiles a view shows, then a live-thumbnail map with breadcrumb chips as an
Omarchy shell widget. See [USAGE.md](USAGE.md) for the full command list and known limits.

## Requirements

- Hyprland 0.56 or newer with the Lua configuration (`hl.layout.register` must exist).
- For the `fractal` command-line tool: `bash`, `jq`, and `notify-send` (libnotify). Omarchy ships all three.
- Optional: [hyprgrass](https://github.com/horriblename/hyprgrass) for pinch-to-zoom on touchscreens.
- For the tests only: a `lua` 5.4 or 5.5 interpreter.

## Install (manual, for now)

```bash
git clone https://github.com/cgranier/fractal-wm.git ~/fractal-wm
cd ~/fractal-wm

# 1. the engine: two Lua modules the Hyprland config can require
ln -s "$PWD/lua/fractal.lua"       ~/.config/hypr/fractal.lua
ln -s "$PWD/lua/fractal_tree.lua"  ~/.config/hypr/fractal_tree.lua

# 2. your bindings: a copy you own and edit
cp lua/fractal_keys.lua ~/.config/hypr/fractal_keys.lua

# 3. the command-line tool
mkdir -p ~/.local/bin && ln -s "$PWD/bin/fractal" ~/.local/bin/fractal
```

Then add one line to `~/.config/hypr/hyprland.lua` (on Omarchy, after the other `require("hypr.…")` lines):

```lua
require("hypr.fractal_keys")
```

On plain Hyprland, make sure `~/.config` is on the Lua module path first, or require the files by path:

```lua
package.path = os.getenv("HOME") .. "/.config/?.lua;" .. package.path
require("hypr.fractal_keys")
```

Reload and check:

```bash
hyprctl reload && hyprctl configerrors     # should print nothing
fractal on                                  # this workspace now uses lua:fractal
```

Nothing changes on a workspace until you run `fractal on` there (or press Super+Ctrl+U). `fractal off` returns it to
dwindle. Uninstall: remove the `require` line, the three links and the copied file, and `~/.local/state/fractal-wm`.

## Keys (defaults in `fractal_keys.lua`)

| Key | Action |
|---|---|
| Super+Ctrl+Down / Up, Super+Ctrl+scroll | zoom in / zoom out |
| Super+Ctrl+Shift+Up | overview (root) |
| Super+Ctrl+Shift+Left / Right | back / forward through views |
| Super+Ctrl+Shift+1..9, Super+Ctrl+1..9 | save framing / jump to framing |
| Super+Ctrl+Alt+arrows | move the focused window in the tree |
| Super+Ctrl+Shift+H / V / T | force the next split to be a row / column / tabs |
| Super+Ctrl+Shift+L | cycle the container kind around the focused window |
| Super+Ctrl+G, Super+Ctrl+Alt+G | next / previous tab |
| Super+Ctrl+Equal / Minus | grow / shrink |
| Super+Ctrl+U | toggle the layout on this workspace |
| Super+Ctrl+Y | Fractal Map overlay (Omarchy shell), else the tree as a notification |
| three-finger pinch (hyprgrass) | zoom out / in |

The chord is Super+Ctrl because Omarchy uses Super+Alt for window groups. Change what you like in your copy.

## Fractal Map (Omarchy shell plugin)

[omarchy-fractal-map](https://github.com/cgranier/omarchy-fractal-map) draws the tree as a clickable map: click a window
or a container to zoom the viewport there, right-click for its parent, breadcrumb and saved framings on top. Install
with `omarchy plugin add https://github.com/cgranier/omarchy-fractal-map.git --enable`; the default bindings open it on
Super+Ctrl+Y when the Omarchy shell is present. It reads the JSON status this layout writes, so it needs nothing else.

## How it works

`lua/fractal_tree.lua` is the pure model: nodes, viewport, zoom, history, framings, layout math, serialization. It has
no Hyprland calls and is tested with plain Lua. `lua/fractal.lua` registers the layout with `hl.layout.register`,
syncs the tree with the workspace's tiled windows on every recalculation, computes boxes for the viewport's subtree and
parks everything else offscreen (Hyprland has no per-window hide from Lua). Commands travel through the
layout-message dispatcher, `hl.dsp.layout("zoom-in")`, so keys, `hyprctl dispatch` and the `fractal` tool all use the
same path. State is saved per workspace under `$XDG_STATE_HOME/fractal-wm` and a rendered status under
`$XDG_RUNTIME_DIR/fractal-wm` for tools and widgets. Notes on the API itself, including the traps:
[docs/HYPRLAND-LUA-LAYOUT-API.md](docs/HYPRLAND-LUA-LAYOUT-API.md).

## Development

```bash
lua tests/test_tree.lua && TMPDIR=/tmp lua tests/test_glue.lua   # 29 tests, no Hyprland needed
hyprctl reload && hyprctl configerrors                            # live: the module hot-swaps behind one registration
fractal log                                                       # engine errors, if any
```

`reference/python/` holds the Python model the Lua port was checked against. It is not used at runtime.

## License

MIT, see [LICENSE](LICENSE).
