#!/bin/bash
set -e
cd /Users/daffi/tmp/hermes-scratch/omarchy-cm5
git add PR_BODY.md
git commit -q -F - <<'MSG'
Hackberry Pi CM5 (ZitaoTech): validated hardware bring-up

- Q20 standalone keyboard via [cm5] dtoverlay=dwc2,dr_mode=host. Root cause:
  QMK RP2040 controller sits on the SoC internal DWC2 USB2 (disabled default).
- Calibrated physical button map documented (raw evdev + VIAL .vil cross-check)
- hackberrypicm5 overlay for MAX17048 battery i2c 0x36 (validated live)
- Onboard speakers via carrier BT A2DP module to PAM8406 (validated live)
- vc4-kms-dsi-pibrick 720x720 panel (validated, Hyprland scale 1.6)
- docs/hackberry-cm5-hardware.md: full validation log with reverts
MSG
git add -A
git commit -q -m 'Add PR_BODY.md (PR description source)' 2>/dev/null || true
git log --oneline -2
git push -u origin hackberry-cm5-hardware 2>&1 | tail -2
