#!/bin/bash
# After Hyprland is up, start the Omarchy shell. Open a terminal only when
# Quickshell fails so a healthy session looks like normal Omarchy.
set +e
export OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}

session_log=/tmp/omarchy-thor-session.log
for candidate in /boot/omarchy-session.log /flash/omarchy-session.log; do
  if [ -w "$candidate" ]; then
    session_log=$candidate
    break
  fi
done
{
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) desktop hook ==="
  echo "uid=$(id -u) OMARCHY_PATH=$OMARCHY_PATH"
  echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY-} XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR-}"
  echo "HYPRLAND_INSTANCE_SIGNATURE=${HYPRLAND_INSTANCE_SIGNATURE-}"
  echo "--- monitors ---"
  hyprctl monitors 2>&1
  echo "--- shell inputs ---"
  command -v omarchy-launch-shell quickshell qs 2>&1
  ls -ld "$OMARCHY_PATH" "$OMARCHY_PATH/shell" 2>&1
} >>"$session_log" 2>&1

[ -x /usr/local/bin/omarchy-thor-outputs ] && /usr/local/bin/omarchy-thor-outputs

if ! pgrep -x quickshell >/dev/null 2>&1; then
  if command -v omarchy-launch-shell >/dev/null; then
    omarchy-launch-shell >>"$session_log" 2>&1 &
  fi
fi

for _ in $(seq 1 30); do
  pgrep -x quickshell >/dev/null 2>&1 && break
  sleep 0.2
done
{
  echo "--- shell result ---"
  pgrep -af 'omarchy-launch-shell|quickshell' || true
  journalctl --user -b -t omarchy-shell --no-pager -n 100 2>/dev/null || true
} >>"$session_log" 2>&1

if pgrep -x quickshell >/dev/null 2>&1; then
  exit 0
fi

# Failure-only escape hatch: preserve a usable terminal and its diagnostics.
if pgrep -x ghostty >/dev/null 2>&1 || pgrep -x kitty >/dev/null 2>&1 ||
   pgrep -x foot >/dev/null 2>&1 || pgrep -x alacritty >/dev/null 2>&1; then
  exit 0
fi
if command -v xdg-terminal-exec >/dev/null; then
  xdg-terminal-exec &
elif command -v ghostty >/dev/null; then
  ghostty &
elif command -v kitty >/dev/null; then
  kitty &
fi
exit 0
