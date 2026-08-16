# Building omarchy-cm5 locally

Everything CI does, on your own machine. The pipeline is three independent
stages — you can run all of them or just the image build (it pulls whatever
packages already exist in the `aarch64-pkgs` GitHub release):

```
1. build/build-any-packages.sh   omarchy runtime (arch=any) packages
2. pkgs/repack-bin.sh            aarch64 binaries upstream already publishes
   pkgs/build-in-chroot.sh       compiled aarch64 packages (quickshell, tools)
3. build/mkimage.sh              the flashable image
   build/verify-image.sh         35-assertion sanity check
```

## Host requirements

**Best host: any native aarch64 Linux box** — a Pi 5 itself, an ARM server,
an ARM VM (UTM/Parallels on Apple Silicon). Everything runs natively, builds
are 5–10× faster, and the entire class of qemu-emulation landmines below
disappears (`build/mkimage.sh` and `pkgs/build-in-chroot.sh` detect
`uname -m` and skip the qemu path automatically).

**Works fine: any x86_64 Linux with root.** You need the qemu-user
translation layer:

```bash
# Debian/Ubuntu
sudo apt install qemu-user-static arch-install-scripts libarchive-tools \
                 dosfstools parted file
# Arch
sudo pacman -S qemu-user-static qemu-user-static-binfmt arch-install-scripts \
               libarchive dosfstools parted

# verify the binfmt handler is registered (F flag = fix-binary, required):
cat /proc/sys/fs/binfmt_misc/qemu-aarch64   # look for "flags: F" (or PCF)
```

Docker (or podman with an alias) is needed only for stage 1 and
`repack-bin.sh`; on an Arch host you can skip the container and run those
scripts directly.

**Also works: macOS on Apple Silicon via Docker Desktop.** The Docker VM is
a native aarch64 Linux, so this is secretly the best-case host with a
container wrapped around every stage (verified end-to-end 2026-08):

```bash
# stages 1 + 2a: the x86 archlinux container, emulated. pacman 7's seccomp
# sandbox fails under emulation exactly like under qemu-user — disable it:
docker run --rm --platform linux/amd64 -v "$PWD:/work" archlinux/archlinux:latest \
  bash -c "sed -i -e '/^\[options\]/a DisableSandbox' -e '/^DownloadUser/d' /etc/pacman.conf \
           && bash /work/build/build-any-packages.sh"   # same for pkgs/repack-bin.sh

# stages 2b + 3: a native arm64 container with the chroot/loop tooling.
# Chroot and image live in named volumes (the macOS bind mount breaks
# xattrs and loop performance); --privileged -v /dev:/dev makes losetup
# partition nodes appear (the VM's devtmpfs is shared in).
docker build -t omarchy-builder - <<'EOF'
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y \
    arch-install-scripts libarchive-tools dosfstools parted file curl \
    util-linux fdisk e2fsprogs git xz-utils zstd && rm -rf /var/lib/apt/lists/*
EOF
docker run --rm --privileged -v /dev:/dev -v omarchy-chroot:/mnt/omarchy-pkgbuild \
  -v "$PWD:/work" omarchy-builder bash /work/pkgs/build-in-chroot.sh quickshell-git
docker run --rm --privileged -v /dev:/dev -v omarchy-image:/img -v "$PWD:/work" \
  omarchy-builder env IMG=/img/omarchy-cm5.img CACHE_DIR=/img/cache \
    LOCAL_PKG_DIR=/work/build/pkgs-out \
    NODE_TARBALL_PATH=/work/build/node/node-v22.23.2-linux-arm64.tar.gz \
    bash /work/build/mkimage.sh
```

