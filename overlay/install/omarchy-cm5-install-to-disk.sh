#!/bin/bash
# First-boot installer: when this system is running from a USB stick and the
# machine has internal storage (NVMe preferred, then eMMC), offer — and
# default to — installing Omarchy onto that internal disk. The USB stick is
# NEVER a target. Declining falls through to normal in-place provisioning
# (live-on-stick mode). Runs on tty1 before omarchy-provision-owner via
# omarchy-cm5-install-to-disk.service; on an installed (internal) system the
# USB check makes it exit immediately.
#
# Presentation mirrors upstream's omarchy-provision-owner (the "real"
# installer look): the omarchy pixel logo, the same gum palette, the same
# console-font scaling — so install → provisioning reads as one flow.
set -euo pipefail

OMARCHY_PATH="${OMARCHY_PATH:-/usr/share/omarchy}"
LOGO_PATH="$OMARCHY_PATH/logo.txt"

# Upstream's gum palette (omarchy-provision-owner)
export GUM_CONFIRM_PROMPT_FOREGROUND="6"
export GUM_CONFIRM_SELECTED_FOREGROUND="0"
export GUM_CONFIRM_SELECTED_BACKGROUND="2"
export GUM_CONFIRM_UNSELECTED_FOREGROUND="7"
export GUM_CONFIRM_UNSELECTED_BACKGROUND="0"
export GUM_CHOOSE_CURSOR_FOREGROUND="2"
export GUM_CHOOSE_HEADER_FOREGROUND="6"

have_gum() { command -v gum >/dev/null; }

say()  { if have_gum; then gum style --foreground 7 "$*"; else echo "$*"; fi }
accent(){ if have_gum; then gum style --foreground 2 "$*"; else echo "$*"; fi }
warn() { if have_gum; then gum style --foreground 1 "$*"; else echo "$*" >&2; fi }

confirm() { # confirm <prompt> — default YES
  if have_gum; then gum confirm --default=yes "$1"
  else read -rp "$1 [Y/n] " a; [[ ! $a =~ ^[Nn] ]]; fi
}

# Match upstream's first-boot console sizing: on a high-resolution KMS
# console the default 8x16 font is tiny; step up so the logo and prompts
# read at the size the real installer renders at. (Simplified from
# omarchy-provision-owner's empirical picker; same fonts, same intent.)
scale_console_font() {
  [[ $(tty 2>/dev/null) == /dev/tty* ]] || return 0
  local rows; rows=$(stty size 2>/dev/null | awk '{print $1}') || return 0
  if   (( rows >= 100 )); then setfont latarcyrheb-sun32 2>/dev/null || true
  elif (( rows >= 60  )); then setfont sun12x22 2>/dev/null || true
  fi
}

