#!/bin/bash
# Repack the omarchy packages whose upstreams already publish aarch64
# binaries — no compilation, just packaging. Runs inside an
# archlinux/archlinux container (x86 is fine: package() only copies files):
#
#   docker run --rm -v "$repo:/work" archlinux/archlinux:latest \
#     bash /work/pkgs/repack-bin.sh
#
# CARCH is switched to aarch64 via makepkg.conf so makepkg selects each
# PKGBUILD's source_aarch64 array and stamps the package arch correctly.
set -euo pipefail

WORK=${WORK:-/work}
OUT=$WORK/build/pkgs-out
mkdir -p "$OUT"

# omarchy-chromium-bin: omacom publishes real aarch64 chromium builds.
# aether: upstream releases ship linux-arm64.
# localsend-bin: upstream releases ship linux-arm-64 debs.
PACKAGES=(omarchy-chromium-bin aether localsend-bin)

pacman -Syu --noconfirm --needed base-devel git sudo >/dev/null
useradd -m builder 2>/dev/null || true
echo 'builder ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/builder

sed -i 's/^CARCH=.*/CARCH="aarch64"/; s/^CHOST=.*/CHOST="aarch64-unknown-linux-gnu"/' /etc/makepkg.conf

build_dir=/home/builder/build
sudo -u builder mkdir -p "$build_dir"
git clone --depth 1 https://github.com/omacom-io/omarchy-pkgs "$build_dir/omarchy-pkgs"
chown -R builder "$build_dir"

: >"$OUT/REPACKED.txt"
for pkg in "${PACKAGES[@]}"; do
  dir=$build_dir/omarchy-pkgs/pkgbuilds/$pkg
  [[ -d $dir ]] || { echo "FAILED: $pkg (no PKGBUILD)" >>"$OUT/REPACKED.txt"; continue; }
  if (cd "$dir" && sudo -u builder makepkg -d -f --ignorearch --skipchecksums --skippgpcheck --noconfirm); then
    cp "$dir"/*-aarch64.pkg.tar.zst "$OUT/" 2>/dev/null || cp "$dir"/*.pkg.tar.zst "$OUT/"
    echo "$pkg" >>"$OUT/REPACKED.txt"
  else
    echo "FAILED: $pkg" >>"$OUT/REPACKED.txt"
  fi
done

cat "$OUT/REPACKED.txt"
ls -la "$OUT"
