#!/bin/bash
# Build compiled omarchy packages for aarch64 in an Arch Linux ARM chroot
# (qemu-user emulated when the host is x86). Slow but faithful: makepkg -s
# resolves each PKGBUILD's makedepends against real ALARM packages.
#
#   sudo pkgs/build-in-chroot.sh quickshell-git
#   sudo pkgs/build-in-chroot.sh cliamp herdr ttfx omacalc omacut omawrite
#
# Output: build/pkgs-out/*.pkg.tar.zst (+ CHROOT-BUILT.txt)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${OUT:-$here/../build/pkgs-out}
CHROOT=${CHROOT:-/mnt/omarchy-pkgbuild}
mkdir -p "$OUT"

(($#)) || { echo "usage: build-in-chroot.sh <pkg> [pkg…]" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
if [[ $(uname -m) != aarch64 ]]; then
  [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] ||
    { echo "install qemu-user-static (binfmt qemu-aarch64)" >&2; exit 1; }
fi

ALARM_MIRRORS=(
  http://os.archlinuxarm.org
  http://fl.us.mirror.archlinuxarm.org
  http://de3.mirror.archlinuxarm.org
)

# --- bootstrap chroot (idempotent: reuse if already set up this run) --------
if [[ ! -x $CHROOT/usr/bin/bash ]]; then
  mkdir -p "$CHROOT"
  ok=0
  for m in "${ALARM_MIRRORS[@]}"; do
    echo "fetching ALARM rootfs from $m …" >&2
    if curl -fL --retry 2 "$m/os/ArchLinuxARM-aarch64-latest.tar.gz" | bsdtar -xpf - -C "$CHROOT"; then ok=1; break; fi
  done
  ((ok)) || { echo "could not fetch ALARM rootfs" >&2; exit 1; }
fi
if [[ $(uname -m) != aarch64 ]] && command -v qemu-aarch64-static >/dev/null; then
  install -Dm755 "$(command -v qemu-aarch64-static)" "$CHROOT/usr/bin/qemu-aarch64-static"
fi

# A plain-directory chroot is not a mountpoint, which breaks pacman's
# CheckSpace ("could not determine cachedir mount point"). Bind-mount the
# chroot onto itself and drop CheckSpace for belt and braces.
if ! mountpoint -q "$CHROOT"; then
  mount --bind "$CHROOT" "$CHROOT"
fi
sed -i 's/^CheckSpace/#CheckSpace/' "$CHROOT/etc/pacman.conf"

run() { arch-chroot "$CHROOT" "$@"; }

# pacman 7's Landlock sandbox / alpm download user both fail under
# qemu-user emulation — disable them in the chroot.
if ! grep -q '^DisableSandbox' "$CHROOT/etc/pacman.conf"; then
  sed -i -e '/^\[options\]/a DisableSandbox' -e '/^DownloadUser/d' "$CHROOT/etc/pacman.conf"
fi

if ! run id builder &>/dev/null; then
  run pacman-key --init
  run pacman-key --populate archlinuxarm
  run pacman -Syu --noconfirm
  run pacman -S --noconfirm --needed base-devel git sudo
  run useradd -m builder
  echo 'builder ALL=(ALL) NOPASSWD: ALL' >"$CHROOT/etc/sudoers.d/builder"
  # makepkg refuses running as root; builds run as builder via chroot su.
  run sudo -u builder git clone --depth 1 https://github.com/omacom-io/omarchy-pkgs /home/builder/omarchy-pkgs
fi

# --- build each requested package -------------------------------------------
# makepkg -s escalates via sudo, whose setuid bit does not work under
# qemu-user emulation ("sudo: effective uid is not 0"). Instead: read the
# PKGBUILD's dependency lists via --printsrcinfo, install them as root
# (root pacman needs no setuid), then build with makepkg -d.
touch "$OUT/CHROOT-BUILT.txt"
for pkg in "$@"; do
  echo "=== building $pkg (qemu chroot) ===" >&2
  if [[ ! -d $CHROOT/home/builder/omarchy-pkgs/pkgbuilds/$pkg ]]; then
    echo "FAILED: $pkg (no PKGBUILD)" >>"$OUT/CHROOT-BUILT.txt"; continue
  fi
  mapfile -t deps < <(
    run sudo -u builder bash -c "cd /home/builder/omarchy-pkgs/pkgbuilds/$pkg && makepkg --printsrcinfo 2>/dev/null" |
      awk -F' = ' '$1 ~ /^\t(make|check)?depends(_aarch64)?$/ { sub(/[<>=].*/, "", $2); print $2 }' | sort -u
  )
  if ((${#deps[@]})); then
    echo "deps: ${deps[*]}" >&2
    run pacman -S --noconfirm --needed --ask 4 "${deps[@]}" ||
      { echo "FAILED: $pkg (deps)" >>"$OUT/CHROOT-BUILT.txt"; continue; }
  fi
  if run sudo -u builder bash -c "cd /home/builder/omarchy-pkgs/pkgbuilds/$pkg && makepkg -d -f --noconfirm --skipchecksums --skippgpcheck"; then
    cp "$CHROOT/home/builder/omarchy-pkgs/pkgbuilds/$pkg"/*.pkg.tar.zst "$OUT/"
    echo "$pkg" >>"$OUT/CHROOT-BUILT.txt"
  else
    echo "FAILED: $pkg" >>"$OUT/CHROOT-BUILT.txt"
  fi
done

cat "$OUT/CHROOT-BUILT.txt"
ls -la "$OUT"
