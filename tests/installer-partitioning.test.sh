#!/bin/bash
# Unit tests for the Pi adaptation layer (pi-disk-layout.sh) — the layout our
# installer writes, exercised the same way upstream omarchy-iso tests its
# machinery: against a plain image file, no root, no loop devices.
#
# What must hold on every install target:
#   - MBR (dos) label with the requested disk id
#   - partition 1: FAT32-typed (0c), 512 MiB, boot flag set
#   - partition 2: linux-typed (83), fills the rest
#   - PARTUUIDs derived from the numbers parted actually assigned
#   - partition_path naming (sda -> sda1, mmcblk0/nvme -> p-suffix)
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if ! command -v parted >/dev/null 2>&1; then
  echo "SKIP: parted is not installed"
  exit 0
fi

# shellcheck source=../overlay/installer/disk-partitioning.sh
source "$ROOT/overlay/installer/disk-partitioning.sh"
# shellcheck source=../overlay/installer/pi-disk-layout.sh
source "$ROOT/overlay/installer/pi-disk-layout.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
IMG="$WORK/disk.img"
truncate -s $((16 * 1024 * 1024 * 1024)) "$IMG"

fails=0
check() { # check <label> <expected> <actual>
  if [[ $2 == "$3" ]]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s: expected %q, got %q\n' "$1" "$2" "$3"; fails=$((fails+1)); fi
}

echo "==> partition_target_disk writes the Pi layout"
partition_target_disk "$IMG" 2ca5b007 >/dev/null

dump=$(sfdisk -d "$IMG")
check "dos label"            "dos"        "$(awk '/^label:/ {print $2}' <<<"$dump")"
check "disk id"              "0x2ca5b007" "$(awk '/^label-id:/ {print $2}' <<<"$dump")"
check "two partitions"       "2"          "$(grep -c '^/' <<<"$dump" || true)"
check "p1 type is FAT (c)"   "1"          "$(grep -c 'type=c\b.*bootable\|bootable.*type=c\b' <<<"$dump" || true)"
check "p2 type is linux(83)" "1"          "$(grep -c 'type=83' <<<"$dump" || true)"
p1_sectors=$(awk -F'[ ,]+' '/img1/ {for(i=1;i<=NF;i++) if($i=="size=") print $(i+1)}' <<<"$dump")
[[ -z $p1_sectors ]] && p1_sectors=$(grep 'img1' <<<"$dump" | sed -E 's/.*size= *([0-9]+).*/\1/')
check "p1 is 512 MiB"        "1048576"    "$p1_sectors"

echo "==> PARTUUIDs come from assigned numbers"
check "boot partuuid" "2ca5b007-01" "$boot_partuuid"
check "root partuuid" "2ca5b007-02" "$root_partuuid"
check "bootp path"    "${IMG}1"     "$bootp"
check "rootp path"    "${IMG}2"     "$rootp"

echo "==> partition_path naming"
check "sda naming"     "/dev/sda2"       "$(partition_path /dev/sda 2)"
check "mmcblk naming"  "/dev/mmcblk0p2"  "$(partition_path /dev/mmcblk0 2)"
check "nvme naming"    "/dev/nvme0n1p1"  "$(partition_path /dev/nvme0n1 1)"

echo
if ((fails)); then echo "$fails check(s) FAILED"; exit 1; else echo "all checks passed"; fi
