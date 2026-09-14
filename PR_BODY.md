# Hackberry Pi CM5 (ZitaoTech): validated hardware bring-up for Omarchy on CM5

Physical validation of the CM5 image on the Hackberry Pi CM5 Lite carrier
(panel, battery gauge, onboard speakers, standalone Q20 keyboard). This PR
carries the config/kernel/packages additions plus a validated learnings doc; it
moves the CM5 row of the README from "physical validation pending" toward
carrier-validated.

## What was validated (physical hardware, 2026-09-13/14)

- Q20 standalone keyboard working with zero dongles (root cause + fix below).
- Onboard speakers audible via the carrier's onboard BT A2DP module -> PAM8406
  amp; PCM2902 confirmed capture-only (mic).
- MAX17048 battery gauge live via `hackberrypicm5` overlay (battery@36) +
  out-of-tree module (newer-kernel fwnode API).
- 720x720 DSI panel on `vc4-kms-dsi-pibrick`, Hyprland at scale 1.6.
- Mic capture, NVMe, LEDs, Tailscale, Hermes Agent runtime on-device.

Test log with commands + backups: `docs/hackberry-cm5-hardware.md`.

## The one non-obvious blocker: Q20 keyboard = internal DWC2 USB host

The Q20 keyboard is a ZitaoTech QMK/VIAL RP2040 controller (USB 4041:0001)
wired to the CM5 SoC's internal DWC2 USB2 controller at `/axi/usb@480000`,
disabled by default in the base DT. With `[cm5] dtoverlay=dwc2,dr_mode=host`
(mirroring the old-image known-good config) the keyboard + nub enumerate as
normal USB HID - no userspace helpers, no external dongles.

## Q20 physical map (raw evdev-calibrated; VIAL .vil cross-checked)

| Control | tap | hold >=400ms |
|---|---|---|
| 1 | BTN_LEFT | held |
| 2 | Super (KEY_LEFTMETA) | held |
| 3 | Esc | F4 |
| 4 | Tab | right-click (BTN_RIGHT) |
| nub | left-click | held (no distinct code) |

## Changes

- `overlay/boot/config.txt`: Hackberry carrier block - `hackberrypicm5`
  overlay, `dtparam=audio=on`, `vc4-kms-dsi-pibrick` panel, `[cm5]`
  `dtoverlay=dwc2,dr_mode=host`.
- `overlay/install/hardware/hackberry-cm5.sh` (new): carrier bring-up notes +
  first-boot BT speaker pairing helper; conditioned in
  `rpi-cm5.sh` on the presence of `/boot/overlays/hackberrypicm5.dtbo`, so
  non-Hackberry CM5 carriers are untouched.
- `docs/hackberry-cm5-hardware.md` (new): the full validated learnings doc

## Not in this PR (honest gaps)

- Battery module is out-of-tree; needs packaging (dkms) + a same-version
  kernel/headers rebuild before it's PR-grade automatable.
- microSD hot-plug not supported by current DT (`broken-cd`).
- HDMI ports enumerated but not physically tested (no monitor attached).
