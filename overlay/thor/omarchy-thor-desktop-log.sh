#!/bin/bash
# Write a desktop-start snapshot to the FAT so a Mac can read it.
sleep 12
boot=/boot
[[ -d $boot && -w $boot ]] || boot=/flash
{
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  echo "sddm: $(systemctl is-active sddm 2>/dev/null || true)"
  echo "graphical: $(systemctl is-active graphical.target 2>/dev/null || true)"
  echo "--- firmware ---"
  ls -l /usr/lib/firmware/qcom/a740_sqe.fw /usr/lib/firmware/qcom/gmu_gen70200.bin \
    /usr/lib/firmware/qcom/sm8550/a740_zap.mbn /usr/lib/firmware/regulatory.db 2>/dev/null || true
  echo "firmware files: $(find /usr/lib/firmware -type f 2>/dev/null | wc -l)"
  echo "--- dri ---"
  ls -l /dev/dri 2>/dev/null || true
  echo "--- drm ---"
  ls /sys/class/drm 2>/dev/null || true
  echo "--- sddm ---"
  journalctl -b -u sddm --no-pager -n 80 2>/dev/null || true
  echo "--- greeter launch ---"
  [ -f /run/omarchy-thor/gpu.env ] && cat /run/omarchy-thor/gpu.env
  [ -f /run/omarchy-thor/greeter.log ] && cat /run/omarchy-thor/greeter.log
  echo "--- greeter Hyprland internal log ---"
  for f in /run/user/961/hypr/*/hyprland.log; do
    [ -f "$f" ] || continue
    echo "### $f"
    tail -240 "$f"
  done
  echo "--- osk ---"
  ls -l /usr/local/bin/wvkbd-mobintl /usr/local/bin/omarchy-thor-osk \
    /usr/local/bin/omarchy-thor-greeter 2>/dev/null || true
  pgrep -af wvkbd || true
  [ -f "$boot/omarchy-osk.log" ] && cat "$boot/omarchy-osk.log"
  [ -f /tmp/omarchy-osk.log ] && cat /tmp/omarchy-osk.log
  echo "--- hypr/uwsm ---"
  journalctl -b --no-pager -n 40 _COMM=Hyprland 2>/dev/null || true
  echo "--- omarchy-shell ---"
  pgrep -af quickshell || true
  pgrep -af Hyprland || true
  journalctl -b -t omarchy-shell --no-pager -n 80 2>/dev/null || true
  [ -f /tmp/omarchy-thor-shell.log ] && cat /tmp/omarchy-thor-shell.log
  echo "--- dmesg gpu/iris ---"
  dmesg | grep -iE 'iris|msm|drm|firmware|hypr' | tail -40
} >"$boot/omarchy-desktop.log" 2>&1 || true
sync

# The first snapshot covers the greeter. Give the user time to authenticate,
# then append the actual desktop/Quickshell state as root so FAT permissions
# cannot hide the diagnostics.
sleep 60
{
  echo ""
  echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) late session snapshot ==="
  echo "--- sessions/processes ---"
  loginctl list-sessions --no-legend 2>/dev/null || true
  pgrep -af 'Hyprland|uwsm|quickshell|omarchy-launch-shell|ghostty|kitty|foot|alacritty' || true
  echo "--- Thor session hook ---"
  [ -f /tmp/omarchy-thor-session.log ] && cat /tmp/omarchy-thor-session.log
  echo "--- OSK ---"
  [ -f /tmp/omarchy-osk.log ] && cat /tmp/omarchy-osk.log
  echo "--- Omarchy shell journal ---"
  journalctl -b -t omarchy-shell --no-pager -n 240 2>/dev/null || true
  echo "--- user session journal ---"
  journalctl -b --no-pager -n 320 2>/dev/null | \
    grep -iE 'uwsm|quickshell|omarchy-shell|qml|hyprland|wayland.*session' || true
  echo "--- all Hyprland internal logs ---"
  for f in /run/user/*/hypr/*/hyprland.log; do
    [ -f "$f" ] || continue
    echo "### $f"
    tail -260 "$f"
  done
} >>"$boot/omarchy-desktop.log" 2>&1 || true
sync
