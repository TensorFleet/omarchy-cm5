# Hackberry Pi CM5 (ZitaoTech) hardware setup for omarchy-cm5.
# Companion of overlay/install/hardware/rpi-cm5.sh; additive-only, runs after it.
# Validated live on Hackberry Pi CM5 Lite (kernel 6.18.45-1-rpi-16k) 2026-09-13/14.

set -euo pipefail

config_txt_patch() {
  # Boot config additions live in overlay/boot/config.txt; nothing to do here.
  :
}

# --- Display panel -----------------------------------------------------------
# Panel is driven by vc4-kms-dsi-pibrick (720x720 portrait, DSI-to-MIPI bridge
# on the ZitaoTech carrier). Hyprland: physical 720x720 gets a 1.6 desktop
# scale => ~450 logical px. Small-screen-safe screensaver font sizing is
# handled by the patched omarchy-launch-screensaver (separate change).

# --- Battery gauge (MAX17048 @ i2c2 addr 0x36) ------------------------------
# hackberrypicm5.dtbo contains battery@36 (hackberrypi,max17048-battery).
# The out-of-tree hackberrypi_max17048 module needs to be packaged so it
# auto-probes when the overlay exposes the i2c device. Kernel >=6.12 needs
# .fwnode initialization (not the older .of_node path).
# PR carries module + header dependencies: linux-rpi-16k-headers.

# --- Onboard speaker path ----------------------------------------------------
# Speakers connect through the carrier's MH-M18 Bluetooth A2DP module into a
# PAM8406 amp. The USB PCM2902 codec is CAPTURE-ONLY (mic), and neither HDMI
# DAI feeds the internal speakers. Bring-up = bluetoothctl pair/trust the
# MH-M18, pipewire bluez5 a2dp-sink, wpctl set-default. Document in
# postinstall instead of hard-requiring a BT pairing at build time.
cat > /root/.omarchy-firstboot-hackberry-bt <<'EOF'
# On first login: pair the onboard speaker (MH-M18). Verified path:
# 1. bluetoothctl: power on / agent on / default-agent / scan on / pair <MAC>
#    trust <MAC> / connect <MAC>
# 2. wpctl set-default <bluez-sink>
# 3. Test: pw-play /usr/share/sounds/alsa/Front_Center.wav
EOF
for d in /etc/skel /root /home/*; do
  install -m 644 /root/.omarchy-firstboot-hackberry-bt "$d/" 2>/dev/null || true
done

# --- Q20 keyboard ------------------------------------------------------------
# Enabled by overlay/boot/config.txt [cm5] dtoverlay=dwc2,dr_mode=host.
# Firmware map (validated by evdev capture):
#  button 1 tap  = BTN_LEFT            (left-click)
#  button 2 tap  = KEY_LEFTMETA        (Super/menu)
#  button 3 tap  = KEY_ESC; hold >=400ms = KEY_F4
#  button 4 tap  = KEY_TAB; hold >=400ms = BTN_RIGHT (right-click)
#  nub           = BTN_LEFT; no distinct long-press code in stock firmware.
# No userspace remap helper required for this mapping.
