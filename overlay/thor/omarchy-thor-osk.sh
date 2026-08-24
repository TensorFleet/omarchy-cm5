#!/bin/bash
# Bottom-deck OSK for the SDDM greeter. Must attach after Hyprland owns a
# Wayland socket. Launching as a sibling with no WAYLAND_DISPLAY is a
# silent no-op and leaves DSI-1 black. wvkbd has no --output flag, so pin
# it with a Hyprland layerrule and focus DSI-1 before spawn.
logfile=/tmp/omarchy-osk.log
for candidate in /boot/omarchy-osk.log /flash/omarchy-osk.log; do
  if [ -w "$candidate" ]; then
    logfile=$candidate
    break
  fi
done
log() { echo "$(date -u +%H:%M:%S) $*" >>"$logfile" 2>/dev/null || true; }

bin=/usr/local/bin/wvkbd-mobintl
[ -x "$bin" ] || bin=$(command -v wvkbd-mobintl 2>/dev/null) || true
if [ -z "$bin" ] || [ ! -x "$bin" ]; then
  log "no wvkbd-mobintl"
  exit 0
fi

runtime=${XDG_RUNTIME_DIR:-/run/sddm}
log "start uid=$(id -u) runtime=$runtime wayland=${WAYLAND_DISPLAY-}"

for _ in $(seq 1 120); do
  if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    for dir in "$runtime/hypr" /run/sddm/hypr /tmp/hypr; do
      [ -d "$dir" ] || continue
      sig=$(ls -1t "$dir" 2>/dev/null | head -1)
      if [ -n "$sig" ]; then
        export HYPRLAND_INSTANCE_SIGNATURE=$sig
        export XDG_RUNTIME_DIR=${dir%/*}
        runtime=$XDG_RUNTIME_DIR
        break
      fi
    done
  fi
  if [ -z "${WAYLAND_DISPLAY:-}" ]; then
    for w in wayland-1 wayland-0 wayland-2; do
      if [ -S "$runtime/$w" ]; then
        export WAYLAND_DISPLAY=$w
        break
      fi
    done
  fi
  if [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && [ -n "${WAYLAND_DISPLAY:-}" ]; then
    hyprctl monitors >/dev/null 2>&1 && break
  fi
  sleep 0.15
done

log "sig=${HYPRLAND_INSTANCE_SIGNATURE-} display=${WAYLAND_DISPLAY-} runtime=$runtime"
if ! hyprctl monitors >/dev/null 2>&1; then
  log "hyprctl never ready"
  exit 0
fi
hyprctl monitors >>"$logfile" 2>/dev/null || true

# Pin the layer-shell surface to the bottom deck.  The script has already
# discovered and exported the compositor socket, so launch directly; Hyprland
# 0.55's Lua command parser treats an absolute path passed through
# `dispatch exec` as Lua source and rejects it before spawning.
hyprctl keyword layerrule "monitor DSI-1, keyboard" >/dev/null 2>&1 || true
hyprctl keyword layerrule "monitor DSI-1, wvkbd" >/dev/null 2>&1 || true
hyprctl dispatch focusmonitor DSI-1 >/dev/null 2>&1 || true
sleep 0.25

# DSI-1 is 1240x1080 after rotation. The simple layer omits the desktop
# function/navigation row that made the full layout cramped on this panel.
"$bin" -H 1080 -L 1080 --landscape-layers simple,special,emoji \
  >>"$logfile" 2>&1 &
sleep 0.4
if pgrep -f wvkbd-mobintl >/dev/null 2>&1; then
  log "wvkbd running pid=$(pgrep -f wvkbd-mobintl | tr '\n' ' ')"
else
  log "wvkbd not running after exec"
fi
hyprctl dispatch focusmonitor DSI-2 >/dev/null 2>&1 || true
