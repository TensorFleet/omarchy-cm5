# Omarchy on AYN Thor (SM8550)

Board target `BOARD=ayn-thor` for [mkimage.sh](../build/mkimage.sh). Android
stays on internal UFS. Flash the image to a **spare** microSD. The ROCKNIX
card is the rollback disk. Do not reflash ABL until this image boots.

## Boot contract

ROCKNIX-ABL loads FAT `/KERNEL` (`ANDROID!` bootimg). The kernel's built-in
initramfs is LibreELEC `busybox/scripts/init` (dummy 5-byte bootimg ramdisk
is ignored). That init does **not** treat STORAGE as the OS. Sequence:

1. `mount_flash` — `LABEL=ROCKNIX` → `/flash`, then `/flash/post-flash.sh`
2. `load_splash` — framebuffer splash from the **initramfs**, not SYSTEM
3. `mount_sysroot` — loop-mount `/flash/SYSTEM` → `/sysroot`, then
   `/flash/post-sysroot.sh` (**STORAGE is not mounted yet**)
4. `mount_storage` — `LABEL=STORAGE` → `/storage`, **or** source
   `/flash/mount-storage.sh` if that file exists (that script must mount)
5. `prepare_sysroot` — move `/flash` and `/storage` under `/sysroot`
6. `chroot /sysroot /usr/sbin/kernel-overlays-setup` — merge modules plus
   extra firmware from `/storage/.config/firmware`
7. `switch_root /sysroot /usr/lib/systemd/systemd` — PID 1 is **SYSTEM**,
   not STORAGE. ROCKNIX stays on the squashfs; STORAGE is userdata.

We keep that contract through step 7, then the SYSTEM stub pivots onto
ext4 STORAGE (Arch). Firmware and desktop files therefore have to land on
ext4 **at or after step 4**. `mount-storage.sh` is the official hook for
that. `post-sysroot.sh` is the wrong place — copies there vanish when
ext4 is mounted.

This image therefore:

1. Keeps the ROCKNIX `KERNEL` (7.1.2, 13 DTBs, Thor = index 9).
2. Replaces `SYSTEM` with a squashfs that satisfies the LibreELEC initramfs
   (`/usr/lib/systemd/systemd` is an Arch pivot, not systemd). ABL may still
   say ROCKNIX (that firmware is on the device). `post-sysroot.sh` bind-mounts
   `omarchy-splash.sh` over the KERNEL's `rocknix-splash` so the framebuffer
   shows Omarchy, not the compiled-in ROCKNIX wordmark.
3. Puts Arch + Omarchy on partition 2.

FAT `post-flash.sh` brings up USB-C CDC-ECM at `172.16.42.1` (no ACM gadget
in this kernel). Host: assign `172.16.42.2` and `telnet 172.16.42.1` during
initramfs, or SSH after systemd.

Boot steps append `/flash/omarchy-boot.log` on the FAT (readable from a Mac)
and a copy on the ext4 root. Previous run is kept as `omarchy-boot.log.old`.

See [thor-ai-handoff.md](thor-ai-handoff.md) for the live inspection notes and
remaining kernel work. Historical greeter/emergency-mode diagnosis is in
[thor-greeter-debug.md](thor-greeter-debug.md).

## Build

On this Mac (Apple Silicon + Docker Desktop), from the `omarchy-cm5` repo:

```
bash build/local-thor.sh            # packages + 12G image + verify
bash build/local-thor.sh packages   # omarchy 'any' pkgs only
bash build/local-thor.sh image      # mkimage + verify (needs build/pkgs-out)
```

The vendor fetch is reproducible: `build/thor-vendor.lock` pins the official
ROCKNIX SM8550 release, filename, SHA-256, and FAT partition geometry. Local
Docker builds and GitHub CI call the same `fetch-thor-vendor.sh` implementation.

The image lives in the `omarchy-thor-image` Docker volume during the build
(bind-mounting a 12G sparse file through osxfs is slow and breaks xattrs),
then is copied to `build/omarchy-thor.img`.

Without Docker (Linux, root, losetup):

