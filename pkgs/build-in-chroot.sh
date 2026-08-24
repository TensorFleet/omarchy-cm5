#!/bin/bash
# Build compiled omarchy packages for aarch64 in an Arch Linux ARM chroot
# (qemu-user emulated when the host is x86). Slow but faithful: makepkg -s
# resolves each PKGBUILD's makedepends against real ALARM packages.
#
#   sudo pkgs/build-in-chroot.sh quickshell-git
#   sudo pkgs/build-in-chroot.sh cliamp herdr ttfx omacalc omacut omawrite
#
# Package sources are resolved from this repository's aarch64-extra directory
# first, then from omarchy-pkgs. Output: build/pkgs-out/*.pkg.tar.*.
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

# A freshly extracted ALARM rootfs has no initialized signing keyring.  It must
# exist before the first upgrade, otherwise pacman downloads hundreds of MB and
# then fails with "required key missing from keyring".
if [[ ! -s $CHROOT/etc/pacman.d/gnupg/pubring.gpg ]]; then
  run pacman-key --init
  run pacman-key --populate archlinuxarm
fi

# Always bring a reused build chroot current before compiling.  This is
# especially important for quickshell: it links Qt private APIs, whose ABI may
# change even in a patch release.  A quickshell built against (for example)
# Qt 6.11.1 will install alongside 6.11.2 but fail at runtime with an undefined
# Qt_6_PRIVATE_API symbol.
run pacman -Syu --noconfirm

if ! run id builder &>/dev/null; then
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
: >"$OUT/CHROOT-BUILT.txt"
for pkg in "$@"; do
  echo "=== building $pkg (qemu chroot) ===" >&2
  builddir=/home/builder/omarchy-pkgs/pkgbuilds/$pkg
  if [[ -d $here/aarch64-extra/$pkg ]]; then
    rm -rf "$CHROOT/home/builder/local-pkgbuilds/$pkg"
    mkdir -p "$CHROOT/home/builder/local-pkgbuilds"
    cp -a "$here/aarch64-extra/$pkg" "$CHROOT/home/builder/local-pkgbuilds/$pkg"
    run chown -R builder:builder "/home/builder/local-pkgbuilds/$pkg"
    builddir=/home/builder/local-pkgbuilds/$pkg
  fi
  if [[ ! -d $CHROOT$builddir ]]; then
    echo "FAILED: $pkg (no PKGBUILD)" >>"$OUT/CHROOT-BUILT.txt"; continue
  fi
  mapfile -t deps < <(
    run sudo -u builder bash -c "cd '$builddir' && makepkg --printsrcinfo 2>/dev/null" |
      awk -F' = ' '$1 ~ /^\t(make|check)?depends(_aarch64)?$/ { sub(/[<>=].*/, "", $2); print $2 }' | sort -u
  )
  if ((${#deps[@]})); then
    echo "deps: ${deps[*]}" >&2
    # Bulk install first; on failure fall back to per-dep so one name ALARM
    # lacks (e.g. yaru's gtk-engine-murrine) doesn't sink the whole build —
    # makepkg -d skips dep checks, so a truly-needed miss fails the build itself.
    if ! run pacman -S --noconfirm --needed --ask 4 "${deps[@]}"; then
      for d in "${deps[@]}"; do
        run pacman -S --noconfirm --needed --ask 4 "$d" ||
          echo "  dep unavailable on ALARM, continuing: $d" >&2
      done
    fi
  fi
  # Quickshell links Qt private symbols, but its upstream VCS package version
  # does not change when ALARM updates Qt. Encode the build Qt ABI in pkgrel so
  # the rolling release can retain/refer to a rebuilt package instead of
  # silently keeping an incompatible same-named asset.
  if [[ $pkg == quickshell-git ]]; then
    qt_version=$(run pacman -Q qt6-base | awk '{print $2}')
    qt_core=${qt_version%%-*}
    IFS=. read -r qt_major qt_minor qt_patch <<<"$qt_core"
    [[ $qt_major =~ ^[0-9]+$ && $qt_minor =~ ^[0-9]+$ && $qt_patch =~ ^[0-9]+$ ]] || {
      echo "could not derive Quickshell pkgrel from Qt version: $qt_version" >&2
      exit 1
    }
    printf -v qt_abi_rel '%d%03d%03d' "$qt_major" "$qt_minor" "$qt_patch"
    run sudo -u builder sed -i -E \
      "s/^pkgrel=.*/pkgrel=1.$qt_abi_rel/" "$builddir/PKGBUILD"
    echo "quickshell Qt ABI: $qt_version (pkgrel 1.$qt_abi_rel)" >&2
  fi
  # -A: some PKGBUILDs declare arch=('x86_64') only by omission (tzupdate);
  # makepkg still stamps the built package with the real CARCH (aarch64).
  if run sudo -u builder bash -c "cd '$builddir' && makepkg -d -f -A --noconfirm --skippgpcheck"; then
    cp "$CHROOT$builddir"/*.pkg.tar.* "$OUT/" || { echo "FAILED: $pkg (harvest)" >>"$OUT/CHROOT-BUILT.txt"; continue; }
    echo "$pkg" >>"$OUT/CHROOT-BUILT.txt"
  else
    echo "FAILED: $pkg" >>"$OUT/CHROOT-BUILT.txt"
  fi
done

cat "$OUT/CHROOT-BUILT.txt"
ls -la "$OUT"
