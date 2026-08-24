#!/bin/bash
# AYN Thor hardware setup — analog of overlay/install/hardware/rpi-cm5.sh.
# Runs inside the image chroot after upstream hardware/all.sh (laptop probes
# all no-op on this SoC).
set -euo pipefail

mkdir -p /etc/skel/.config/hypr /usr/share/omarchy/config/hypr

# Omarchy 4 reads ~/.config/hypr/monitors.lua (via hyprland.lua). The old
# hyprland.conf source line never ran, so DSI-2 stayed portrait and the
# setup UI only filled 1080 of the 1920-wide landscape panel.
if [[ -f /boot/thor-monitors.lua ]]; then
  install -Dm644 /boot/thor-monitors.lua /etc/skel/.config/hypr/monitors.lua
  install -Dm644 /boot/thor-monitors.lua /usr/share/omarchy/config/hypr/monitors.lua
fi

# Omarchy 4 / Hyprland 0.55+ rejects `monitor =` in .conf (unknown keyword).
# Rotation lives in monitors.lua only. Strip any leftover source line.
if [[ -f /etc/skel/.config/hypr/hyprland.conf ]]; then
  sed -i '/ayn-thor.conf/d' /etc/skel/.config/hypr/hyprland.conf
fi

# Omarchy 4 already ships looknfeel.lua. Do not append hl.config here —
# this Hyprland build treats unknown keys as a critical parse error.

mkdir -p /etc/omarchy-thor
echo balanced >/etc/omarchy-thor/power-profile

# fbcon on the top panel so omarchy-provision-owner on tty1 is visible.
mkdir -p /etc/modprobe.d
cat >/etc/modprobe.d/thor-fbcon.conf <<'EOF'
options msm fbcon=rotate:1
EOF
if [[ -f /boot/blacklist-qcom-iris.conf ]]; then
  install -Dm644 /boot/blacklist-qcom-iris.conf /etc/modprobe.d/blacklist-qcom-iris.conf
else
  cat >/etc/modprobe.d/blacklist-qcom-iris.conf <<'EOF'
blacklist qcom_iris
EOF
fi

if [[ -f /boot/20-ayn-thor.uwsm ]]; then
  install -Dm644 /boot/20-ayn-thor.uwsm /usr/share/uwsm/env.d/20-ayn-thor
fi

# Console: prefer tty0/tty1 on DSI.
mkdir -p /etc/systemd/system/getty@tty1.service.d
printf '[Service]\nTTYPath=/dev/tty1\n' >/etc/systemd/system/getty@tty1.service.d/thor.conf
