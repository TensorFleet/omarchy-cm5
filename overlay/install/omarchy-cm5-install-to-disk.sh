#!/bin/bash
# First-boot installer: when this system is running from a USB stick and the
# machine has internal storage (NVMe preferred, then eMMC), offer — and
# default to — installing Omarchy onto that internal disk. The USB stick is
# NEVER a target. Declining falls through to normal in-place provisioning
# (live-on-stick mode). Runs on tty1 before omarchy-provision-owner via
# omarchy-cm5-install-to-disk.service; on an installed (internal) system the
# USB check makes it exit immediately.
set -euo pipefail

say()  { command -v gum >/dev/null && gum style --foreground 212 "$*" || echo "$*"; }
warn() { command -v gum >/dev/null && gum style --foreground 196 "$*" || echo "$*" >&2; }

confirm() { # confirm <prompt> — default YES
  if command -v gum >/dev/null; then gum confirm --default=yes "$1"
  else read -rp "$1 [Y/n] " a; [[ ! $a =~ ^[Nn] ]]; fi
}

# --- am I running from USB? -------------------------------------------------
# PKNAME is the kernel's own parent-device answer — never parse device names
# by hand (a regex once turned /dev/sda2 into "disk" /dev/sda2, whose empty
# TRAN made this exit silently and skip the whole install).
rootsrc=$(findmnt -no SOURCE /)                 # /dev/sda2, /dev/mmcblk0p2, …
rootdisk=/dev/$(lsblk -ndo PKNAME "$rootsrc")
if [[ $(lsblk -ndo TRAN "$rootdisk" 2>/dev/null) != usb ]]; then
  echo "install-to-disk: root $rootsrc is on $rootdisk (not USB) — nothing to do"
  exit 0
fi

# --- find an internal target (never USB, never removable) -------------------
target=""
for cand in $(lsblk -dpno NAME | grep -E '/dev/nvme[0-9]+n[0-9]+$') \
            $(lsblk -dpno NAME | grep -E '/dev/mmcblk[0-9]+$'); do
  [[ $cand == "$rootdisk" ]] && continue
  [[ $(lsblk -ndo TRAN "$cand" 2>/dev/null) == usb ]] && continue
  [[ $(lsblk -ndo RM "$cand" 2>/dev/null | tr -d ' ') == 1 ]] && continue
  (( $(blockdev --getsize64 "$cand") >= 14000000000 )) || continue
  target=$cand; break
done
if [[ -z $target ]]; then
  echo "install-to-disk: no internal (non-USB, non-removable, ≥14 GB) disk found — live mode"
  exit 0
fi

# Test hook: report the decision and stop before anything destructive.
# tests/installer-detection.test.sh runs the real script under mocked
# lsblk/findmnt/blockdev and asserts on this output.
if [[ ${OMARCHY_INSTALL_CHECK:-} == 1 ]]; then
  echo "TARGET=$target"
  exit 0
fi

size=$(lsblk -ndo SIZE "$target" | tr -d ' ')
model=$(lsblk -ndo MODEL "$target" | sed 's/ *$//')

clear
say ""
say "  Omarchy CM5 installer"
say ""
say "  Internal storage found: $target ($size ${model:+— $model})"
warn "  Installing ERASES EVERYTHING on $target."
say ""
if ! confirm "Install Omarchy to $target now?"; then
  say "Skipping install — continuing as a live system on the USB stick."
  sleep 2
  exit 0
fi

# --- partition: same layout as the image, fresh disk id ---------------------
# A new MBR id (and thus new PARTUUIDs) means the installed system and the
# stick can coexist without root=PARTUUID ambiguity.
newid=$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')
sfdisk --wipe always "$target" <<EOF
label: dos
label-id: 0x$newid
start=2048, size=1048576, type=c, bootable
start=1050624, type=83
EOF
partx -u "$target" || true

pp=""; [[ $target == *[0-9] ]] && pp="p"
bootp="${target}${pp}1" rootp="${target}${pp}2"
for _ in {1..20}; do [[ -b $bootp && -b $rootp ]] && break; sleep 0.5; done
[[ -b $bootp && -b $rootp ]] || { warn "partitions never appeared on $target"; exit 1; }

mkfs.vfat -F 32 -n OMARCHYBOOT "$bootp" >/dev/null
mkfs.ext4 -qF -L omarchy-root "$rootp"

mnt=/run/omarchy-install-target
mkdir -p "$mnt"
mount "$rootp" "$mnt"
mkdir -p "$mnt/boot"
mount "$bootp" "$mnt/boot"

# --- copy the running system ------------------------------------------------
say "Copying system to $target (a few minutes) …"
rsync -aHAXx --info=progress2 \
  --exclude=/var/lib/omarchy-cm5/root-grown \
  --exclude=/var/cache/pacman/pkg/'*' \
  --exclude=/lost+found \
  / "$mnt/"
rsync -a /boot/ "$mnt/boot/"

# --- retarget boot + fstab to the new PARTUUIDs -----------------------------
sed -i "s/root=PARTUUID=[0-9a-fA-F-]*/root=PARTUUID=$newid-02/" "$mnt/boot/cmdline.txt"
cat >"$mnt/etc/fstab" <<EOF
# Written by omarchy-cm5-install-to-disk
PARTUUID=$newid-02  /      ext4  defaults  0 1
PARTUUID=$newid-01  /boot  vfat  defaults  0 2
EOF
# grow-root re-runs on the installed system (target may be bigger than image)
rm -f "$mnt/var/lib/omarchy-cm5/root-grown"

sync
umount -R "$mnt"

say ""
say "  Installed to $target."
say "  Remove the USB stick — first boot on internal storage asks for"
say "  your username and password."
say ""
if confirm "Reboot now?"; then systemctl reboot; else systemctl poweroff; fi
