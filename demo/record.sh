#!/usr/bin/env bash
# Scripted demo of fractal-wm, recorded with Omarchy's screen recorder.
#
# Opens five windows on the active workspace (terminal, browser on the repo,
# file manager, nvim on notes.md, a live view of the tree), then zooms into
# nvim, back out to the top, and into the browser. A floating key display
# shows the key each step corresponds to. Everything is driven through the
# `fractal` CLI, which is the same path the keybindings use.
#
# Usage: switch to an empty workspace, then  demo/record.sh
# Needs: alacritty, chromium, nautilus, nvim, omarchy screenrecord (gpu-screen-recorder).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo_url="https://github.com/cgranier/fractal-wm"
fifo="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fractal-demo.fifo"
profile="$(mktemp -d)"
step="${STEP:-2.6}"          # seconds to hold each state on camera
pids=()

if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
  HYPRLAND_INSTANCE_SIGNATURE="$(ls -t "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/hypr" | head -1)"
  export HYPRLAND_INSTANCE_SIGNATURE
fi

# Run a desktop command with Hyprland's environment (D-Bus, Wayland display).
lua_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }
launch() { hyprctl dispatch "hl.dsp.exec_cmd($(lua_str "$1"))" >/dev/null; }
hud() { printf '%s\n' "$1" > "$fifo"; }
ws() { hyprctl activeworkspace -j | jq -r .id; }
count() { hyprctl clients -j | jq -r --argjson w "$(ws)" '[.[] | select(.workspace.id==$w and .floating==false)] | length'; }
wait_for() { # wait_for <count>
  for _ in $(seq 1 60); do [[ "$(count)" -ge "$1" ]] && return 0; sleep 0.25; done
  echo "timed out waiting for window $1" >&2; return 1
}
focus_class() { # focus_class <class regex>
  local addr; addr="$(hyprctl clients -j | jq -r --arg c "$1" --argjson w "$(ws)" '.[] | select(.workspace.id==$w and (.class|test($c))) | .address' | head -1)"
  hyprctl dispatch "hl.dsp.focus({ window = hl.get_window(\"address:$addr\") })" >/dev/null
}
cleanup() {
  # Close every window the demo opened on its workspace, by address, so an
  # already-running file manager or browser elsewhere is left alone.
  local w; w="$(ws)"
  hyprctl clients -j | jq -r --argjson w "$w" '.[] | select(.workspace.id==$w and (.class|test("^(demo-|fractal-hud|org.gnome.Nautilus|chrome-github)"))) | .address' |
    while read -r a; do hyprctl dispatch "hl.dsp.window.close({ window = hl.get_window(\"address:$a\") })" >/dev/null || true; done
  pkill -f "^alacritty --class fractal-hud" 2>/dev/null || true
  pkill -f "^alacritty --class demo-" 2>/dev/null || true
  pkill -f "^/usr/lib/chromium/chromium --user-data-dir=$profile" 2>/dev/null || true
  rm -f "$fifo"
  sleep 1; rm -rf "$profile" 2>/dev/null || (sleep 2; rm -rf "$profile") || true
}
trap cleanup EXIT

workspace="$(ws)"
[[ "$(count)" -eq 0 ]] || { echo "workspace $workspace is not empty" >&2; exit 1; }

# Key display: floating, pinned, never focused, bottom centre.
rm -f "$fifo"; mkfifo "$fifo"
hyprctl eval 'hl.window_rule({ match = { class = "^fractal-hud$" }, float = true, pin = true, no_focus = true, size = { 1240, 60 }, move = { 64, 812 } })' >/dev/null
fractal on >/dev/null
fractal reset >/dev/null
launch "alacritty --class fractal-hud -o font.size=16 -o window.padding.x=14 -o window.padding.y=10 -e $here/hud.sh $fifo"
sleep 1.2
hud "fractal-wm · a new window splits the focused tile along its longer side"

omarchy screenrecord --fullscreen
sleep 1.5

launch "alacritty --class demo-term -o font.size=11 -e $here/term.sh"
wait_for 1; sleep "$step"

hud "2nd window → the terminal tile is wide → it splits into a row"
# --disable-extensions: a fresh profile otherwise loads the system 1Password extension, whose welcome tab becomes a sixth window.
launch "chromium --user-data-dir=$profile --no-first-run --no-default-browser-check --disable-extensions --disable-sync --class=demo-browser --app=$repo_url"
wait_for 2; sleep "$step"

hud "3rd window → the browser tile is tall → it splits into a column"
launch "nautilus $here"
wait_for 3; sleep "$step"

hud "4th window → wide tile again → row"
launch "alacritty --class demo-nvim -o font.size=11 -e nvim $here/notes.md"
wait_for 4; sleep "$step"

hud "5th window → a live view of the tree (fractal tree)"
launch "alacritty --class demo-tree -o font.size=11 -e watch -n 0.3 -t -c cat ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/fractal-wm/ws-$workspace.txt"
wait_for 5; sleep "$((${step%.*} + 1))"

hud "focus nvim ·  Super+Ctrl+Down  → zoom in: nvim becomes the top window"
focus_class '^demo-nvim$'; sleep 0.8
fractal zoom-in >/dev/null; sleep "$((${step%.*} + 1))"

hud "Super+Ctrl+Down  again → nvim alone"
fractal zoom-in >/dev/null; sleep "$step"

hud "Super+Ctrl+Up  → zoom out one level"
fractal zoom-out >/dev/null; sleep "$step"
hud "Super+Ctrl+Up  → and again"
fractal zoom-out >/dev/null; sleep "$step"
hud "Super+Ctrl+Up  → and again"
fractal zoom-out >/dev/null; sleep "$step"
hud "Super+Ctrl+Shift+Up  → all the way to the top (overview)"
fractal zoom-root >/dev/null; sleep "$((${step%.*} + 1))"

hud "focus the browser ·  Super+Ctrl+Down  → browser + all tiles split off it"
focus_class '^(demo-browser|chrome-github)'; sleep 0.8
fractal zoom-in >/dev/null; sleep "$((${step%.*} + 2))"

hud "Super+Ctrl+Shift+1  → save this view as framing 1"
fractal frame-save 1 >/dev/null; sleep "$step"
hud "Super+Ctrl+Shift+Up  → overview ·  Super+Ctrl+1  → back to framing 1"
fractal zoom-root >/dev/null; sleep "$step"
fractal frame 1 >/dev/null; sleep "$((${step%.*} + 1))"
hud "github.com/cgranier/fractal-wm"
sleep 2

omarchy screenrecord --stop-recording
sleep 1
echo "recording saved under ${OMARCHY_SCREENRECORD_DIR:-$HOME/Videos}"
ls -t "${OMARCHY_SCREENRECORD_DIR:-$HOME/Videos}"/*.mp4 2>/dev/null | head -1
