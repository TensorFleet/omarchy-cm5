#!/bin/bash
# Direct Hyprland when uwsm does not map a session. Start Hyprland, then
# force outputs + shell + a terminal via hyprctl (do not rely only on
# hyprland.start — a missed event is a black screen with a cursor).
set -euo pipefail
. /usr/share/uwsm/env.d/20-ayn-thor 2>/dev/null || true
export OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
cfg=$HOME/.config/hypr/hyprland.lua
[[ -f $cfg ]] || cfg=/etc/skel/.config/hypr/hyprland.lua
[[ -f $cfg ]] || cfg=/usr/share/omarchy/config/hypr/hyprland.lua
start-hyprland -- --config "$cfg" &
hpid=$!
for _ in $(seq 1 80); do
  hyprctl monitors >/dev/null 2>&1 && break
  sleep 0.1
done
/usr/local/bin/omarchy-thor-desktop || true
wait "$hpid"
