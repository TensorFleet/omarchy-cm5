#!/bin/bash
# First-boot: grow partition 2 (root) to fill the boot medium, then grow the
# ext4 filesystem. The image is built at a fixed size; the USB stick or eMMC
# it is written to is almost always bigger. Uses only util-linux + e2fsprogs.
# Self-disarms via the systemd unit's ConditionPathExists flag file.
set -euo pipefail

FLAG=/var/lib/omarchy-cm5/root-grown
mkdir -p "$(dirname "$FLAG")"

rootsrc=$(findmnt -no SOURCE /) # e.g. /dev/sda2, /dev/mmcblk0p2, /dev/nvme0n1p2
case $rootsrc in
  *[0-9]p2) disk=${rootsrc%p2} ;;
  *2) disk=${rootsrc%2} ;;
  *) echo "unrecognized root device $rootsrc" >&2; exit 1 ;;
esac

# Grow partition 2 to the end of the disk; --no-reread + partx handles the
# mounted-disk case. "," + default size = all remaining space.
echo ", +" | sfdisk --no-reread -N 2 "$disk" || true
partx -u "$disk" || true
resize2fs "$rootsrc"

touch "$FLAG"
echo "root filesystem grown to $(findmnt -no SIZE /)"
