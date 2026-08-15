# Build log: first full local build on macOS, first boot on hardware (2026-08)

This is the narrative record of the first end-to-end local run of the
omarchy-cm5 pipeline on a Mac — every stage, every failure, and the fixes
that came out of it. The distilled operational knowledge lives in
[local-build.md](local-build.md); this file is the *why* behind those
commits (`8077ea2`, `bba4cae`, `8175d94`).

## Motivation

CI (GitHub x86 runners + qemu-user) builds quickshell-git in **2 h 40 m**.
The goal was a local pipeline fast enough to iterate on — and it turned out
the Mac was hiding the best-case host all along: **Docker Desktop's VM on
Apple Silicon is a native aarch64 Linux**. Six cores, no emulation for the
ARM work. The entire class of qemu landmines documented in local-build.md
simply doesn't apply.

## Timeline and timings

| Stage | Where it ran | Time | Notes |
|---|---|---|---|
| 0 — fetch + resolve | macOS host directly | ~1 min | git/curl/bsdtar only |
| 1 — arch=any packages | `archlinux/archlinux` under Rosetta/qemu | ~15 min | needed pacman `DisableSandbox` |
| 2a — binary repacks | same container | ~5 min | chromium download dominates |
| 2b — compiled aarch64 | **native** ALARM chroot in privileged arm64 container | **~8 min for quickshell-git** | vs 2 h 40 m in CI |
| 3 — image + verify | privileged arm64 Ubuntu container, loop devices | ~25 min first run, ~12 min warm-cache | |
| flash | `dd \| authopen` to `/dev/rdiskN` | ~24 min | stick sustains ~9 MB/s |

## What broke, in order

### 1. pacman 7's seccomp sandbox fails under Docker's x86 emulation

First `docker run --platform linux/amd64 archlinux/archlinux` died with
`error restricting syscalls via seccomp: 22`. Same family as the Landlock
landmine: pacman's own sandbox can't set up under Rosetta/qemu-x86_64.
Fix: sed `DisableSandbox` into the container's pacman.conf before running
any stage script. (CI on real x86 never sees this.)

### 2. omarchy-pkgs had drifted under the scripts

- `mise` and the `nvim` wrapper no longer exist as PKGBUILDs.
- **tzupdate was rewritten in Rust.** Stage 1 used to sed its arch to
  `'any'` and build it in the x86 container — which would now bake an x86
  binary into an "any" package. Moved to the aarch64 chroot, built with
  `makepkg -A` (its PKGBUILD declares `x86_64` only by omission).
- `yaru-icon-theme` / `xdg-terminal-exec` needed build tools the stage 1
  container never installed (`meson`, `sassc`, `scdoc`), and yaru's
  makedepends name two packages ALARM doesn't have at all
  (`gtk-engine-murrine`, `yaru-gnome-shell-theme`) — the bulk
  `pacman -S` was all-or-nothing, so the chroot build now falls back to
  per-dep install and lets `makepkg -d` decide what's actually fatal.

### 3. qemu-x86_64 hangs on heavy emulated builds

yaru's meson/ninja icon render (2000+ targets) wedged under emulation:
ninja alive at 0 % CPU with a zombie `[meson] <defunct>` child. Not a
build bug — a qemu-user process-management artifact. Anything
`arch=('any')` with a real build step gets built in the native chroot on
this host instead; the output is identical.

### 4. Ubuntu splits sfdisk into `fdisk`

The arm64 builder container (Ubuntu 24.04 + arch-install-scripts) was
missing `sfdisk` despite util-linux being installed. One-line Dockerfile
fix, now a landmine-table row.

### 5. THE BOOT KILLER: genfstab leaked build-host loop devices

The image verified "0 hard failures", flashed, and did not boot: plymouth
splash forever, and behind Esc:

```
[ TIME ] Timed out waiting for device /dev/loop1p1.
[DEPEND] Dependency failed for /boot.
[DEPEND] Dependency failed for Local File Systems.
[FAILED] Failed to activate swap /swap.
ERROR: Failed to open encryption mapping: ... is not a LUKS volume ...
```

