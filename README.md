# omarchy-cm5

Omarchy 4 ("Quattro") on the Raspberry Pi Compute Module 5 — a mini distro
built as an **overlay** on upstream [basecamp/omarchy](https://github.com/basecamp/omarchy),
modifying as close to zero lines of the original code as possible.

> **Status:** image pipeline runs end-to-end in CI (build → verify → release).
> Not yet validated on physical hardware.
> Read [`docs/feasibility.md`](docs/feasibility.md) for the full difficulty
> assessment — the short version is below.

## The short version

Porting Omarchy Quattro to the CM5 is **moderate difficulty, and very little of
it is "porting code."** Omarchy itself is ~90% architecture-neutral bash,
Quickshell QML, and config files layered over Arch. The real work is three
infrastructure jobs:

| Job | Effort | Why |
|---|---|---|
| aarch64 package pipeline | The bulk of the work | `pkgs.omarchy.org/stable/$arch` only publishes x86_64. ~15 Omarchy-custom packages (quickshell-git, hyprland-guiutils, aether, tensaku, omarchy itself, …) need aarch64 rebuilds in a repo we host with the same layout. |
| Image builder | A focused weekend | The Pi doesn't boot an archiso ISO. We replace the ISO pipeline with a loopback SD/eMMC image builder: FAT32 firmware partition + root fs, pacstrap from Arch Linux ARM, then run upstream's own `install/` scripts in a chroot. |
| Pi boot/kernel/GPU integration | Small but fiddly | `linux-rpi-16k` + Pi firmware instead of `linux` + limine; Mesa v3d/v3dv (GLES 3.1, Vulkan 1.3) instead of Intel/AMD/NVIDIA. Hyprland and Quickshell (Qt6) are both proven on the Pi 5's VideoCore VII. |

The expected **delta against upstream is near zero**: upstream's hardware
scripts are all gated behind `lspci`/`dmidecode` probes for laptop hardware
that simply won't match on a Pi, so they no-op. Our changes live in this repo
as *additions* (one extra hardware script, a package-list filter, a pacman.conf
override), not edits. See [`patches/README.md`](patches/README.md) for the
zero-patch policy.

## Layout

```
upstream.lock        # pinned basecamp/omarchy quattro commit
build/               # image builder (replaces the x86 ISO pipeline)
  fetch-upstream.sh  #   clone upstream at the pinned ref
  mkimage.sh         #   loopback image: partition, pacstrap, chroot-install
overlay/             # everything we add on top of upstream — no edits
  pacman/            #   pacman.conf for ALARM + our aarch64 [omarchy] repo
  install/           #   package skip/add lists, rpi-cm5 hardware script
  boot/              #   config.txt for the CM5
pkgs/                # aarch64 rebuild pipeline for Omarchy's custom packages
patches/             # ideally stays empty — see its README
docs/feasibility.md  # the full difficulty analysis with sources
```


## Building & flashing

The image is built by CI: **Actions → build-image** (runs on every push that
touches `build/`, `overlay/`, or `upstream.lock`, or via *Run workflow*).
A successful run publishes a GitHub release with:

- `omarchy-cm5.img.xz` — the flashable image (or `…xz.partNN` pieces when it
  exceeds the 2 GiB release-asset limit: `cat *.part* > omarchy-cm5.img.xz`)
- `SHA256SUMS`, the package-resolution build report, and the image
  verification report

Flash it to a USB stick (≥16 GB) with Raspberry Pi Imager / balenaEtcher
(both read `.img.xz` directly), or:

```
xz -dc omarchy-cm5.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

Boot the Pi 5 from the stick. First boot runs the same deferred-provisioning
setup the official ISO arms — username, password, hostname, timezone on
tty1 — then hands off to SDDM. The root partition auto-grows to fill the
stick on first boot.

To build locally instead (needs root, loop devices, and qemu-user binfmt on
x86):

```
build/fetch-upstream.sh
build/resolve-packages.sh
docker run --rm -v "$PWD:/work" archlinux/archlinux:latest bash /work/build/build-any-packages.sh
sudo LOCAL_PKG_DIR=$PWD/build/pkgs-out build/mkimage.sh
sudo build/verify-image.sh build/omarchy-cm5.img
```

## Base system choice

**Arch Linux ARM (aarch64)** with the `linux-rpi-16k` kernel. Omarchy is
Arch-to-the-bone (pacman, yay/AUR, Arch package names everywhere), so staying
on an Arch-family base is what keeps the delta near zero. ALARM's repos carry
`hyprland` for aarch64. The known catch: ALARM's stock Pi boot images have a
rocky history on Pi 5-class hardware, so `mkimage.sh` builds the rootfs from
the ALARM tarball + pacman directly rather than starting from their SD images.
Fallback if ALARM bites: the same overlay on Manjaro ARM (what the community
Pi 5 guide used), at the cost of more package-name drift.

## Provenance

Canonical home: `TensorFleet/omarchy-cm5`. Initially scaffolded in a
session workspace inside `mattkanwisher/cellstation`
(branch `claude/omarchy-quattro-rp-cm5-seobqb`).
