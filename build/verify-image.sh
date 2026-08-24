#!/bin/bash
# Post-build verification: mount the finished image read-only and assert the
# properties a bootable Pi 5 Omarchy install image must have. Exit non-zero on
# any hard failure; print a VERIFICATION report either way.
set -uo pipefail

IMG=${1:?usage: verify-image.sh <image>}
BOARD=${BOARD:-cm5}
VERDICT=${VERDICT:-${IMG%.img}.VERIFICATION.txt}
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

loop=$(losetup --find --show --partscan --read-only "$IMG")
mnt=$(mktemp -d)
trap 'umount -R "$mnt" 2>/dev/null; losetup -d "$loop"; rmdir "$mnt" 2>/dev/null' EXIT
for _ in {1..20}; do [[ -b ${loop}p1 && -b ${loop}p2 ]] && break; sleep 0.5; done
mount -o ro "${loop}p2" "$mnt"
mount -o ro "${loop}p1" "$mnt/boot"

fails=0
: >"$VERDICT"
check() { # check <hard|soft> <description> <command…>
  local kind=$1 desc=$2; shift 2
  if "$@" &>/dev/null; then
    echo "PASS  $desc" >>"$VERDICT"
  elif [[ $kind == hard ]]; then
    echo "FAIL  $desc" >>"$VERDICT"; ((fails++))
  else
    echo "warn  $desc" >>"$VERDICT"
  fi
}
has() { compgen -G "$1" >/dev/null; }

# Partition table / boot chain
check hard "MBR partition table with boot+root"   bash -c "sfdisk -d '$IMG' | grep -q 'type=c' && sfdisk -d '$IMG' | grep -q 'type=83'"
check hard "kernel modules installed"             has "$mnt/usr/lib/modules/*/kernel"
if [[ $BOARD == ayn-thor ]]; then
  check hard "fixed disk id 0x7a055550"             bash -c "sfdisk -d '$IMG' | grep -qi 'label-id: 0x7a055550'"
  check hard "ABL KERNEL present"                   test -f "$mnt/boot/KERNEL"
  check hard "KERNEL is ANDROID! bootimg"           bash -c "test \"\$(head -c 8 '$mnt/boot/KERNEL')\" = 'ANDROID!'"
  check hard "SYSTEM stub squashfs present"         test -f "$mnt/boot/SYSTEM"
  check hard "SYSTEM has systemd pivot shim"        bash -c "unsquashfs -l '$mnt/boot/SYSTEM' 2>/dev/null | grep -q 'usr/lib/systemd/systemd'"
  check hard "post-flash.sh USB debug hook"         test -f "$mnt/boot/post-flash.sh"
  check hard "omarchy-log.sh on FAT"                test -f "$mnt/boot/omarchy-log.sh"
  check hard "omarchy-splash.sh on FAT"             test -f "$mnt/boot/omarchy-splash.sh"
  check hard "no Pi config.txt on Thor image"       bash -c "! test -f '$mnt/boot/config.txt'"
  check hard "Thor session wrapper"                 test -x "$mnt/usr/local/bin/omarchy-thor-session"
  check hard "Thor monitors.lua has DSI-2"          grep -q 'DSI-2' "$mnt/etc/skel/.config/hypr/monitors.lua"
  check hard "Thor DSI-2 capped at 60 Hz"           grep -q 'mode = "1080x1920@60"' "$mnt/etc/skel/.config/hypr/monitors.lua"
  check hard "Thor monitors.lua rotates both DSIs"  bash -c "test \"\$(grep -c 'transform = 3' '$mnt/etc/skel/.config/hypr/monitors.lua')\" -eq 2"
  check hard "Thor monitors.lua on FAT"             test -f "$mnt/boot/thor-monitors.lua"
  check hard "Thor gamepad keyboard mapper"         test -x "$mnt/usr/local/bin/omarchy-thor-kb"
  check hard "Thor gamepad screensaver wake"        test -x "$mnt/usr/local/bin/omarchy-thor-gamepad-wake"
  check hard "Thor DSI timeout recovery helper"      test -x "$mnt/usr/local/bin/omarchy-thor-display-recover"
  check hard "Thor Wi-Fi credential importer"       test -x "$mnt/usr/local/bin/omarchy-thor-wifi-import"
  check hard "Thor greeter OSK helper"              test -x "$mnt/usr/local/bin/omarchy-thor-osk"
  check hard "Thor OSK binary"                      test -x "$mnt/usr/bin/wvkbd-mobintl"
  check hard "Thor desktop shell launcher"          test -x "$mnt/usr/local/bin/omarchy-thor-desktop"
  check hard "Thor direct Hyprland session"         test -x "$mnt/usr/local/bin/omarchy-thor-session"
  check hard "Thor debug sudo is opt-in"            test ! -e "$mnt/etc/sudoers.d/99-thor-debug"
  check hard "Thor gamepad wake enabled"            test -L "$mnt/etc/systemd/system/multi-user.target.wants/omarchy-thor-gamepad-wake.service"
  check hard "Thor DSI recovery enabled"             test -L "$mnt/etc/systemd/system/multi-user.target.wants/omarchy-thor-display-recover.service"
  check hard "Thor Wi-Fi import enabled"            test -L "$mnt/etc/systemd/system/multi-user.target.wants/omarchy-thor-wifi-import.service"
  check hard "Thor USB debug enabled"               test -L "$mnt/etc/systemd/system/multi-user.target.wants/omarchy-thor-usb-gadget.service"
  check hard "Thor SSH daemon enabled"              test -L "$mnt/etc/systemd/system/multi-user.target.wants/sshd.service"
  check hard "Thor base has no fixed autologin user" test ! -e "$mnt/etc/sddm.conf.d/99-thor-autologin.conf"
  check hard "Thor gum letter picker"               test -x "$mnt/usr/local/bin/omarchy-thor-type"
  check hard "Thor gum wrapper for provision"       test -x "$mnt/usr/local/lib/omarchy-thor/gum"
  check hard "Thor CDSP firmware"                   test -f "$mnt/usr/lib/firmware/qcom/sm8550/ayn/cdsp.mbn"
  check hard "Thor Iris VPU firmware"               test -f "$mnt/usr/lib/firmware/qcom/vpu/vpu30_p4.mbn"
  check hard "Thor Hyprland fallback session"       test -f "$mnt/usr/local/share/wayland-sessions/omarchy-thor.desktop"
  check hard "Thor touch hwdb"                      test -f "$mnt/usr/lib/udev/hwdb.d/61-thor-ft5x06.hwdb"
  check hard "Thor modules 7.1.2"                   test -d "$mnt/usr/lib/modules/7.1.2"
  check soft "Thor ADSP firmware"                   test -f "$mnt/usr/lib/firmware/qcom/sm8550/ayn/thor/adsp.mbn"
  check hard "fstab mounts / by PARTUUID"           grep -qE 'PARTUUID=7a055550-02[[:space:]]+/[[:space:]]' "$mnt/etc/fstab"
  check hard "fstab mounts /boot by PARTUUID"       grep -qE 'PARTUUID=7a055550-01[[:space:]]+/boot[[:space:]]' "$mnt/etc/fstab"
