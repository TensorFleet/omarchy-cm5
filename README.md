# Omarchy on ARM handhelds and Raspberry Pi CM5

This repository builds Omarchy 4 (“Quattro”) as bootable aarch64 images while
keeping the distribution itself as an overlay on
[basecamp/omarchy](https://github.com/basecamp/omarchy).

| Target | Board value | Boot media | Status |
|---|---|---|---|
| AYN Thor Base/Pro/Max (Snapdragon 8 Gen 2 / SM8550) | `ayn-thor` | microSD through the device’s existing ABL | Boots and runs the complete Omarchy Hyprland/Quickshell desktop on physical hardware |
| Raspberry Pi 5 / Compute Module 5 | `cm5` | SD, USB, NVMe, or eMMC | Image pipeline builds and verifies in CI; physical validation is still pending |

The Thor image includes the dual-screen layout, touch mapping, bottom-screen
login keyboard, gamepad-assisted first-boot setup, gamepad screensaver wake,
Qualcomm firmware, SSH recovery, and automatic recovery from the known top-panel
DSI timeout.

## Install on an AYN Thor

You need a spare microSD card of at least 16 GB. Android remains on internal
storage. Keep a known-working ROCKNIX card as a rollback and do not modify ABL.

1. Open the repository’s GitHub Releases and download the newest
   `thor-build-*` release assets: the image, `SHA256SUMS`, and verification
   report.
2. If the image was split to fit GitHub’s asset-size limit, reassemble it:

   ```bash
   cat omarchy-thor.img.xz.part* > omarchy-thor.img.xz
   ```

3. Verify the downloaded files:

   ```bash
   sha256sum -c SHA256SUMS
   ```

4. Flash the image. Double-check the destination because this overwrites the
   selected disk.

   Linux:

   ```bash
   xz -dc omarchy-thor.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
   ```

   macOS:

   ```bash
   diskutil list external physical
   diskutil unmountDisk /dev/diskN
   xz -dc omarchy-thor.img.xz | sudo dd of=/dev/rdiskN bs=4m
   diskutil eject /dev/diskN
   ```

5. Insert the card, power on while holding **Volume −**, select device
   **Thor**, and boot Linux. **Volume +** at power-on still forces Android.
6. Complete first-boot owner setup. The bottom screen supplies an on-screen
   keyboard. During the console form, the gamepad maps A/B/Start to Enter,
   D-pad to arrows, Select/X to Escape, and Y to Delete.

The root filesystem grows to fill the card automatically. After provisioning,
SDDM logs into the selected owner and starts the complete Omarchy desktop.

### Optional Wi-Fi provisioning

To bring up Wi-Fi without a USB keyboard, mount the card’s `ROCKNIX` FAT
partition after flashing and create `omarchy-thor-wifi` containing the SSID on
line 1 and WPA passphrase on line 2. The first boot imports it into
NetworkManager and deletes the plaintext file.

Never commit that file. Local build automation accepts the same data through
`THOR_WIFI_FILE=/path/to/.wifi`; `.wifi` and generated payloads are ignored by
Git.

### Recovery access

The image enables OpenSSH and a USB-C CDC-ECM recovery interface at
`172.16.42.1/24`. Configure the Mac/Linux host end as `172.16.42.2/24`, then
connect to the owner account:

```bash
ssh owner@172.16.42.1
```

A local debug image can stage an SSH public key and explicitly enable
passwordless sudo:

```bash
sudo env \
  BOARD=ayn-thor \
  THOR_SSH_PUBKEY="$HOME/.ssh/id_ed25519.pub" \
  THOR_PASSWORDLESS_SUDO=1 \
  LOCAL_PKG_DIR="$PWD/build/pkgs-out" \
  bash build/mkimage.sh
```

Release CI never sets those debug options.

## Build locally

On Apple Silicon, install Docker Desktop, the GitHub CLI (`gh`), and `xz`, then:

```bash
bash build/local-thor.sh            # packages, 12 GB image, and verification
bash build/local-thor.sh packages   # package stage only
bash build/local-thor.sh image      # image stage using build/pkgs-out
```

The build downloads the pinned ROCKNIX SM8550 image, verifies its SHA-256, and
extracts only the Thor kernel/modules/firmware payload. The large image is built
inside the `omarchy-thor-image` Docker volume and copied to
`build/omarchy-thor.img` after verification.

On native Linux, install `qemu-user-static`, `arch-install-scripts`,
`libarchive-tools`, `dosfstools`, `parted`, `squashfs-tools`, `mtools`, `zstd`,
and `python3`, then:

```bash
bash build/fetch-thor-vendor.sh
bash build/fetch-upstream.sh
bash build/resolve-packages.sh
sudo env BOARD=ayn-thor LOCAL_PKG_DIR="$PWD/build/pkgs-out" bash build/mkimage.sh
sudo env BOARD=ayn-thor bash build/verify-image.sh build/omarchy-thor.img
```

For a fast repair of an existing Thor card, build and copy only the FAT
payload:

```bash
bash build/mk-thor-bootfiles.sh
bash build/update-thor-fat.sh diskN   # macOS; validates a small ROCKNIX disk
```

## CI and releases

- `test-thor` checks shell/C syntax, dual-screen settings, secure debug defaults,
  and parity between fresh-image and FAT-repair payloads.
- `build-arm-packages` maintains the rolling `aarch64-pkgs` pacman repository,
  including an ABI-current Quickshell build.
- `build-image-thor` downloads and verifies the pinned ROCKNIX source, builds a
  12 GB image, runs hard image assertions, compresses/splits it, creates
  checksums, and publishes a `thor-build-*` GitHub release.
- `build-image` continues to build and release the CM5 image.

The Thor image build fails rather than publishing a partial desktop if
Quickshell, Omarchy, the OSK, SSH, firmware, display recovery, or provisioning
support is absent.

## Known Thor kernel issues

- ROCKNIX kernel 7.1.2 can occasionally lose the top command-mode DSI panel’s
  frame-done interrupt. DSI-2 is capped at 60 Hz and
  `omarchy-thor-display-recover.service` cycles only that panel when encoder 38
  times out. A future kernel should port ROCKNIX’s newer ICNA35xx
  brightness/first-kickoff serialization fix.
- USB-C hubs enumerate USB and Ethernet, but DisplayPort Alt Mode/HDMI has not
  yet asserted HPD on the tested Thor under this kernel. This is a Qualcomm
  PMIC GLINK/Alt Mode investigation, not a Hyprland monitor-layout issue.

See [docs/thor.md](docs/thor.md) for the boot contract and detailed debugging,
[docs/thor-greeter-debug.md](docs/thor-greeter-debug.md) for the display/session
history, and [docs/thor-ai-handoff.md](docs/thor-ai-handoff.md) for the current
engineering handoff.

## Repository layout

```text
upstream.lock        pinned basecamp/omarchy Quattro commit
build/               image, vendor-fetch, package, and FAT-update tooling
overlay/install/     target package lists and hardware/install hooks
overlay/systemd/     first-boot and Thor recovery services
overlay/thor/        dual-display, input, audio, session, and boot payload
pkgs/                aarch64 package rebuild and hosted-repository pipeline
tests/               installer and Thor source checks
docs/                implementation and troubleshooting notes
```

Canonical home: `TensorFleet/omarchy-cm5`.
