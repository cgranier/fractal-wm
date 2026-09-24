# Fractal WM — demo notes

A workspace is one tree. New windows split the focused tile along its
larger dimension, so the tree deepens on its own:

    terminal | ( browser / ( files | ( nvim / tree ) ) )

## Moves shown in the recording

- Super + Ctrl + Down   zoom in: the focused window becomes the top of the view
- Super + Ctrl + Up     zoom out one level
- Super + Ctrl + Shift + Up   overview (root)
- Super + Ctrl + Shift + 1    save this view as framing 1

## Why

Tilers shrink every window as you add more. Here the screen is a camera:
zoom into the part you are working on, and the rest waits offscreen.

- [x] tile selection (pick which tiles a view shows)
- [x] live-thumbnail map with breadcrumb chips
- [x] dwindle-style insertion
- [x] top-window zoom
