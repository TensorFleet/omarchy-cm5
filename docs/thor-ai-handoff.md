# AYN Thor Omarchy engineering handoff

Last updated: 2026-08-24. This document is for the next engineer or AI taking
over the AYN Thor (SM8550) bring-up.

## Goal and current state

The target is a flashable microSD image that boots through the Thor’s existing
ROCKNIX ABL, pivots into Arch Linux ARM, completes owner provisioning without a
physical keyboard, and starts the normal Omarchy 4 Hyprland + Quickshell
desktop across both internal displays.

That path now works on physical AYN Thor Base/Pro/Max hardware. The image and
FAT repair overlay contain all fixes discovered during bring-up. Two kernel
issues remain: intermittent corruption of the top DSI scanout, which now has an
automatic userspace recovery, and USB-C DisplayPort Alt Mode failing to assert
HPD with the currently tested hub.

## Safety and access

- Never write to the user’s 1 TB Samsung T7 (`disk6` during the original
  session). The Thor card was a roughly 32 GB removable disk (`disk25` at the
  time), but macOS disk numbers are not stable. `update-thor-fat.sh` deliberately
  selects only a small removable disk with a `ROCKNIX` FAT partition.
- Android lives on internal UFS. The Linux work belongs on a spare microSD.
  Volume − enters the ABL/Linux device picker; Volume + forces Android.
- Wi-Fi credentials live in the ignored `.wifi` file and must never be printed,
  documented, or committed. Full image and FAT builders accept
  `THOR_WIFI_FILE=/path/to/.wifi` and stage a credential that deletes itself
  after NetworkManager imports it.
- The live debug unit was reachable as `thor-omarchy.local` / `10.197.1.43`
  over Wi-Fi and as `172.16.42.1` over USB ECM. The DHCP address may change.
- Public releases are secret-free and do not enable passwordless sudo. Local
  debug builds may explicitly set `THOR_SSH_PUBKEY` and
  `THOR_PASSWORDLESS_SUDO=1`. The installer applies these to whichever owner has
  UID 1000; it no longer assumes the username `hyper`.

## Boot architecture

The key trap is that ROCKNIX’s initramfs does not directly switch to the ext4
`STORAGE` partition. It mounts FAT `ROCKNIX` as `/flash`, loop-mounts FAT
`SYSTEM` as `/sysroot`, mounts `STORAGE` as `/storage`, and then executes
`/sysroot/usr/lib/systemd/systemd`. Our tiny SYSTEM squashfs makes that path a
pivot shim into Arch’s systemd on STORAGE.

Important files:

- `build/mkimage.sh`: complete fresh image builder (`BOARD=ayn-thor`).
- `build/thor-vendor.lock`: immutable ROCKNIX release, filename, SHA-256, and
  FAT geometry.
- `build/fetch-thor-vendor.sh`: obtains KERNEL/SYSTEM data locally or from the
  pinned official release.
- `build/mk-thor-system-stub.sh`: builds the squashfs pivot shim.
- `overlay/thor/mount-storage.sh` and `thor-apply-storage.sh`: apply the same
  fixes after STORAGE exists; this is also the repair/update mechanism.
- `build/mk-thor-bootfiles.sh` + `build/update-thor-fat.sh`: seconds-long FAT
  update path for an already-flashed card.

Do not copy Arch files in `post-sysroot.sh`: STORAGE has not been mounted yet,
so they disappear underneath the later mount. Use `thor-apply-storage.sh`.

## Fixes already integrated

### GPU and desktop startup

- The complete ROCKNIX Thor firmware tree is installed, including A740 SQE,
  GMU, zap, CDSP, Iris/VPU, regulatory data, audio topology, and Wi-Fi firmware.
- `omarchy-thor-wait-dri` waits for `/dev/dri`, the render node, late firmware
  fallback completion, and minimum boot uptime before SDDM touches EGL.
- The session starts with `start-hyprland`, not raw `Hyprland`, eliminating the
  warning and ensuring Omarchy’s environment is loaded.
- `omarchy-thor-session` and `omarchy-thor-desktop` explicitly launch the
  Omarchy shell once the compositor socket exists. A terminal opens only as a
  failure escape hatch.
- `omarchy-thor-desktop-fallback.service` retries SDDM with the direct Thor
  session if the UWSM session never maps.

### Quickshell and Qt

Quickshell links Qt private ABI. The earlier package was built against a
different Qt patch release, so it installed successfully but failed before the
shell rendered, leaving a black desktop and movable pointer. The package build
now upgrades the chroot before compiling and encodes the Qt version into the
package release number. Both local and release image pipelines rebuild
Quickshell against the current ALARM Qt rather than trusting a possibly stale
rolling asset. `mkimage.sh` requires `quickshell-git` and runs
`quickshell --version`; `verify-image.sh` treats the shell as a hard Thor
requirement. FAT repair payloads may carry a compressed, hash-checked emergency
binary built against the image’s Qt.

### Dual displays, rotation, and touch

- Omarchy 4’s Hyprland configuration is Lua. Legacy `monitor =` Hyprlang files
  caused emergency mode/red-bar errors and must not return.
- `thor-monitors.lua` and `sddm-hyprland.lua` define both native-portrait panels
  with `transform = 3` for chassis-landscape orientation.
