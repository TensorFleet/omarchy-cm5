# Hackberry Pi CM5 (ZitaoTech) — physical validation notes for omarchy-cm5

Validated 2026-09-13/14 on Hackberry Pi CM5 Lite (Rev1.0), SD-root Omarchy
build, kernel 6.18.45-1-rpi-16k, Hyprland on v3d. All fixes live-validated
against the old working image as golden reference.

## What works after this PR (physically confirmed)

- Panel: 720x720 DSI panel via `vc4-kms-dsi-pibrick`, Hyprland scale 1.6.
- Battery: MAX17048 gauge at i2c 0x36 via `hackberrypicm5` overlay + out-of-tree
  `hackberrypi-max17048` module. Upower/syfs report capacity + voltage.
- Keyboard: standalone Q20 keyboard over internal DWC2 USB (see below); no
  dongles.
- Speakers: onboard MH-M18 BT module -> PAM8406 amp; user-validated output.
- Mic: PCM2902 capture verified (48kHz mono, 2s arecord rc=0).
- NVMe: mounts, boots Hermes-side userdata via bind.
- LEDs: ACT/PWR/default-on classes; ACT driven by mmc0.
- Tailscale, PipeWire audio stack, Hyprland/Quickshell desktop.

## Q20 keyboard: root cause and fix

Symptom: fresh image had no keyboard at all (no USB device, no kbd event node).
Wrong guesses eliminated: not i2c, not GPIO, not the touch controller
(15-0048 EP0110M09 is touch only), not Logitech Bolt.

Root cause: the Q20 keyboard is a ZitaoTech QMK/VIAL RP2040 USB controller
(`4041:0001`, "ZitaoTech HACKBerryPiQ20") wired to the CM5 SoC's internal DWC2
USB2 controller at `/axi/usb@480000`. That DT node was disabled in the base
CM5 device tree, so the keyboard never enumerated.

Fix: `[cm5] dtoverlay=dwc2,dr_mode=host` in config.txt, mirroring the old
image's known-good config. dwc2 is in the stock kernel, no packages.

## Q20 physical button map (calibrated by raw evdev capture + VIAL .vil cross-check)

| Control | Short tap | Long hold (>=400ms QMK tap-dance) |
|---|---|---|
| button 1 | BTN_LEFT (left-click) | held left-click |
| button 2 | KEY_LEFTMETA (Super/menu) | held |
| button 3 | KEY_ESC | KEY_F4 |
| button 4 | KEY_TAB | BTN_RIGHT (right-click) |
| nub | BTN_LEFT | held BTN_LEFT (no distinct code) |

Interfaces: event7 = kbd (META/ESC/F4/TAB), event8 = mouse (BTN_LEFT/BTN_RIGHT).
VIAL reference: Keyboard/HackberryPi_CM5_Q20.vil in ZitaoTech/HackberryPiCM5.

## Speakers

Root cause: fresh image lacked BT audio session; Caribbean speakers are wired
through the onboard MH-M18 Bluetooth A2DP module into a PAM8406 amp. The
PCM2902 USB codec is capture-only and HDMI DAIs do not feed the internal
speakers. Bring-up = `bluetoothctl pair/trust/connect` + `wpctl set-default
<bluez-sink>`. mix quality is hardware-limited (mono PAM8406), not a config
issue - user-confirmed and accepted.

## Battery

- Built `hackberrypi-max17048` module out-of-tree against
  `linux-rpi-16k-headers` (kernel header drift: 6.18.45 running vs 6.18.51
  headers; module vermagic binary-patched same-length to load).
- Newer kernel requires `.fwnode = dev_fwnode()` init (old source used
  `.of_node`).
- Live-verified: `/sys/class/power_supply/battery/{capacity,status,voltage_now}`
  populated; reboot-persistence now expected via config.txt overlay swap
  (`hackberrypi` -> `hackberrypicm5`, which carries `battery@36`).

## Screensaver (small-panel scaling)

`omarchy-launch-screensaver` rendered fixed 18pt ANSI art; on the 720x720
(1.6 scale => ~450 logical px) panel, 81-column art overshot the screen.
Fix: compute font size from monitor logical width / art width.

## Verification log (device)

`/home/don/omarchy-hw-fixes-2026-09-13.log` contains the full per-agent
change/verified/revert-state log; retains all backups made.