```
# once: extract KERNEL/modules/firmware from a ROCKNIX FAT image
bash pkgs/aarch64-extra/linux-rocknix-sm8550/extract.sh \
  --from-fat /path/to/rocknix-p1-system.img

build/fetch-upstream.sh
sudo env BOARD=ayn-thor LOCAL_PKG_DIR=$PWD/build/pkgs-out bash build/mkimage.sh
sudo env BOARD=ayn-thor bash build/verify-image.sh build/omarchy-thor.img
```

CI: **Actions → test-thor** for fast source checks and **Actions →
build-image-thor** for a verified image plus `thor-build-*` GitHub release.

## Flash

```
xz -dc omarchy-thor.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Insert the spare card, hold **Vol −**, pick device **Thor**, boot Linux.
**Vol +** at power-on still forces Android.

First boot: `omarchy-provision-owner` on tty1 (top DSI), then SDDM / Hyprland.

First-boot setup is a tty1 gum form (Return, arrows, then username). The
Thor has no QWERTY, so `omarchy-thor-kb` turns the gamepad into a virtual
keyboard (A/B/Start = Enter, D-pad = arrows, Select/X = Esc, Y = delete)
and `gum input` is replaced by a D-pad letter picker. The mapper only
runs while `/var/lib/omarchy/provisioning/pending` exists.

After provisioning, `omarchy-thor-gamepad-wake` watches the physical gamepad
without grabbing it, so games still receive every event. Button presses emit a
dedicated wake-key event for the Wayland idle monitor. While the Omarchy
screensaver is present, the helper also emits Escape to dismiss it; it does not
bypass the password lock.

For a local debug card, Wi-Fi can be provisioned without embedding credentials
in the image. Put a file named `omarchy-thor-wifi` on the ROCKNIX FAT with the
SSID on line 1 and WPA passphrase on line 2. The one-shot importer creates an
autoconnecting NetworkManager profile and deletes the FAT credential after
import. `THOR_WIFI_FILE=/path/to/.wifi` stages this file through
`mk-thor-bootfiles.sh`.

Passwordless sudo is intentionally opt-in. An
`omarchy-thor-passwordless-sudo` marker on the ROCKNIX FAT enables
`NOPASSWD: ALL` for the `hyper` debug owner. Build updates can stage the marker
with `THOR_PASSWORDLESS_SUDO=1`; release images do not contain it.

Firmware is the whole ROCKNIX overlay tree for Thor (not a hand-picked
list). `extract.sh` copies `usr/lib/kernel-overlays/base/lib/firmware`
and drops Ayaneo/Odin 2 siblings. FAT `firmware/` is applied onto ext4
after STORAGE is mounted. GPU needs `qcom/a740_sqe.fw` + `gmu_gen70200.bin`
+ `qcom/sm8550/a740_zap.mbn` or Hyprland dies while `fb0` still works.
After setup, if the console stays up, read `omarchy-desktop.log` on the FAT.

Both DSI panels are native portrait panels mounted in the Thor chassis.
Hyprland uses `1080x1920@60` for top-panel DSI-2, `preferred` for DSI-1, and
`transform = 3` for both outputs, with
the touch devices mapped by output name. The earlier failure came from a stale
legacy `monitors.conf` containing unsupported Lua-era keys, not from the
working transform in `monitors.lua`. Apply-storage deletes legacy
`monitors.conf` / `ayn-thor.conf` files each boot. The greeter Lua must stay
monitor-only: `hl.config` / `hl.exec` are rejected on this build.

ROCKNIX 7.1.2 can intermittently lose the frame-done signal for DSI-2's
command-mode encoder and leave only the physical top-panel scanout corrupt.
The 60 Hz cap reduces load but does not eliminate the driver race.
`omarchy-thor-display-recover.service` watches for encoder 38's timeout and
power-cycles only DSI-2. The upstream-quality fix is to port ROCKNIX's newer
ICNA35xx brightness/first-kickoff serialization into the SM8550 kernel.

USB-C hub data, Ethernet, and Power Delivery enumerate on the tested unit, but
the kernel's `DP-1` remains disconnected with no HPD, lanes, or EDID. This is a
Qualcomm PMIC GLINK/Alt Mode issue (or hub negotiation issue), not a missing
Hyprland output rule. See the handoff for captured sysfs/DRM evidence and the
next powered-hub/direct-adapter tests.