- DSI-2 (top 1080x1920 ICNA3520) is explicitly capped at 60 Hz. DSI-1 (bottom)
  uses its preferred mode.
- Touch devices are mapped to their corresponding outputs. Udev hwdb/rules
  supply the device calibration.
- Apply-storage deletes stale `monitors.conf`, `ayn-thor.conf`, and CM5 monitor
  files from skel and existing owners.

### Greeter, input, and first boot

- SDDM runs a clean-home Hyprland compositor with a monitor-only Lua file.
- `wvkbd-mobintl` starts after the greeter compositor socket appears and is
  pinned to DSI-1. The layout is functional but still looks desktop-like; an
  Android-style mobile layout is a future UX improvement.
- The keyboard is no longer a card-only repair binary. `wvkbd` 0.20 is built
  reproducibly from a checksum-pinned upstream tag in
  `pkgs/aarch64-extra/wvkbd`; local and release image builds require the
  resulting aarch64 package.
- `omarchy-thor-kb` maps gamepad buttons into a virtual keyboard only while the
  provisioning `pending` flag exists. `omarchy-thor-gum` supplies a D-pad letter
  picker for fields that require text.
- `omarchy-thor-gamepad-wake` observes without grabbing the gamepad, emits a
  wake key for Wayland idle, and emits Escape while the screensaver is present.

### Remote recovery

- OpenSSH is installed and enabled.
- Initramfs and systemd cooperate on a CDC-ECM gadget at `172.16.42.1/24`.
  Port 22 and the USB-only fallback port 53317 are allowed only on `usb0` by
  default.
- An optional two-line FAT Wi-Fi credential creates an autoconnecting
  NetworkManager profile and opens SSH on that Wi-Fi interface.
- Boot, greeter, OSK, and late desktop snapshots are written to FAT for recovery
  when networking is unavailable.

## Remaining top-panel corruption

The visual noise is physical DSI-2 scanout corruption, not a corrupt compositor
buffer: Hyprland screenshots remain clean while the panel is noisy. Kernel logs
show:

```text
dpu_encoder_frame_done_timeout ... enc38 frame done timeout
_dpu_encoder_phys_cmd_wait_for_idle ... id:38 pp:2 kickoff timeout
```

`omarchy-thor-display-recover.service` tails the kernel journal and cycles only
DSI-2 through Hyprland DPMS when encoder 38 times out. This restored the panel
in a controlled live test.

The upstream-quality work is to port ROCKNIX SM8750 commit `b59f018e0`
(`sm8750: fix panel initialization in gamescope`) or its ICNA35xx
brightness/first-kickoff serialization into the SM8550 kernel patch set. The
fix explains that brightness writes racing panel bring-up/first kickoff can
wedge the DSI command engine. This repository currently consumes a prebuilt
ROCKNIX KERNEL, so a real fix requires building/publishing a patched SM8550
kernel rather than changing the Arch rootfs.

## Remaining USB-C HDMI/DisplayPort issue

Observed with a USB-C hub and HDMI monitor:

- USB 2/3 hubs, Logitech input, Realtek Ethernet, USB Power Delivery, UCSI,
  GPIO SBU mux, QMP combo PHY, PMIC GLINK Alt Mode, and the DRM DP controller
  all bind successfully.
- Type-C sees a reverse-orientation partner and the Thor is USB host/power
  source.
- `/sys/class/drm/card0-DP-1/status` remains `disconnected`; EDID is empty;
  `dp_debug` reports zero lanes/rate/capabilities; Hyprland correctly sees only
  DSI-1 and DSI-2.
- Rebinding only `pmic_glink.altmode.0` after all suppliers were ready did not
  produce HPD.
- Boot logs contain `Failed to create device link (0x180)` from pmic-glink to
  `usb0-sbu-mux`, `88e8000.phy`, and `a600000.usb`, although all later bind.

Therefore this is below Hyprland: Qualcomm firmware/PMIC GLINK never delivered
an active DP/HPD notification to DRM, or the tested hub never negotiated DP Alt
Mode. Required next tests are a powered hub, a known-good direct USB-C-to-HDMI
adapter, unplug/replug with the connector flipped, and a journal/DRM-state
capture during hotplug. If hardware is ruled out, port ROCKNIX commit
`51112feae` (`soc/qcom: defer altmode probe until mode-switch registers`) to the
SM8550 kernel and rebuild. Merely adding a `DP-1` Hyprland rule cannot help while
the kernel connector is disconnected.

## Validation and release expectations

Run before publishing:

```bash
bash tests/thor-source.test.sh
bash build/local-thor.sh
sudo env BOARD=ayn-thor bash build/verify-image.sh build/omarchy-thor.img
git diff --check
```

The GitHub `test-thor` workflow performs fast source checks. The
`build-image-thor` workflow independently fetches the checksum-pinned vendor
image, rebuilds the required keyboard and Qt-ABI-matched Quickshell packages,
retries transient ALARM mirror failures, builds and verifies the complete
image, compresses/splits it, writes `SHA256SUMS`, and publishes a
`thor-build-*` release. Do not weaken hard verification checks to make a
partial desktop publish.
