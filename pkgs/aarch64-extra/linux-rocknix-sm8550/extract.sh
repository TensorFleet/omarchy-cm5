#!/bin/bash
# Populate vendor/ for linux-rocknix-sm8550 + linux-firmware-thor from a
# ROCKNIX FAT SYSTEM image, a squashfs, or a previously extracted tree.
#
#   extract.sh --from-system /path/SYSTEM
#   extract.sh --from-fat    /path/rocknix-p1-system.img
#   extract.sh --from-tree   /path/from-system
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fw_pkg=$here/../linux-firmware-thor
mode="" src=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --from-system|--from-fat|--from-tree) mode=${1#--from-}; src=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n $mode && -n $src ]] || { echo "usage: $0 --from-{system,fat,tree} PATH" >&2; exit 2; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tree=""
case $mode in
  fat)
    command -v mcopy >/dev/null || { echo "need mtools mcopy" >&2; exit 1; }
    mcopy -n -i "$src" ::/SYSTEM "$work/SYSTEM"
    mcopy -n -i "$src" ::/KERNEL "$work/KERNEL"
    src=$work/SYSTEM
    mode=system
    ;;
esac
if [[ $mode == system ]]; then
  command -v unsquashfs >/dev/null || { echo "need unsquashfs" >&2; exit 1; }
  unsquashfs -f -d "$work/tree" "$src" \
    usr/lib/kernel-overlays/base/lib/modules/7.1.2 \
    usr/lib/kernel-overlays/base/lib/firmware \
    usr/share/alsa/ucm2/AYN \
    usr/share/alsa/ucm2/conf.d/sm8550 \
    usr/bin/busybox \
    usr/lib/ld-linux-aarch64.so.1 \
    usr/lib/libc.so.6
  tree=$work/tree
else
  tree=$src
fi

kmod=$here/vendor
fw=$fw_pkg/vendor
rm -rf "$kmod" "$fw"
mkdir -p "$kmod/modules" "$fw/firmware" "$fw/alsa" "$fw/stub"

base=$tree/usr/lib/kernel-overlays/base
cp -a "$base/lib/modules/7.1.2" "$kmod/modules/"
# KERNEL: from fat extract, or sibling
if [[ -f $work/KERNEL ]]; then
  cp -a "$work/KERNEL" "$kmod/KERNEL"
elif [[ -f ${THOR_KERNEL:-} ]]; then
  cp -a "$THOR_KERNEL" "$kmod/KERNEL"
fi

# Whole ROCKNIX overlay firmware tree. Do not cherry-pick blobs — every
# "Direct firmware load ... -2" so far was a file this subset skipped.
# Other SM8550 handhelds (Ayaneo / Odin 2) stay out; Thor does not load them.
mkdir -p "$fw/firmware"
cp -a "$base/lib/firmware/." "$fw/firmware/"
rm -rf "$fw/firmware/qcom/sm8550/ayaneo" \
  "$fw/firmware/qcom/sm8550/ayn/odin2" \
  "$fw/firmware/qcom/sm8550/ayn/odin2mini" \
  "$fw/firmware/qcom/sm8550/ayn/odin2portal"
# Follow topology symlinks so a FAT copy does not lose AYN-Thor-tplg.bin.
if [[ -L $fw/firmware/qcom/sm8550/AYN-Thor-tplg.bin ]]; then
  cp -L "$fw/firmware/qcom/sm8550/AYN-Thor-tplg.bin" "$fw/firmware/qcom/sm8550/AYN-Thor-tplg.bin.real"
  mv "$fw/firmware/qcom/sm8550/AYN-Thor-tplg.bin.real" "$fw/firmware/qcom/sm8550/AYN-Thor-tplg.bin"
fi
[[ -d $tree/usr/share/alsa/ucm2 ]] && cp -a "$tree/usr/share/alsa/ucm2" "$fw/alsa/"

# stub runtime (busybox + libc) lives with the firmware vendor tree
mkdir -p "$fw/stub/usr/bin" "$fw/stub/usr/lib"
cp -a "$tree/usr/bin/busybox" "$fw/stub/usr/bin/"
cp -a "$tree/usr/lib/ld-linux-aarch64.so.1" "$fw/stub/usr/lib/"
cp -a "$tree/usr/lib/libc.so.6" "$fw/stub/usr/lib/"

# tarballs the PKGBUILDs expect
if command -v zstd >/dev/null; then
  tar -C "$kmod" -cf - . | zstd -q -o "$here/vendor.tar.zst"
  tar -C "$fw" -cf - . | zstd -q -o "$fw_pkg/vendor.tar.zst"
else
  tar -C "$kmod" -cJf "$here/vendor.tar.xz" .
  tar -C "$fw" -cJf "$fw_pkg/vendor.tar.xz" .
  echo "note: zstd missing; wrote .tar.xz (PKGBUILD expects vendor.tar.zst)" >&2
fi

echo "linux-rocknix-sm8550 vendor: $kmod"
echo "linux-firmware-thor vendor:  $fw"
du -sh "$kmod" "$fw"
