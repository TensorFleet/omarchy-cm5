#!/bin/bash
# Build a small ABL-bootable test image (KERNEL + SYSTEM stub + empty ext4)
# without root/losetup — used to validate the boot contract on a spare card.
#
#   mk-thor-boottest-image.sh --out build/omarchy-thor-boottest.img
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
out=$here/omarchy-thor-boottest.img
while [[ $# -gt 0 ]]; do
  case $1 in
    --out) out=$2; shift 2 ;;
    *) echo "unknown: $1" >&2; exit 2 ;;
  esac
done

vendor_k=$here/../pkgs/aarch64-extra/linux-rocknix-sm8550/vendor
vendor_fw=$here/../pkgs/aarch64-extra/linux-firmware-thor/vendor
[[ -f $vendor_k/KERNEL ]] || { echo "run extract.sh first (missing KERNEL)" >&2; exit 1; }
[[ -d $vendor_fw/stub ]] || { echo "run extract.sh first (missing stub)" >&2; exit 1; }

command -v mformat >/dev/null
command -v mcopy >/dev/null
mke2fs=$(command -v mke2fs || command -v mkfs.ext4 || true)
[[ -n $mke2fs ]] || mke2fs=/opt/homebrew/opt/e2fsprogs/sbin/mke2fs
[[ -x $mke2fs ]] || { echo "need mke2fs/mkfs.ext4" >&2; exit 1; }

stub=$(mktemp)
trap 'rm -f "$stub"' EXIT
bash "$here/mk-thor-system-stub.sh" --vendor "$vendor_fw/stub" --out "$stub"

# 64 MiB FAT + 256 MiB ext4 (enough for KERNEL + stub; not a full Omarchy root)
fat_bytes=$((64 * 1024 * 1024))
ext_bytes=$((256 * 1024 * 1024))
start=2048
fat_secs=$((fat_bytes / 512))
ext_secs=$((ext_bytes / 512))
ext_start=$((start + fat_secs))
img_bytes=$(( (ext_start + ext_secs) * 512 ))

rm -f "$out"
python3 - "$out" "$img_bytes" "$start" "$fat_secs" "$ext_start" "$ext_secs" <<'PY'
import struct, sys, pathlib
path, img_bytes, start, fat_secs, ext_start, ext_secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
img = bytearray(img_bytes)
# MBR, disk id 0x7a055550, two partitions
img[440:444] = struct.pack("<I", 0x7A055550)
def pent(boot, typ, lba, nsec):
    return bytes([boot, 0,0,0, typ, 0,0,0]) + struct.pack("<II", lba, nsec)
# 0x0C FAT32 LBA, 0x83 Linux
img[446:462] = pent(0x80, 0x0C, start, fat_secs)
img[462:478] = pent(0x00, 0x83, ext_start, ext_secs)
img[510] = 0x55
img[511] = 0xAA
pathlib.Path(path).write_bytes(img)
print(f"image {path} {img_bytes} p1 lba={start} n={fat_secs} p2 lba={ext_start} n={ext_secs}")
PY

# FAT at byte offset start*512
fat_off=$((start * 512))
mformat -i "$out@@$fat_off" -F -v ROCKNIX ::
mcopy -i "$out@@$fat_off" "$vendor_k/KERNEL" ::KERNEL
mcopy -i "$out@@$fat_off" "$stub" ::SYSTEM
# md5 sidecars
md5_k=$(md5 -q "$vendor_k/KERNEL" 2>/dev/null || md5sum "$vendor_k/KERNEL" | awk '{print $1}')
md5_s=$(md5 -q "$stub" 2>/dev/null || md5sum "$stub" | awk '{print $1}')
printf '%s  KERNEL\n' "$md5_k" > /tmp/KERNEL.md5
printf '%s  SYSTEM\n' "$md5_s" > /tmp/SYSTEM.md5
mcopy -i "$out@@$fat_off" /tmp/KERNEL.md5 ::KERNEL.md5
mcopy -i "$out@@$fat_off" /tmp/SYSTEM.md5 ::SYSTEM.md5

# ext4 at ext_start — write a filesystem image then splice in
extimg=$(mktemp)
trap 'rm -f "$stub" "$extimg"' EXIT
truncate -s "$ext_bytes" "$extimg"
"$mke2fs" -F -t ext4 -L STORAGE -m 0 "$extimg" >/dev/null
python3 - "$out" "$extimg" "$ext_start" <<'PY'
import sys, pathlib
out, ext, lba = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
data = bytearray(out.read_bytes())
blob = ext.read_bytes()
off = lba * 512
data[off:off+len(blob)] = blob
out.write_bytes(data)
print("spliced ext4", len(blob), "at", off)
PY

echo "boottest image: $out"
mdir -i "$out@@$fat_off" ::