One trap: heavy emulated builds (meson/ninja under `qemu-x86_64`) can hang
with zombie children. Anything `arch=('any')` that has a real build step
(yaru-icon-theme's icon rendering) is better built in the native aarch64
chroot on this host — the output is identical.

Disk: ~25 GB free. The image itself is 12 GB sparse plus a ~6 GB package
cache (kept outside the image; set `CACHE_DIR` to control where).

## Stage 0 — checkout

```bash
git clone https://github.com/TensorFleet/omarchy-cm5 && cd omarchy-cm5
bash build/fetch-upstream.sh        # basecamp/omarchy at the pinned ref (upstream.lock)
bash build/resolve-packages.sh      # ALARM package-name universe + omarchy aarch64 repo probe
```

`resolve-packages.sh` writes `build/resolved/alarm-names.txt` (used by the
package builders) and probes whether `pkgs.omarchy.org` has grown an official
aarch64 repo — if it ever does, `mkimage.sh` will prefer it and stages 1–2
become unnecessary.

## Stage 1 — omarchy runtime packages (fast, ~4 min)

The four core packages (`omarchy`, `omarchy-settings`, `omarchy-nvim`,
`omarchy-keyring`) are `arch=('any')` — pure config/script content — so any
architecture can package them. Output lands in `build/pkgs-out/`:

```bash
docker run --rm -v "$PWD:/work" archlinux/archlinux:latest \
  bash /work/build/build-any-packages.sh
```

This also builds the `any` font/tool packages ALARM lacks and generates
`omarchy-cm5-shims` (an empty `provides=` package) for any hard dependency
that has no aarch64 build — each shimmed name is listed in
`build/pkgs-out/SHIMMED.txt`. Keep that list honest: it should only ever
contain the limine bootloader stack (structurally unused on Pi-firmware
boot).

## Stage 2 — compiled aarch64 packages

### 2a. Repacks (fast, ~1 min)

Upstream publishes real aarch64 binaries for these; we only re-wrap them as
pacman packages:

```bash
docker run --rm -v "$PWD:/work" archlinux/archlinux:latest \
  bash /work/pkgs/repack-bin.sh
# → omarchy-chromium-bin (their patched Chromium), aether, localsend-bin
```

### 2b. Real compiles (slow under qemu, fast native)

```bash
sudo pkgs/build-in-chroot.sh quickshell-git                       # the big one
sudo pkgs/build-in-chroot.sh cliamp herdr ttfx omacalc omacut omawrite tzupdate yay
```

Bootstraps a throwaway Arch Linux ARM chroot (`CHROOT=/mnt/omarchy-pkgbuild`
by default, reused across invocations) and runs `makepkg` per package.
Observed timings: quickshell-git ≈ **2 h 40 m** on a 4-core x86 runner under
qemu; expect ≈ 15–25 min native on a Pi 5. The small tools are minutes each.

`tzupdate` moved here from stage 1: omarchy-pkgs rewrote it in Rust, so it
needs a real aarch64 compile (its PKGBUILD says `arch=('x86_64')` only by
omission; the script builds with `makepkg -A` and stamps aarch64). `yay` is
a nice-to-have AUR helper on-device. Formerly-suggested `mise` and the
`nvim` wrapper no longer exist in omarchy-pkgs; `localsend` gained a source
PKGBUILD upstream, but it's a heavy Flutter build — the `localsend-bin`
repack covers it.

## Stage 3 — the image

```bash
sudo env \
  IMG=$PWD/build/omarchy-cm5.img \
  IMG_SIZE=12G \
  CACHE_DIR=$PWD/build/cache \
  LOCAL_PKG_DIR=$PWD/build/pkgs-out \
  NODE_TARBALL_PATH=$PWD/build/node/node-v22.23.2-linux-arm64.tar.gz \
  bash build/mkimage.sh

sudo bash build/verify-image.sh build/omarchy-cm5.img   # must end "hard failures: 0"
```

Grab the node tarball first (any current LTS arm64 build):

```bash
mkdir -p build/node && curl -fLO --output-dir build/node \
  "https://nodejs.org/dist/latest-v22.x/$(curl -fsSL https://nodejs.org/dist/latest-v22.x/ | grep -o 'node-v[0-9.]*-linux-arm64\.tar\.gz' | head -1)"
```

It's stashed in the image so first-boot user finalization works offline
(upstream's `mise-work.sh` globs a `linux-x64` name — the builder stages the
arm64 tarball under both names deliberately; the content is arm64).

What mkimage produces: MBR image, 512 MB FAT32 boot partition + ext4 root,
fixed disk id `0x2ca5b007` so `cmdline.txt` can hardcode
`root=PARTUUID=2ca5b007-02` (no initramfs dependency for root discovery —
though an initramfs is generated for plymouth). First boot runs
`omarchy-provision-owner` on tty1 (username/password/hostname/timezone — the
official ISO's deferred-provisioning flow), and a one-shot service grows the
root partition to fill the drive.

### Flash

```bash
xz -T0 -6 build/omarchy-cm5.img          # optional, for storage/transfer
# Raspberry Pi Imager / balenaEtcher flash the .img or .img.xz directly, or:
sudo dd if=build/omarchy-cm5.img of=/dev/sdX bs=4M status=progress conv=fsync
```

16 GB stick minimum. Boot the Pi 5 with no SD card inserted; USB boot is in
the default EEPROM boot order.

## Landmines already defused (don't re-discover these)

All of these are handled in the scripts; listed so you know why the odd-looking
code exists — and which problems vanish on a native aarch64 builder (†):

| Symptom | Cause | Where handled |
|---|---|---|
| † `pacman: Landlock is not supported by the kernel` | qemu-user implements no Landlock syscalls; pacman 7 treats that as fatal | `DisableSandbox` in `overlay/pacman/pacman-cm5.conf` (kept on-device too — Pi kernels don't always enable Landlock) and sed'ed into the build chroot |
| † `sudo: effective uid is not 0` during `makepkg -s` | setuid escalation doesn't work under qemu-user | `build-in-chroot.sh` installs deps as root from `--printsrcinfo`, then `makepkg -d` |
| `could not determine cachedir mount point` / bogus "not enough free disk space" | plain-directory chroot isn't a mountpoint, breaking `CheckSpace` | self bind-mount + `CheckSpace` commented in the build chroot |
| Built package "disappears" | ALARM's `makepkg.conf` uses `PKGEXT=.pkg.tar.xz`, not `.zst` | all harvest globs are `*.pkg.tar.*` |
| Image builds but Pi shows rainbow/no boot | ALARM has shipped the Pi 5 kernel as `kernel_2712.img` *or* `kernel8.img` at different times; a stale `kernel=` line in config.txt = no boot | `mkimage.sh` points `kernel=` at the file actually installed; `verify-image.sh` asserts it exists |
| `mkinitcpio` errors: `btrfs-overlayfs` hook / `thunderbolt` module not found | omarchy-settings ships x86/limine-flavored drop-ins | removed/neutralized before initramfs generation |
| `snapper.sh` and `firewall.sh` stage failures in the log | snapper needs btrfs (image is ext4); ufw can't probe iptables in chroot | tolerated by design; verify-image checks what actually matters. `sudo ufw enable` once on the Pi if you want the firewall |
| Chromium/LocalSend missing | base list says `chromium`/`localsend`; neither name exists on ALARM | image substitutes `omarchy-chromium-bin` / `localsend-bin` (real aarch64 upstream builds, repacked by `pkgs/repack-bin.sh`) when present in the pool |
| † `error restricting syscalls via seccomp: 22` from pacman in a Docker x86 container on Apple Silicon | pacman 7's own seccomp sandbox fails under Rosetta/qemu-x86_64, same family as the Landlock failure | sed `DisableSandbox` into the container's pacman.conf before running the stage scripts (see macOS section) |
| † Emulated x86 container build hangs forever, zombie `meson` under `ninja` | qemu-x86_64 user emulation loses track of children on heavy parallel builds | build `any` packages that have real build steps in the native aarch64 chroot instead |
| `missing tool: sfdisk` on a Debian/Ubuntu builder | Ubuntu splits sfdisk out of util-linux | `apt install fdisk` |
| `ERROR: <pkg> is not available for the 'aarch64' architecture` | PKGBUILD declares `arch=('x86_64')` only by omission (tzupdate) | `build-in-chroot.sh` builds with `makepkg -A`; package is stamped with the real CARCH |
| One missing dep name aborts a whole chroot build (`target not found: gtk-engine-murrine`) | bulk `pacman -S` is all-or-nothing; some makedepends don't exist on ALARM | `build-in-chroot.sh` falls back to per-dep install and lets `makepkg -d` decide what's truly fatal |
| Pi boots to plymouth splash, Esc shows `Timed out waiting for /dev/loopXp1` → `Dependency failed for /boot` / failed swap | `genfstab -U` inside a build container has no blkid data — it writes the build host's loop device paths and copies the host's active swap into the image fstab | `mkimage.sh` writes fstab by hand from the deterministic PARTUUIDs; `verify-image.sh` hard-fails on `/dev/loop` or swap in fstab |
| `ERROR: Failed to open encryption mapping … not a LUKS volume` at boot | omarchy-settings' mkinitcpio drop-ins include the `encrypt` hook (upstream root is LUKS; ours is plain ext4) | non-fatal, but `mkimage.sh` seds the encrypt hooks out before initramfs generation |
| First boot detours through emergency mode ("root account is locked … Press Enter to continue"), then provisioning runs normally; later boots clean | grow-root ran `Before=sysinit.target` and rewrote the partition table (sfdisk + `partx -u`) while /boot was still being fsck'd/mounted | grow-root is now an ordinary `After=local-fs.target` service; online resize2fs doesn't need to run early |
| Plymouth splash renders as a white field with scattered pixel clusters until KMS takes over | Pi firmware hands the kernel a 16-bit RGB565 simplefb (`format=r5g6b5` in dmesg); plymouth mis-renders its dark theme into it during the ~1s before vc4 binds | `framebuffer_depth=32` in overlay config.txt |
| First-login updater: `error: target not found: voxtype-bin` | upstream added voxtype to the base set; voxtype only publishes x86_64 binaries — no arm64 release exists to repack | expected, harmless; revisit if voxtype ships arm64 |
| zig builds in a container chroot: `unable to discover remote git server capabilities: ResolvConfParseFailed` | zig's builtin git client parses /etc/resolv.conf itself and chokes on Docker's entries (curl is unaffected — glibc resolver) | write a plain `nameserver 1.1.1.1` resolv.conf in the outer container before arch-chroot |
| ghostty build: `package not found at …/p/uucode-0.2.0-…` after a "Failed to fetch git+…" | upstream dependency repo drifted; the pinned commit now hashes as a different version, and the mirror fallback didn't populate the cache | `zig fetch https://deps.files.ghostty.org/<name-version-hash>.tar.gz` into the build's ZIG_GLOBAL_CACHE_DIR, then re-run makepkg |

## CI equivalents

- **Actions → build-image** (`.github/workflows/build-image.yml`): stages 0,
  1, 3 + release upload. Runs on every push touching `build/`, `overlay/`,
  or `upstream.lock`.
- **Actions → build-arm-packages**: stage 2, publishing into the rolling
  `aarch64-pkgs` release that both CI and your local `mkimage.sh` can pull
  from (`gh release download aarch64-pkgs -p '*.pkg.tar.*' -D build/pkgs-out`).
  Its final `publish-db` job runs `pkgs/publish-repo.sh` (repo-add over the
  whole pool + db upload), which makes the release a **servable pacman
  repo** — deployed devices carry it as their `[omarchy]` repo:

  ```
  [omarchy]
  SigLevel = Optional TrustAll
  Server = https://github.com/TensorFleet/omarchy-cm5/releases/download/aarch64-pkgs
  ```

  `mkimage.sh` points the image's pacman.conf there at finalize (and drops
  the baked-in /opt/omarchy-repo pool, ~450 MB). Run `pkgs/publish-repo.sh`
  locally after a local package build to push your pool to the same repo.

Packages whose omarchy-pkgs PKGBUILD is x86-only even though upstream ships
arm64 binaries get their own PKGBUILD under `pkgs/aarch64-extra/` (currently
`voxtype-bin` — upstream publishes signed `-linux-aarch64-cpu`/`-onnx`
builds); `repack-bin.sh` builds those alongside the omarchy-pkgs repacks.

A known-good verified image already exists:
**github.com/TensorFleet/omarchy-cm5/releases/tag/build-6** (all 35 checks
passed; built before quickshell-git/cliamp finished compiling, so the bar
runs on ALARM's stock `quickshell` — functionally the same shell).
