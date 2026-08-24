#!/bin/bash
# Incremental Thor update: copy FAT boot files only (KERNEL/SYSTEM/hooks).
# Never rewrites the 12G ext4 root. Seconds, not minutes.
# Usage: bash build/update-thor-fat.sh [diskN]
set -euo pipefail
# Do not synthesize AppleDouble ._* files for every copied payload item.
export COPYFILE_DISABLE=1
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src=${BOOTFILES:-$here/thor-boot-update}
[[ -f $src/SYSTEM && -f $src/KERNEL && -f $src/post-flash.sh && -f $src/thor-monitors.lua && -f $src/omarchy-thor-kb ]] || {
  echo "run: docker … bash /work/build/mk-thor-bootfiles.sh first" >&2
  exit 1
}

disk=${1:-}
if [[ -z $disk ]]; then
  # Prefer a ROCKNIX-labeled FAT on a removable disk that is not huge.
  while read -r ident; do
    [[ $ident == disk*s* ]] || continue
    vol=$(diskutil info "$ident" 2>/dev/null | awk -F': *' '/Volume Name/{print $2}')
    [[ $vol == ROCKNIX ]] || continue
    whole=${ident%%s[0-9]*}
    size=$(diskutil info "$whole" | awk -F'[()]' '/Disk Size/{print $2}' | awk '{print $1}')
    if [[ -n $size && $size -lt 107374182400 ]]; then
      disk=$whole
      break
    fi
  done < <(diskutil list | awk '/Windows_FAT_32|DOS_FAT_32/{print $NF}')
fi
[[ -n $disk ]] || { echo "no ROCKNIX FAT found — insert the Omarchy card" >&2; diskutil list external physical; exit 1; }

echo "updating FAT on $disk"
diskutil mountDisk "$disk" >/dev/null || diskutil mount "${disk}s1"
mnt=$(diskutil info "${disk}s1" | awk -F': *' '/Mount Point/{print $2; exit}')
[[ -n $mnt && -d $mnt ]] || { echo "could not mount ${disk}s1" >&2; exit 1; }
echo "mount: $mnt"
cp -f "$src/KERNEL" "$src/SYSTEM" "$src/KERNEL.md5" "$src/SYSTEM.md5" \
  "$src/post-flash.sh" "$src/post-sysroot.sh" "$src/omarchy-log.sh" \
  "$src/omarchy-splash.sh" "$src/thor-apply-storage.sh" "$src/mount-storage.sh" \
  "$src/thor-monitors.lua" \
  "$src/omarchy-thor-kb" "$src/omarchy-thor-type.sh" "$src/omarchy-thor-gum.sh" \
  "$src/omarchy-thor-kb.service" "$src/omarchy-thor-gamepad-wake" \
  "$src/omarchy-thor-gamepad-wake.service" "$src/omarchy-thor-display-recover" \
  "$src/omarchy-thor-display-recover.service" "$src/omarchy-thor-wifi-import" \
  "$src/omarchy-thor-wifi-import.service" "$src/omarchy-provision-owner-thor.conf" \
  "$src/blacklist-qcom-iris.conf" "$src/20-ayn-thor.uwsm" \
  "$src/omarchy-thor-wait-dri.sh" "$src/sddm-thor.conf" "$src/sddm-autologin.conf" \
  "$src/sddm-hyprland.lua" "$src/sddm-wayland.conf" \
  "$src/omarchy-thor-greeter.sh" "$src/omarchy-thor-outputs.sh" \
  "$src/omarchy-thor-desktop.sh" "$src/omarchy-thor-session.sh" \
  "$src/omarchy-thor-osk.sh" \
  "$src/omarchy-thor-desktop-log.sh" "$src/omarchy-thor-desktop-log.service" \
  "$src/omarchy-thor.desktop" "$src/omarchy-thor-desktop-fallback.sh" \
  "$src/omarchy-thor-desktop-fallback.service" \
  "$src/omarchy-thor-usb-gadget.sh" "$src/omarchy-thor-usb-gadget.service" "$mnt/"
[[ -f $src/omarchy-thor-debug.pub ]] && cp -f "$src/omarchy-thor-debug.pub" "$mnt/"
[[ -f $src/openssh-thor.pkg.tar.xz ]] && cp -f "$src/openssh-thor.pkg.tar.xz" "$mnt/"
[[ -f $src/omarchy-thor-wifi ]] && cp -f "$src/omarchy-thor-wifi" "$mnt/"
[[ -f $src/omarchy-thor-passwordless-sudo ]] && \
  cp -f "$src/omarchy-thor-passwordless-sudo" "$mnt/"
[[ -f $src/omarchy-thor-passwordless-sudo ]] || \
  rm -f "$mnt/omarchy-thor-passwordless-sudo"
rm -f "$mnt/sddm-hyprland.conf"
# Older updates created AppleDouble sidecars on the FAT. They are metadata,
# not Thor payloads, and make config-file isolation harder to audit.
find "$mnt" -maxdepth 1 -type f -name '._*' -delete
[[ -x $src/wvkbd-mobintl ]] && cp -f "$src/wvkbd-mobintl" "$mnt/"
if [[ -f $src/quickshell.xz && -f $src/quickshell.sha256 ]]; then
  cp -f "$src/quickshell.xz" "$src/quickshell.sha256" "$mnt/"
  [[ -f $src/quickshell-qt.version ]] && cp -f "$src/quickshell-qt.version" "$mnt/"
fi
if [[ -d $src/firmware ]]; then
  rm -rf "$mnt/firmware"
  mkdir -p "$mnt/firmware"
  cp -a "$src/firmware/." "$mnt/firmware/"
fi
sync
ls -lh "$mnt/KERNEL" "$mnt/SYSTEM" "$mnt/omarchy-thor-kb" \
  "$mnt/omarchy-thor-gamepad-wake" "$mnt/thor-monitors.lua" "$mnt/quickshell.xz"
diskutil eject "$disk"
echo "ejected. Card back in the Thor, Vol-, device Thor."