else
  check hard "fixed disk id 0x2ca5b007"             bash -c "sfdisk -d '$IMG' | grep -qi 'label-id: 0x2ca5b007'"
  check hard "Pi 5 kernel image on boot partition"  bash -c "ls '$mnt/boot' | grep -qE '^kernel(_2712|8)\.img$'"
  check hard "config.txt kernel= names a real file"  bash -c "k=\$(sed -n 's/^kernel=//p' '$mnt/boot/config.txt' | head -1); [[ -n \$k && -f $mnt/boot/\$k ]]"
  check hard "config.txt present"                   test -f "$mnt/boot/config.txt"
  check hard "cmdline.txt points at PARTUUID root"  grep -q 'root=PARTUUID=2ca5b007-02' "$mnt/boot/cmdline.txt"
  check hard "device trees present (bcm2712)"       has "$mnt/boot/*2712*.dtb"
  check hard "overlays directory present"           test -d "$mnt/boot/overlays"
  check hard "kms display overlay configured"       grep -q 'vc4-kms-v3d' "$mnt/boot/config.txt"
  check soft "initramfs referenced in config.txt"   grep -q '^initramfs ' "$mnt/boot/config.txt"
  check hard "fstab mounts / by PARTUUID"           grep -qE 'PARTUUID=2ca5b007-02[[:space:]]+/[[:space:]]' "$mnt/etc/fstab"
  check hard "fstab mounts /boot by PARTUUID"       grep -qE 'PARTUUID=2ca5b007-01[[:space:]]+/boot[[:space:]]' "$mnt/etc/fstab"
fi

# Base system
# fstab must use the deterministic PARTUUIDs — genfstab inside a build
# container once leaked /dev/loopXpN paths and the build host's swapfile,
# which hard-fails Local File Systems on the Pi (no such devices).
check hard "fstab free of build-host leakage"     bash -c "! grep -E '/dev/loop|[[:space:]]swap[[:space:]]' '$mnt/etc/fstab'"

