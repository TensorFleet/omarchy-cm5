# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154  # bootp/rootp/*_partuuid are this file's
# output contract; created_partition_number is set by disk-partitioning.sh,
# which callers source first.
# The Pi adaptation layer over upstream omarchy-iso's disk-partitioning.sh
# (which must be sourced first): MBR label for Pi-firmware boot, the fixed
# 512M FAT32 + ext4 layout every omarchy-cm5 system uses, a fresh MBR disk
# id, and PARTUUIDs derived from the partition numbers parted ACTUALLY
# assigned (upstream's read-back rule, applied to the MBR PARTUUID format).
#
# Sourced, not executed. Testable against a plain image file — device-node
# waiting is the caller's job (tests/installer-partitioning.test.sh runs
# this exact code, mirroring upstream's partition-numbering test).

# partition_target_disk <disk-or-image> <mbr-disk-id-hex>
# On success sets: bootp rootp boot_partuuid root_partuuid
partition_target_disk() {
  local _target="$1" _newid="$2"
  local boot_start boot_end disk_end bootnum rootnum

  # parted's end coordinate is INCLUSIVE (a partition "to X" occupies the
  # sector containing X) — the first test run caught adjacent partitions
  # overlapping by one sector when root started at the boot end. Sector
  # arithmetic below reproduces the image's sfdisk layout exactly:
  # p1 = sectors [2048..1050623] (1048576 sectors = 512 MiB), p2 = the rest.
  local sector=512
  boot_start=$((2048 * sector))
  boot_end=$((boot_start + 512 * 1024 * 1024 - sector))   # inclusive last byte
  if [[ -b $_target ]]; then
    disk_end=$(( $(blockdev --getsize64 "$_target") - 1024 * 1024 ))
  else
    disk_end=$(( $(stat -c %s "$_target" 2>/dev/null || stat -f %z "$_target") - 1024 * 1024 ))
  fi

  disk_step "clearing signatures on $_target" wipefs -af "$_target"
  disk_step "writing MBR label" parted --script "$_target" mklabel msdos
  create_partition "$_target" "$boot_start" "$boot_end" fat32 OMARCHYBOOT ||
    _disk_abort "creating the boot partition"
  bootnum=$created_partition_number
  bootp=$(partition_path "$_target" "$bootnum")
  create_partition "$_target" "$((boot_end + sector))" "$disk_end" ext4 omarchy-root ||
    _disk_abort "creating the root partition"
  rootnum=$created_partition_number
  rootp=$(partition_path "$_target" "$rootnum")
  disk_step "setting boot flag" parted --script "$_target" set "$bootnum" boot on
  disk_step "setting disk id 0x$_newid" sfdisk --disk-id "$_target" "0x$_newid"
  printf -v boot_partuuid '%s-%02d' "$_newid" "$bootnum"
  printf -v root_partuuid '%s-%02d' "$_newid" "$rootnum"
}