Three separate findings in one screen:

- `genfstab -U` **inside the build container has no blkid data** and falls
  back to raw device paths — it wrote the *build machine's* `/dev/loop1p1`
  as the `/boot` mount source. That device can never exist on the Pi.
- genfstab also copied the **Docker VM's active swapfile** into fstab.
- omarchy-settings' mkinitcpio drop-ins carry the `encrypt` hook (upstream
  root is LUKS; ours is ext4) — non-fatal, but scary in the log.

And the trap on top: root is locked and no user exists before first-boot
provisioning, so the emergency shell is unreachable — the stick cannot be
repaired on-device. Rebuild + reflash was the only path.

Fixes (`bba4cae`): mkimage writes fstab **by hand** from the deterministic
PARTUUIDs (`2ca5b007-01`/`-02`) — genfstab is gone entirely; verify-image
now **hard-fails** on any `/dev/loop` or swap entry in fstab (the old
check only asserted entries existed, which is how this passed); the
encrypt hooks are sed'ed out before initramfs generation.

Lesson: **a verifier that only checks presence will happily bless
garbage.** Every failure a boot log shows you is a candidate for a new
hard assertion.

### 6. grow-root raced the /boot mount into emergency mode

Second flash booted — through a weird detour: emergency mode banner,
"root account is locked … Press Enter to continue", then the full
provisioning flow ran normally. The journal made it precise:

```
19:26:13 grow-root: Re-reading the partition table failed.: Device or resource busy
19:26:16 grow-root: root filesystem grown to 57.2G
19:26:18 systemd: dev-disk-by-partuuid-2ca5b007-01.device … unit isn't active
19:26:18 systemd: boot.mount: Job boot.mount/start failed with result 'dependency'
19:26:18 systemd: Reached target Emergency Mode.
```

The unit ran with `DefaultDependencies=no` / `Before=sysinit.target`, so
its sfdisk + `partx -u` partition-table rewrite churned the partition
device units at the exact moment systemd was fsck'ing/mounting `/boot`.
With root locked, sulogin degrades to "press Enter", which *resumes
normal boot* — hence "broken then it did the full installer".

Fix (`8175d94`): grow-root is an ordinary service `After=local-fs.target`.
Online resize2fs is fine on the mounted root at any point; nothing needs
the grown filesystem in early boot. First-boot-only race — flashed sticks
that already grew are unaffected.

## macOS-specific machinery worth keeping

- **Flashing without sudo:** `dd if=img bs=4M | /usr/libexec/authopen -w
  /dev/rdiskN` — authopen pops the native macOS authorization dialog and
  writes stdin to the device. No sudoers changes.
- **Pre-authorized flashing:** gate the write on a marker file —
  `{ until test -f MARKER; do sleep 10; done; dd ...; } | authopen -w ...`
  — the auth dialog appears at pipeline *start*, the user approves once
  and walks away, and the write begins whenever the image verifies. On
  failure, kill the job; nothing is written.
- **Progress:** `dd`'s file offset lies once the pipe is primed; the truth
  is authopen's own write offset on the raw device
  (`lsof -o -p <authopen-pid>`).
- Chroot and image live in **named volumes** (`omarchy-chroot`,
  `omarchy-image`) — the macOS bind mount breaks xattrs and loop
  performance. The bind mount is only for the repo and the harvested
  packages.

## End state

- Image verified with the hardened checks, flashed, and **booted to a
  fully provisioned desktop** — omarchy 4.0.0rc5-1 on `6.18.44-1-rpi-16k`,
  zero failed units, root grown to 57.2 G, confirmed over SSH.
- LocalSend present via the `localsend-bin` substitution (same mechanism
  as chromium).
- Remaining benign log noise on the CM5 IO board: `brcm-pcie link down`
  (empty PCIe slot), wpa_supplicant nl80211 capability notices, one-time
  gnome-keyring unlock complaint at first login.