# Installer + hosted repo
if [[ $BOARD == ayn-thor ]]; then
  check hard "install-to-disk NOT wired on Thor"    bash -c "! test -L '$mnt/etc/systemd/system/multi-user.target.wants/omarchy-cm5-install-to-disk.service'"
else
  check hard "install-to-disk installer present"    test -x "$mnt/usr/local/bin/omarchy-cm5-install-to-disk"
  check hard "forked disk machinery present"        test -f "$mnt/usr/local/share/omarchy-cm5/disk-partitioning.sh"
  check hard "parted present (installer dependency)" test -e "$mnt/usr/bin/parted"
  check hard "install-to-disk service wired"        test -L "$mnt/etc/systemd/system/multi-user.target.wants/omarchy-cm5-install-to-disk.service"
  check hard "rsync present (installer dependency)" test -e "$mnt/usr/bin/rsync"
fi
check hard "[omarchy] repo points at hosted URL"  grep -q 'Server = https://github.com/TensorFleet/omarchy-cm5/releases/download/aarch64-pkgs' "$mnt/etc/pacman.conf"
check hard "aarch64 rootfs (ELF machine)"         bash -c "file -b '$mnt/usr/bin/bash' | grep -q aarch64"
check hard "systemd present"                      test -e "$mnt/usr/lib/systemd/systemd"
check hard "NetworkManager enabled"               test -L "$mnt/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
check hard "sddm display manager enabled"         test -L "$mnt/etc/systemd/system/display-manager.service"
check soft "stock alarm user removed"             bash -c "! grep -q '^alarm:' '$mnt/etc/passwd'"
check hard "machine-id empty (first-boot init)"   bash -c "! test -s '$mnt/etc/machine-id'"

# Omarchy
check hard "omarchy runtime at /usr/share/omarchy" test -f "$mnt/usr/share/omarchy/version"
check hard "omarchy bin on PATH (/usr/bin)"        test -x "$mnt/usr/bin/omarchy"
check hard "hyprland installed"                    test -x "$mnt/usr/bin/Hyprland"
check hard "/etc/skel seeded with hypr config"     test -d "$mnt/etc/skel/.config/hypr"
check hard "omarchy session for sddm"              has "$mnt/usr/share/wayland-sessions/*.desktop"
if [[ $BOARD == ayn-thor ]]; then
  check hard "quickshell present (bar/menus)"      bash -c "test -x '$mnt/usr/bin/quickshell' || test -x '$mnt/usr/bin/qs'"
  check hard "OpenSSH server present"              test -x "$mnt/usr/bin/sshd"
else
  check soft "quickshell present (bar/menus)"      bash -c "test -x '$mnt/usr/bin/quickshell' || test -x '$mnt/usr/bin/qs'"
fi
check soft "uwsm present"                          test -x "$mnt/usr/bin/uwsm"

# First-boot provisioning ("install" flow)
check hard "provisioning armed (pending flag)"     test -f "$mnt/var/lib/omarchy/provisioning/pending"
check hard "omarchy-provision-owner service wired" test -L "$mnt/etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"
check hard "omarchy-provision-owner binary"        test -x "$mnt/usr/bin/omarchy-provision-owner"
check hard "gum available (provisioning TUI)"      test -x "$mnt/usr/bin/gum"
check soft "node tarball staged for offline setup" has "$mnt/var/lib/omarchy/provisioning/packages/node-v*-linux-x64.tar.gz"
check hard "grow-root first-boot service wired"    test -L "$mnt/etc/systemd/system/multi-user.target.wants/omarchy-cm5-grow-root.service"

# GPU / board specifics
if [[ $BOARD == ayn-thor ]]; then
  check soft "mesa freedreno dri"                  has "$mnt/usr/lib/dri/*msm*"
  check soft "vulkan-freedreno ICD"                has "$mnt/usr/share/vulkan/icd.d/freedreno*"
else
  check hard "CM5 hyprland drop-in from overlay"     test -f "$mnt/etc/skel/.config/hypr/rpi-cm5.conf"
  check soft "mesa (v3d GL) installed"               has "$mnt/usr/lib/dri/*v3d*"
  check soft "vulkan-broadcom (v3dv) installed"      has "$mnt/usr/share/vulkan/icd.d/broadcom*"
fi

echo "" >>"$VERDICT"
echo "hard failures: $fails" >>"$VERDICT"
cat "$VERDICT"
exit $((fails > 0))
