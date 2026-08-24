#!/bin/bash
# SDDM CompositorCommand. Give Hyprland an empty, boot-local home so neither
# /var/lib/sddm nor an old Omarchy config can be discovered implicitly.
# Do not hyprctl keyword monitor — that is hyprlang and trips emergency mode.
runtime=/run/omarchy-thor
export HOME="$runtime/sddm-home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
export XDG_STATE_HOME="$HOME/.local/state"
unset OMARCHY_PATH HYPRLAND_CONFIG
mkdir -p "$XDG_CONFIG_HOME/hypr" "$XDG_CACHE_HOME" "$XDG_STATE_HOME"

# ExecStartPre creates this file after the GPU is ready.  Source it here
# instead of using systemd EnvironmentFile, which is read before ExecStartPre.
if [[ -r $runtime/gpu.env ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$runtime/gpu.env"
  set +a
fi

log="$runtime/greeter.log"
if ! touch "$log" 2>/dev/null; then
  log=/tmp/omarchy-thor-greeter.log
fi
exec >>"$log" 2>&1

echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) greeter start ==="
id
echo "HOME=$HOME XDG_CONFIG_HOME=$XDG_CONFIG_HOME"
[[ -r $runtime/gpu.env ]] && cat "$runtime/gpu.env"
echo "--- greeter config ---"
sed -n '1,240p' /usr/share/sddm/hyprland.lua
echo "--- possible competing configs ---"
find /usr/share/sddm /etc/sddm.conf.d /var/lib/sddm/.config/hypr \
  -maxdepth 2 -type f -print 2>/dev/null | sort
echo "--- start-hyprland ---"
start-hyprland -- --config /usr/share/sddm/hyprland.lua &
hyprland_pid=$!
trap 'kill -TERM "$hyprland_pid" 2>/dev/null || true' HUP INT TERM

# The OSK helper waits for this compositor's socket, then pins its layer to
# DSI-1. Keep it outside the Lua start event so it inherits this runtime.
/usr/local/bin/omarchy-thor-osk &
wait "$hyprland_pid"
