# The concept, and how it was assessed

Written 2026-09-23 after watching Dan Fessler's post *"What happens when you make your Operating System fractal?"*
(X, 2026-09-22; a React prototype built on his [react-dockable](https://github.com/DanFessler/react-dockable) library,
itself inspired by Scott Jenson's talk *"Are we really going to use the same Desktop UX forever?"*). Kept here as the
design rationale for fractal-wm.

## 1. The concept

**Everything on the desktop is one tree.** Leaves are windows. Interior nodes are containers with a split direction
(row, column) or tabs. The wallpaper "desktop" is itself a leaf in the tree. This part is ordinary hierarchical
tiling (i3/sway, hy3, react-dockable): drag a window to an edge to insert a new row/column, drag across the whole
top/bottom to span, change a container's split direction, pull a window out to float, dock it back in.

**The twist: the viewport is a node, not the screen.** In every tiler today the root node is welded to the monitor;
as you add windows the leaves shrink. Dan unwelds it: *any* node can be the one that fills the monitor. Zoom in =
make a child the viewport. Zoom out = make the parent the viewport. The layout rule is identical at every depth, so
each level looks and acts like a full desktop; that self-similarity is the "fractal". Depth is unbounded because
only the current viewport's subtree has to be legible. The screen becomes a camera over an infinite canvas.

**Navigation seen in the video**

- Double-click a title → that node fills the screen. Double-click the desktop → desktop node. Double-click again → root ("Overview").
- Scroll wheel over the bar steps one level up/down the ancestor chain: Work ↔ Desktop is one notch, Music one more.
- Pinch on touch zooms continuously and snaps to the nearest node's bounds.
- Back / forward buttons keep a browser-like history of viewports.
- "Save framing" bookmarks a node as a named chip in the bottom bar: `Overview | Desktop | Saved Frame | + | ‹ › | 3 spaces`.
- Level of detail: a window that would be rendered too small collapses to its app icon.
- Bottom-right "Map" button: an overview of the whole tree.

**Versus workspaces.** Workspaces are a flat list of siblings that you switch between blind. Here a "workspace" is
any subtree, and context is one zoom-out away instead of a switch.

### Diagram

```
 THE TREE (one per screen)                     WHAT THE MONITOR SHOWS

 Root ─┬─ Desktop (wallpaper)                  viewport = Root  ("Overview")
       ├─ Row A ─┬─ Projects                   ┌──────────┬───────────┬─────────┐
       │         ├─ Column B ─┬─ Notes         │ Projects │ Notes     │ Studio  │
       │         │            └─ Reference     │          ├───────────┤         │
       │         └─ Studio                     │          │ Reference │         │
       └─ Row C ─┬─ Inbox                      ├──────────┴───────────┴─────────┤
                 └─ Column D ─┬─ Calendar      │ Inbox      │ [cal] [pics] icons │
                              └─ Photos        └────────────┴────────────────────┘

   zoom in: double-click "Row C" / scroll one notch / pinch
                                               viewport = Row C
   Row C now fills the monitor. Row A and     ┌─────────────────────────────────┐
   the Desktop still exist in the tree,        │ Inbox                           │
   they are just outside the camera.           ├────────────────┬────────────────┤
                                               │ Calendar       │ Photos         │
                                               └────────────────┴────────────────┘
   zoom in again
                                               viewport = Column D
                                               ┌────────────────┬────────────────┐
                                               │ Calendar       │ Photos         │
                                               └────────────────┴────────────────┘
   "Save framing" here → chip "Column D" in the bar; scroll up twice → back at Root.
```

## 2. Feasibility on Hyprland / Omarchy (assessed 2026-09-23, before the build)

Facts checked on an Omarchy 4 laptop (Hyprland 0.56.2, Quickshell 0.3.1): hyprpm rebuilds plugins on every Hyprland update and
some fail to build (the ABI tax in action); Quickshell ships screencopy and toplevel-management modules (live window thumbnails
from QML); Omarchy toggles layouts per workspace; hyprgrass provides pinch gestures. hy3 (i3-style nested groups as a Hyprland
layout plugin) tracks Hyprland releases and installs via hyprpm or AUR.

The idea splits into three layers with very different costs.

| Layer | What it gives | Route | Effort | Main risk |
|---|---|---|---|---|
| A. Tree + movable viewport (the actual idea) | nested containers, zoom in/out by node, history, saved framings, keyboard/scroll navigation | **A1** external "IPC tiler" daemon: float all windows, compute geometry from its own tree, apply via `hyprctl dispatch movewindowpixel/resizewindowpixel exact`, park off-viewport windows on a special workspace | ~1 week | feels a frame late, fights Hyprland animations; no icons; prototype only |
| | same, done properly | **A2** C++ Hyprland layout plugin (fork hy3, add a per-monitor viewport node; nodes outside it hidden like inactive hy3 tabs) | 1–3 months | plugin ABI breaks every Hyprland release; every Omarchy update rebuilds through hyprpm; not distributable through the Omarchy plugin marketplace |
| B. Map / Overview, breadcrumb chips, back/forward, pinch-to-zoom with snap, icon LOD | the visible "fractal" feel | Quickshell layer-shell overlay drawing live `ScreencopyView` thumbnails of each toplevel on a zoomable canvas, plus a bar widget for the chips; drives layer A over IPC; hyprgrass pinch bound to zoom dispatchers | 1–2 weeks with existing Quattro plugin tooling | thumbnails are pictures, not live windows (same as hyprexpo/GNOME overview); needs layer A to exist |
| C. Continuous zoom of *live, interactive* windows, windows shrinking to icons in place | Dan's demo fidelity | Hyprland render hooks (hyprexpo-style scaled framebuffers) or a purpose-built compositor | 6+ months | effectively a new compositor; real apps have minimum sizes, Dan's React "apps" do not |

**What does not translate:** Omarchy has no desktop icons, so the Desktop node is just the wallpaper tile (keep as a
"home" node or drop). Real clients refuse tiny sizes, so the icon-LOD trick only works in the overview (layer B),
never in the live layout. Hyprland does animate geometry changes, so switching viewport in layer A will read as
windows sliding and growing, a fair stand-in for a camera zoom.

**Verdict at the time:** the *interaction model* (layer A1 + B) is a two-to-three-week build; the *compositor-level* version
(A2, then C) is real window-manager engineering with a permanent maintenance tax.

**What actually happened:** Hyprland 0.56's Lua config exposes `hl.layout.register`, a custom-layout API that runs inside the
compositor. That made layer A2 (a real tiled layout, no C++, no ABI churn) the cheapest route, and it is what this repository
implements. Layer B and C remain future work.