render_header() {
  clear
  if [[ -f $LOGO_PATH ]] && have_gum; then
    gum style --foreground 2 --padding "1 0" "$(cat "$LOGO_PATH")"
  else
    accent "  OMARCHY"
  fi
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

# --- find internal targets (never USB, never removable) ---------------------
targets=()
for cand in $(lsblk -dpno NAME | grep -E '/dev/nvme[0-9]+n[0-9]+$') \
            $(lsblk -dpno NAME | grep -E '/dev/mmcblk[0-9]+$'); do
  [[ $cand == "$rootdisk" ]] && continue
  [[ $(lsblk -ndo TRAN "$cand" 2>/dev/null) == usb ]] && continue
  [[ $(lsblk -ndo RM "$cand" 2>/dev/null | tr -d ' ') == 1 ]] && continue
  (( $(blockdev --getsize64 "$cand") >= 14000000000 )) || continue
  targets+=("$cand")
done
if ((${#targets[@]} == 0)); then
  echo "install-to-disk: no internal (non-USB, non-removable, ≥14 GB) disk found — live mode"
  exit 0
fi
target=${targets[0]}                            # NVMe sorts before eMMC

# Test hook: report the decision and stop before anything destructive.
# tests/installer-detection.test.sh runs the real script under mocked
# lsblk/findmnt/blockdev and asserts on this output.
if [[ ${OMARCHY_INSTALL_CHECK:-} == 1 ]]; then
  echo "TARGET=$target"
  exit 0
fi

label_of() {
  local size model
  size=$(lsblk -ndo SIZE "$1" | tr -d ' ')
  model=$(lsblk -ndo MODEL "$1" | sed 's/ *$//')
  echo "$1  ($size${model:+ — $model})"
}

scale_console_font
render_header

# Multiple internal disks: choose with the omarchy menu; one: it's the default.
if ((${#targets[@]} > 1)) && have_gum; then
  labels=(); for t in "${targets[@]}"; do labels+=("$(label_of "$t")"); done
  picked=$(gum choose --header "Install Omarchy to which disk?" "${labels[@]}")
  target=${picked%% *}
fi

say ""
accent "  Install Omarchy to internal storage"
say ""
say "  Target: $(label_of "$target")"
warn "  Everything on this disk will be erased."
say ""
if ! confirm "Install Omarchy to $target now?"; then
  say "Skipping install — continuing as a live system on the USB stick."
  sleep 2
  exit 0
fi

# --- partition: same layout as the image, fresh disk id ---------------------
# Disk machinery forked from upstream omarchy-iso (disk-partitioning.sh):
# read-back partition numbering, creation bookkeeping, rollback on failure.
# Pi adaptations: MBR label (firmware boot — no GPT/EFI/limine), fixed
# 512M FAT + ext4 layout, fresh MBR disk id so the installed system's
# PARTUUIDs can't collide with the stick's.
lib=${OMARCHY_CM5_LIB:-/usr/local/share/omarchy-cm5}
# shellcheck source=overlay/installer/disk-partitioning.sh
source "$lib/disk-partitioning.sh"
# shellcheck source=overlay/installer/pi-disk-layout.sh
source "$lib/pi-disk-layout.sh"
disk_abort_hook() { warn "$1"; rollback_created_parts "$target"; }

newid=$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')
partition_target_disk "$target" "$newid"   # sets bootp/rootp/*_partuuid
partprobe "$target" 2>/dev/null || true
wait_for_device "$bootp" || _disk_abort "boot partition device never appeared"
wait_for_device "$rootp" || _disk_abort "root partition device never appeared"

disk_step "formatting $bootp" mkfs.vfat -F 32 -n OMARCHYBOOT "$bootp"
disk_step "formatting $rootp" mkfs.ext4 -qF -L omarchy-root "$rootp"

mnt=/run/omarchy-install-target
mkdir -p "$mnt"
mount "$rootp" "$mnt"
mkdir -p "$mnt/boot"
mount "$bootp" "$mnt/boot"

# --- copy the running system ------------------------------------------------
render_header
accent "  Installing Omarchy to $target …"
say ""
rsync -aHAXx --info=progress2 \
  --exclude=/var/lib/omarchy-cm5/root-grown \
  --exclude=/var/cache/pacman/pkg/'*' \
  --exclude=/lost+found \
  / "$mnt/"
rsync -a /boot/ "$mnt/boot/"

# --- retarget boot + fstab to the new PARTUUIDs -----------------------------
sed -i "s/root=PARTUUID=[0-9a-fA-F-]*/root=PARTUUID=$root_partuuid/" "$mnt/boot/cmdline.txt"
cat >"$mnt/etc/fstab" <<EOF
# Written by omarchy-cm5-install-to-disk
PARTUUID=$root_partuuid  /      ext4  defaults  0 1
PARTUUID=$boot_partuuid  /boot  vfat  defaults  0 2
EOF
# grow-root re-runs on the installed system (target may be bigger than image)
rm -f "$mnt/var/lib/omarchy-cm5/root-grown"

sync
umount -R "$mnt"

render_header
accent "  Omarchy is installed on $target."
say ""
say "  Remove the USB stick. First boot asks for your username and password."
say ""
if confirm "Reboot now?"; then systemctl reboot; else systemctl poweroff; fi
