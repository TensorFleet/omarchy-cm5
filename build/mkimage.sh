#!/bin/bash
# Build a flashable USB/SD/eMMC image of Omarchy Quattro for the Raspberry
# Pi 5 / CM5 (aarch64) on an Arch Linux ARM base.
#
# This replaces upstream's x86 archiso pipeline:
#   1. loopback image: 512M FAT32 firmware partition + ext4 root (MBR, fixed
#      disk id so cmdline.txt can use a deterministic PARTUUID)
#   2. bootstrap Arch Linux ARM aarch64 rootfs (tarball, then pacman inside
#      a qemu-user chroot when building on x86)
#   3. Pi kernel + firmware boot chain (linux-rpi-16k, no limine)
#   4. the filtered omarchy package set (overlay/install/packages.*)
#   5. the four omarchy 'any' packages (omarchy, -settings, -nvim, -keyring),
#      prebuilt by build/build-any-packages.sh, via a local pacman repo
#   6. upstream's own install stages, unmodified, in the chroot
#   7. CM5/Pi overlay + deferred first-boot provisioning (same flow the ISO
#      arms: omarchy-provision-owner asks for user/password on tty1)
#
# Inputs (env):
#   BOARD             cm5 (default) or ayn-thor
#   IMG               output path            (default build/omarchy-$BOARD.img)
#   IMG_SIZE          image size             (default 12G)
#   LOCAL_PKG_DIR     dir of *.pkg.tar.* from build-any-packages.sh
#   OMARCHY_REPO_URL  aarch64 [omarchy] repo base URL, if one exists
#                     (probed by resolve-packages.sh; overrides LOCAL_PKG_DIR)
#   NODE_TARBALL_PATH node-v*-linux-arm64.tar.gz to stash for offline
#                     first-boot user finalization
#   ALARM_TARBALL     Arch Linux ARM rootfs tarball URL override
#   THOR_VENDOR_DIR   extracted ROCKNIX KERNEL/modules/firmware/stub (ayn-thor)
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
overlay="$here/../overlay"
upstream="$here/upstream"

BOARD=${BOARD:-cm5}
case $BOARD in
  cm5|ayn-thor) ;;
  *) echo "BOARD must be cm5 or ayn-thor (got $BOARD)" >&2; exit 2 ;;
esac

IMG=${IMG:-$here/omarchy-$BOARD.img}
IMG_SIZE=${IMG_SIZE:-12G}
LOCAL_PKG_DIR=${LOCAL_PKG_DIR:-}
OMARCHY_REPO_URL=${OMARCHY_REPO_URL:-}
NODE_TARBALL_PATH=${NODE_TARBALL_PATH:-}
REPORT=${REPORT:-$IMG.report.txt}

# MBR disk identifier: fixed so root=PARTUUID=… is knowable at build time.
# Thor uses a different id so the two images cannot be confused.
if [[ $BOARD == ayn-thor ]]; then
  DISK_ID=7a055550
else
  DISK_ID=2ca5b007
fi

ALARM_MIRRORS=(
  http://os.archlinuxarm.org
  http://fl.us.mirror.archlinuxarm.org
  http://de3.mirror.archlinuxarm.org
  http://il.us.mirror.archlinuxarm.org
)
ALARM_TARBALL=${ALARM_TARBALL:-}

[[ -d $upstream ]] || { echo "run build/fetch-upstream.sh first" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "must run as root (losetup/mount/chroot)" >&2; exit 1; }
for tool in sfdisk losetup mkfs.vfat mkfs.ext4 bsdtar arch-chroot curl; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

if [[ $(uname -m) != aarch64 ]]; then
  # Cross-building: need binfmt so we can chroot into the aarch64 rootfs.
  [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] ||
    { echo "install qemu-user-static (binfmt qemu-aarch64) for cross-builds" >&2; exit 1; }
fi

: >"$REPORT"
note() { echo "$*" | tee -a "$REPORT" >&2; }

# --- 1. image + partitions ---------------------------------------------------
rm -f "$IMG"
truncate -s "$IMG_SIZE" "$IMG"
sfdisk "$IMG" <<EOF
label: dos
label-id: 0x$DISK_ID
start=2048, size=1048576, type=c, bootable
start=1050624, type=83
EOF

loop=$(losetup --find --show --partscan "$IMG")
root=/mnt/omarchy-cm5
cleanup() {
  set +e
  umount -R "$root" 2>/dev/null
  losetup -d "$loop" 2>/dev/null
}
trap cleanup EXIT

# udev may need a beat to create the partition nodes
for _ in {1..20}; do [[ -b ${loop}p1 && -b ${loop}p2 ]] && break; sleep 0.5; done
[[ -b ${loop}p1 ]] || { echo "loop partitions never appeared" >&2; exit 1; }

if [[ $BOARD == ayn-thor ]]; then
  # ABL + stock KERNEL initramfs look for FAT label ROCKNIX and ext4 STORAGE.
  # Also set omarchy-root as a second name the SYSTEM stub accepts.
  mkfs.vfat -F 32 -n ROCKNIX "${loop}p1"
  mkfs.ext4 -q -L STORAGE "${loop}p2"
else
  mkfs.vfat -F 32 -n OMARCHYBOOT "${loop}p1"
  mkfs.ext4 -q -L omarchy-root "${loop}p2"
fi

mkdir -p "$root"
mount "${loop}p2" "$root"
mkdir -p "$root/boot"
mount "${loop}p1" "$root/boot"

# --- 2. base rootfs ----------------------------------------------------------
fetch_tarball() {
  local url
  if [[ -n $ALARM_TARBALL ]]; then
    curl -fL --retry 3 "$ALARM_TARBALL" | bsdtar -xpf - -C "$root" && return 0
    return 1
  fi
  for m in "${ALARM_MIRRORS[@]}"; do
    url="$m/os/ArchLinuxARM-aarch64-latest.tar.gz"
    note "fetching rootfs: $url"
    if curl -fL --retry 2 "$url" | bsdtar -xpf - -C "$root"; then return 0; fi
    note "  … failed, trying next mirror"
  done
  return 1
}
fetch_tarball || { echo "could not fetch Arch Linux ARM rootfs tarball" >&2; exit 1; }

# qemu for the chroot when cross-building (harmless copy on native aarch64
# when the binfmt handler is registered with the F flag it isn't even used)
if [[ $(uname -m) != aarch64 ]] && command -v qemu-aarch64-static >/dev/null; then
  install -Dm755 "$(command -v qemu-aarch64-static)" "$root/usr/bin/qemu-aarch64-static"
fi

# Keep the package cache outside the image
hostcache=${CACHE_DIR:-$(mktemp -d /tmp/omarchy-cm5-cache.XXXX)}
mkdir -p "$hostcache" "$root/var/cache/pacman/pkg"
mount --bind "$hostcache" "$root/var/cache/pacman/pkg"

# pacman.conf: overlay conf, with the [omarchy] section rewritten for what
# this build actually has (remote aarch64 repo > local prebuilt dir > none).
awk 'BEGIN{skip=0} /^\[omarchy\]/{skip=1} skip&&/^\[/&&!/^\[omarchy\]/{skip=0} !skip' \
  "$overlay/pacman/pacman-cm5.conf" >"$root/etc/pacman.conf"
if [[ -n $OMARCHY_REPO_URL ]]; then
  note "[omarchy] repo: $OMARCHY_REPO_URL"
  cat >>"$root/etc/pacman.conf" <<EOF

[omarchy]
SigLevel = Optional TrustAll
Server = $OMARCHY_REPO_URL/\$arch
EOF
elif [[ -n $LOCAL_PKG_DIR && -d $LOCAL_PKG_DIR ]]; then
  note "[omarchy] repo: local prebuilt packages ($(ls "$LOCAL_PKG_DIR"/*.pkg.tar.* 2>/dev/null | wc -l) files)"
  mkdir -p "$root/opt/omarchy-repo"
  cp "$LOCAL_PKG_DIR"/*.pkg.tar.* "$root/opt/omarchy-repo/"
  cat >>"$root/etc/pacman.conf" <<'EOF'

[omarchy]
SigLevel = Optional TrustAll
Server = file:///opt/omarchy-repo
EOF
else
  note "[omarchy] repo: NONE (no aarch64 repo, no local packages) — omarchy runtime will be missing"
fi

in_chroot() { arch-chroot "$root" "$@"; }
pacman_retry() {
  local attempt
  for attempt in 1 2 3; do
    if in_chroot pacman "$@"; then
      return 0
    fi
    note "pacman attempt $attempt failed; refreshing mirrors and retrying"
    in_chroot pacman -Sy --noconfirm || true
    sleep 3
  done
  return 1
}

in_chroot pacman-key --init
in_chroot pacman-key --populate archlinuxarm
if [[ -d $root/opt/omarchy-repo ]]; then
  in_chroot bash -c 'repo-add -q /opt/omarchy-repo/omarchy.db.tar.gz /opt/omarchy-repo/*.pkg.tar.*'
fi
pacman_retry -Syu --noconfirm

# The generic tarball ships the generic kernel; the Pi kernel replaces it.
in_chroot pacman -R --noconfirm linux-aarch64 2>/dev/null || true

# --- 3. board boot chain -----------------------------------------------------
pkg_available() { in_chroot pacman -Si "$1" &>/dev/null; }
first_available() { local p; for p in "$@"; do pkg_available "$p" && { echo "$p"; return 0; }; done; return 1; }

if [[ $BOARD == ayn-thor ]]; then
  # ALARM's linux-aarch64 will not boot SM8550. Use ROCKNIX 7.1.2 modules +
  # firmware extracted by pkgs/aarch64-extra/linux-rocknix-sm8550/extract.sh.
  kernel_pkg=linux-rocknix-sm8550
  note "kernel: $kernel_pkg (ROCKNIX SM8550, not ALARM linux)"
  if pkg_available linux-rocknix-sm8550; then
    pacman_retry -S --noconfirm --ask 4 --needed linux-rocknix-sm8550
  fi
  if pkg_available linux-firmware-thor; then
    pacman_retry -S --noconfirm --ask 4 --needed linux-firmware-thor
  fi
  if p=$(first_available linux-firmware); then
    in_chroot pacman -S --noconfirm --ask 4 --needed "$p" || true
  fi
else
  # Pi kernel + firmware instead of upstream's linux + limine. Package names
  # have drifted on ALARM before, so resolve each alternative.
  kernel_pkg=$(first_available linux-rpi-16k linux-rpi) ||
    { echo "no Raspberry Pi kernel package on ALARM?!" >&2; exit 1; }
  note "kernel: $kernel_pkg"

  boot_pkgs=("$kernel_pkg")
  for choice in "raspberrypi-bootloader" "firmware-raspberrypi" "raspberrypi-utils rpi-utils" "linux-firmware" "dosfstools"; do
    # shellcheck disable=SC2086
    if p=$(first_available $choice); then boot_pkgs+=("$p"); else note "boot pkg unavailable, skipped: $choice"; fi
  done
  in_chroot pacman -S --noconfirm --ask 4 --needed "${boot_pkgs[@]}"
fi

# --- 4. omarchy package set --------------------------------------------------
# Upstream base list, minus skip list, plus Pi additions — then filtered by
# what actually exists for aarch64. Misses are reported, not fatal: the report
# drives packages.skip updates.
add_list=$overlay/install/packages.add
[[ $BOARD == ayn-thor && -f $overlay/install/packages.thor.add ]] && add_list=$overlay/install/packages.thor.add
mapfile -t requested < <(
  grep -vE '^\s*(#|$)' "$upstream/install/omarchy-base.packages" |
    grep -vxFf <(grep -vE '^\s*(#|$)' "$overlay/install/packages.skip")
  grep -vE '^\s*(#|$)' "$add_list"
)
# Prefer the -bin repacks when their aarch64 builds are in the repo
# (chromium: omacom's patched build; localsend: upstream's arm64 release —
# the base list asks for the plain names, which don't exist on ALARM).
# quattro now asks for mise-bin; we ship the same arm64 binary as `mise`.
for sub in chromium=omarchy-chromium-bin localsend=localsend-bin mise-bin=mise; do
  from=${sub%%=*} to=${sub#*=}
  if pkg_available "$to"; then
    for i in "${!requested[@]}"; do
      [[ ${requested[$i]} == "$from" ]] && requested[$i]=$to
    done
  fi
done

available=() missing=()
for p in "${requested[@]}"; do
  if pkg_available "$p"; then available+=("$p"); else missing+=("$p"); fi
done
note ""
note "package resolution: ${#available[@]} available, ${#missing[@]} unavailable on aarch64"
for p in "${missing[@]}"; do note "  MISSING: $p"; done
pacman_retry -S --noconfirm --ask 4 --needed "${available[@]}"

# omarchy runtime + settings (built as arch=any, or from the aarch64 repo).
  # A Thor image without the real Quickshell package boots to a movable pointer
  # on a black background. Require it as part of the desktop, and install it
  # before Omarchy so pacman cannot satisfy the dependency with a provider shim.
  omarchy_core=(quickshell-git omarchy-keyring omarchy-settings omarchy-nvim omarchy)
core_missing=0
for p in "${omarchy_core[@]}"; do
  pkg_available "$p" || { note "  MISSING CORE: $p"; core_missing=1; }
done
if (( core_missing == 0 )); then
  pacman_retry -S --noconfirm --ask 4 --needed "${omarchy_core[@]}"
  # quickshell consumes Qt private API.  A stale AUR build can satisfy pacman
  # dependencies yet crash before main() after Qt receives a patch update.
  # Fail the image build here instead of shipping a black desktop.
  if pkg_available quickshell-git && ! in_chroot quickshell --version >/dev/null; then
    echo "quickshell cannot resolve the installed Qt ABI; rebuild quickshell-git" >&2
    exit 1
  fi
else
  echo "omarchy core packages missing — refusing to publish an incomplete desktop" >&2
  exit 1
fi

# --- 5. upstream install stages, unmodified ----------------------------------
# The omarchy package has installed upstream's install/ tree at
# /usr/share/omarchy/install; run the same stages the ISO runs in its target
# chroot. Individual scripts may fail on ARM (e.g. snapper on ext4) — that is
# logged by run_logged and tolerated; hard requirements are verified at the end.
if [[ -d $root/usr/share/omarchy/install ]]; then
  run_stage() {
    in_chroot env \
      OMARCHY_PATH=/usr/share/omarchy \
      OMARCHY_INSTALL=/usr/share/omarchy/install \
      OMARCHY_SETUP_CONTEXT=iso-chroot \
      OMARCHY_LOG_TO_STDOUT=1 \
      bash -c 'source /usr/share/omarchy/install/helpers/logging.sh; source "$1"' _ "$1" ||
      note "stage reported failure (see log above): $1"
  }
  run_stage /usr/share/omarchy/install/hardware/all.sh
  run_stage /usr/share/omarchy/install/config/all.sh
  run_stage /usr/share/omarchy/install/login/all.sh
else
  note "SKIPPING upstream install stages: /usr/share/omarchy missing"
fi

# Safety net: enable-services.sh runs under bash -eE, so one missing unit
# aborts the rest of its chain. These four are boot-critical; enabling twice
# is idempotent.
for svc in sddm.service NetworkManager.service systemd-resolved.service systemd-timesyncd.service; do
  in_chroot systemctl enable "$svc" || note "could not enable $svc"
done

# --- 6. board overlay --------------------------------------------------------
rm -f "$root/etc/mkinitcpio.conf.d/thunderbolt_module.conf"
sed -i 's/\bbtrfs-overlayfs\b//g' "$root/etc/mkinitcpio.conf.d/omarchy_hooks.conf" 2>/dev/null || true
sed -i -E 's/\b(sd-)?encrypt\b//g' "$root/etc/mkinitcpio.conf.d/omarchy_hooks.conf" 2>/dev/null || true

if [[ $BOARD == ayn-thor ]]; then
  # Vendor blobs: KERNEL + modules + firmware + busybox stub.
  thor_vendor=${THOR_VENDOR_DIR:-$here/thor-vendor}
  kmod_vendor=$here/../pkgs/aarch64-extra/linux-rocknix-sm8550/vendor
  fw_vendor=$here/../pkgs/aarch64-extra/linux-firmware-thor/vendor
  [[ -d $thor_vendor ]] || thor_vendor=$kmod_vendor
  kernel_src=${THOR_KERNEL:-}
  [[ -z $kernel_src && -f $kmod_vendor/KERNEL ]] && kernel_src=$kmod_vendor/KERNEL
  [[ -z $kernel_src && -f $thor_vendor/KERNEL ]] && kernel_src=$thor_vendor/KERNEL
  [[ -n $kernel_src && -f $kernel_src ]] || {
    echo "ayn-thor: missing KERNEL (set THOR_KERNEL or run extract.sh)" >&2
    exit 1
  }
  install -Dm644 "$kernel_src" "$root/boot/KERNEL"
  if [[ -x $here/pack-qcom-bootimg.sh ]]; then
    bash "$here/pack-qcom-bootimg.sh" --in "$root/boot/KERNEL" --out "$root/boot/KERNEL" \
      --cmdline "boot=LABEL=ROCKNIX disk=LABEL=STORAGE progress rootwait console=tty0 allow_mismatched_32bit_el0 fw_devlink.strict=1 pcie_ports=compat irqaffinity=0-2 cgroup.memory=nokmem,nosocket nosoftlockup"
  fi
  echo "$(md5sum "$root/boot/KERNEL" | awk '{print $1}')  KERNEL" >"$root/boot/KERNEL.md5"

  if [[ -d $kmod_vendor/modules/7.1.2 ]]; then
    mkdir -p "$root/usr/lib/modules"
    cp -a "$kmod_vendor/modules/7.1.2" "$root/usr/lib/modules/"
    note "thor modules: 7.1.2 from vendor"
  fi
  if [[ -d $fw_vendor/firmware ]]; then
    mkdir -p "$root/usr/lib/firmware"
    cp -a "$fw_vendor/firmware/." "$root/usr/lib/firmware/"
    note "thor firmware: copied from vendor"
  fi
  stub_vendor=$fw_vendor/stub
  [[ -d $stub_vendor ]] || stub_vendor=$thor_vendor/stub
  [[ -d $stub_vendor ]] || { echo "ayn-thor: missing busybox stub vendor" >&2; exit 1; }
  bash "$here/mk-thor-system-stub.sh" --vendor "$stub_vendor" --out "$root/boot/SYSTEM"
  echo "$(md5sum "$root/boot/SYSTEM" | awk '{print $1}')  SYSTEM" >"$root/boot/SYSTEM.md5"
  note "thor SYSTEM stub: $(wc -c <"$root/boot/SYSTEM") bytes"
  # ROCKNIX initramfs sources this after mounting /flash (USB ECM debug).
  install -Dm644 "$overlay/thor/post-flash.sh" "$root/boot/post-flash.sh"
  install -Dm644 "$overlay/thor/post-sysroot.sh" "$root/boot/post-sysroot.sh"
  install -Dm644 "$overlay/thor/omarchy-log.sh" "$root/boot/omarchy-log.sh"
  install -Dm644 "$overlay/thor/omarchy-splash.sh" "$root/boot/omarchy-splash.sh"
  install -Dm644 "$overlay/thor/thor-monitors.lua" "$root/boot/thor-monitors.lua"
  install -Dm644 "$overlay/thor/thor-apply-storage.sh" "$root/boot/thor-apply-storage.sh"
  install -Dm644 "$overlay/thor/mount-storage.sh" "$root/boot/mount-storage.sh"
  install -Dm644 "$overlay/thor/omarchy-thor-kb.c" "$root/usr/local/src/omarchy-thor-kb.c"
  install -Dm644 "$overlay/thor/omarchy-thor-gamepad-wake.c" \
    "$root/usr/local/src/omarchy-thor-gamepad-wake.c"
  install -Dm755 "$overlay/thor/omarchy-thor-type.sh" "$root/usr/local/bin/omarchy-thor-type"
  install -Dm755 "$overlay/thor/omarchy-thor-gum.sh" "$root/usr/local/lib/omarchy-thor/gum"
  install -Dm644 "$overlay/systemd/omarchy-thor-kb.service" \
    "$root/etc/systemd/system/omarchy-thor-kb.service"
  install -Dm644 "$overlay/systemd/omarchy-thor-gamepad-wake.service" \
    "$root/etc/systemd/system/omarchy-thor-gamepad-wake.service"
  install -Dm755 "$overlay/install/omarchy-thor-display-recover.sh" \
    "$root/usr/local/bin/omarchy-thor-display-recover"
  install -Dm644 "$overlay/systemd/omarchy-thor-display-recover.service" \
    "$root/etc/systemd/system/omarchy-thor-display-recover.service"
  install -Dm755 "$overlay/install/omarchy-thor-wifi-import.sh" \
    "$root/usr/local/bin/omarchy-thor-wifi-import"
  install -Dm644 "$overlay/systemd/omarchy-thor-wifi-import.service" \
    "$root/etc/systemd/system/omarchy-thor-wifi-import.service"
  install -Dm644 "$overlay/systemd/omarchy-provision-owner.service.d/thor.conf" \
    "$root/etc/systemd/system/omarchy-provision-owner.service.d/thor.conf"
  ln -sf /etc/systemd/system/omarchy-thor-kb.service \
    "$root/etc/systemd/system/multi-user.target.wants/omarchy-thor-kb.service"
  ln -sf /etc/systemd/system/omarchy-thor-gamepad-wake.service \
    "$root/etc/systemd/system/multi-user.target.wants/omarchy-thor-gamepad-wake.service"
  ln -sf /etc/systemd/system/omarchy-thor-display-recover.service \
    "$root/etc/systemd/system/multi-user.target.wants/omarchy-thor-display-recover.service"
  ln -sf /etc/systemd/system/omarchy-thor-wifi-import.service \
    "$root/etc/systemd/system/multi-user.target.wants/omarchy-thor-wifi-import.service"
  if [[ -x ${THOR_KB_BIN:-} ]]; then
    install -Dm755 "$THOR_KB_BIN" "$root/usr/local/bin/omarchy-thor-kb"
    install -Dm755 "$THOR_KB_BIN" "$root/boot/omarchy-thor-kb"
  elif in_chroot gcc -O2 -o /usr/local/bin/omarchy-thor-kb /usr/local/src/omarchy-thor-kb.c; then
    install -Dm755 "$root/usr/local/bin/omarchy-thor-kb" "$root/boot/omarchy-thor-kb"
    note "thor-kb: compiled in chroot"
  else
    note "thor-kb: compile skipped (no gcc / THOR_KB_BIN)"
  fi
  if [[ -x ${THOR_GAMEPAD_WAKE_BIN:-} ]]; then
    install -Dm755 "$THOR_GAMEPAD_WAKE_BIN" \
      "$root/usr/local/bin/omarchy-thor-gamepad-wake"
    install -Dm755 "$THOR_GAMEPAD_WAKE_BIN" \
      "$root/boot/omarchy-thor-gamepad-wake"
  elif in_chroot gcc -O2 -o /usr/local/bin/omarchy-thor-gamepad-wake \
      /usr/local/src/omarchy-thor-gamepad-wake.c; then
    install -Dm755 "$root/usr/local/bin/omarchy-thor-gamepad-wake" \
      "$root/boot/omarchy-thor-gamepad-wake"
    note "thor-gamepad-wake: compiled in chroot"
  else
    note "thor-gamepad-wake: compile skipped (no gcc / THOR_GAMEPAD_WAKE_BIN)"
  fi
  install -Dm755 "$overlay/thor/omarchy-thor-type.sh" "$root/boot/omarchy-thor-type.sh"
  install -Dm755 "$overlay/thor/omarchy-thor-gum.sh" "$root/boot/omarchy-thor-gum.sh"
  install -Dm644 "$overlay/systemd/omarchy-thor-kb.service" "$root/boot/omarchy-thor-kb.service"
  install -Dm644 "$overlay/systemd/omarchy-thor-gamepad-wake.service" \
    "$root/boot/omarchy-thor-gamepad-wake.service"
  install -Dm755 "$overlay/install/omarchy-thor-display-recover.sh" \
    "$root/boot/omarchy-thor-display-recover"
  install -Dm644 "$overlay/systemd/omarchy-thor-display-recover.service" \
    "$root/boot/omarchy-thor-display-recover.service"
  install -Dm755 "$overlay/install/omarchy-thor-wifi-import.sh" \
    "$root/boot/omarchy-thor-wifi-import"
  install -Dm644 "$overlay/systemd/omarchy-thor-wifi-import.service" \
    "$root/boot/omarchy-thor-wifi-import.service"
  install -Dm644 "$overlay/systemd/omarchy-provision-owner.service.d/thor.conf" \
    "$root/boot/omarchy-provision-owner-thor.conf"
  install -Dm644 "$overlay/thor/blacklist-qcom-iris.conf" \
    "$root/boot/blacklist-qcom-iris.conf"
  install -Dm644 "$overlay/thor/blacklist-qcom-iris.conf" \
    "$root/etc/modprobe.d/blacklist-qcom-iris.conf"

  # Optional debug-card provisioning. Release CI does not set these inputs, so
  # published images contain no credentials, keys, or passwordless-sudo marker.
  if [[ -n ${THOR_SSH_PUBKEY:-} && -f ${THOR_SSH_PUBKEY} ]]; then
    install -Dm644 "$THOR_SSH_PUBKEY" "$root/boot/omarchy-thor-debug.pub"
  fi
  if [[ -n ${THOR_WIFI_FILE:-} && -f ${THOR_WIFI_FILE} ]]; then
    install -Dm600 "$THOR_WIFI_FILE" "$root/boot/omarchy-thor-wifi"
  fi
  if [[ ${THOR_PASSWORDLESS_SUDO:-0} == 1 ]]; then
    : >"$root/boot/omarchy-thor-passwordless-sudo"
  fi
  install -Dm644 "$overlay/thor/20-ayn-thor.uwsm" "$root/boot/20-ayn-thor.uwsm"
  install -Dm644 "$overlay/thor/20-ayn-thor.uwsm" "$root/usr/share/uwsm/env.d/20-ayn-thor"
  install -Dm755 "$overlay/thor/omarchy-thor-wait-dri.sh" \
    "$root/usr/local/bin/omarchy-thor-wait-dri"
  install -Dm755 "$overlay/thor/omarchy-thor-wait-dri.sh" \
    "$root/boot/omarchy-thor-wait-dri.sh"
  install -Dm644 "$overlay/systemd/sddm.service.d/thor.conf" \
    "$root/etc/systemd/system/sddm.service.d/thor.conf"
  install -Dm644 "$overlay/systemd/sddm.service.d/thor.conf" \
    "$root/boot/sddm-thor.conf"
  install -Dm644 "$overlay/thor/sddm-hyprland.lua" \
    "$root/usr/share/sddm/hyprland.lua"
  install -Dm644 "$overlay/thor/sddm-hyprland.lua" \
    "$root/boot/sddm-hyprland.lua"
  install -Dm644 "$overlay/thor/sddm-wayland.conf" \
    "$root/etc/sddm.conf.d/thor-wayland.conf"
  install -Dm644 "$overlay/thor/sddm-wayland.conf" \
    "$root/boot/sddm-wayland.conf"
  install -Dm755 "$overlay/thor/omarchy-thor-greeter.sh" \
    "$root/usr/local/bin/omarchy-thor-greeter"
  install -Dm755 "$overlay/thor/omarchy-thor-greeter.sh" \
    "$root/boot/omarchy-thor-greeter.sh"
  install -Dm755 "$overlay/thor/omarchy-thor-outputs.sh" \
    "$root/usr/local/bin/omarchy-thor-outputs"
  install -Dm755 "$overlay/thor/omarchy-thor-outputs.sh" \
    "$root/boot/omarchy-thor-outputs.sh"
  install -Dm755 "$overlay/thor/omarchy-thor-session.sh" \
    "$root/usr/local/bin/omarchy-thor-session"
  install -Dm755 "$overlay/thor/omarchy-thor-session.sh" \
    "$root/boot/omarchy-thor-session.sh"
  install -Dm755 "$overlay/thor/omarchy-thor-desktop.sh" \
    "$root/usr/local/bin/omarchy-thor-desktop"
  install -Dm755 "$overlay/thor/omarchy-thor-desktop.sh" \
    "$root/boot/omarchy-thor-desktop.sh"
  install -Dm755 "$overlay/thor/omarchy-thor-osk.sh" \
    "$root/usr/local/bin/omarchy-thor-osk"
  install -Dm755 "$overlay/thor/omarchy-thor-osk.sh" \
    "$root/boot/omarchy-thor-osk.sh"
  install -Dm755 "$overlay/thor/omarchy-thor-desktop-log.sh" \
    "$root/usr/local/bin/omarchy-thor-desktop-log"
  install -Dm755 "$overlay/thor/omarchy-thor-desktop-log.sh" \
    "$root/boot/omarchy-thor-desktop-log.sh"
  install -Dm644 "$overlay/systemd/omarchy-thor-desktop-log.service" \
    "$root/etc/systemd/system/omarchy-thor-desktop-log.service"
  install -Dm644 "$overlay/systemd/omarchy-thor-desktop-log.service" \
    "$root/boot/omarchy-thor-desktop-log.service"
  ln -sf /etc/systemd/system/omarchy-thor-desktop-log.service \
    "$root/etc/systemd/system/graphical.target.wants/omarchy-thor-desktop-log.service"
  install -Dm644 "$overlay/thor/omarchy-thor.desktop" \
    "$root/usr/local/share/wayland-sessions/omarchy-thor.desktop"
  install -Dm644 "$overlay/thor/omarchy-thor.desktop" \
    "$root/boot/omarchy-thor.desktop"
  install -Dm755 "$overlay/thor/omarchy-thor-desktop-fallback.sh" \
    "$root/usr/local/bin/omarchy-thor-desktop-fallback"
  install -Dm755 "$overlay/thor/omarchy-thor-desktop-fallback.sh" \
    "$root/boot/omarchy-thor-desktop-fallback.sh"
  install -Dm644 "$overlay/systemd/omarchy-thor-desktop-fallback.service" \
    "$root/etc/systemd/system/omarchy-thor-desktop-fallback.service"
  install -Dm644 "$overlay/systemd/omarchy-thor-desktop-fallback.service" \
    "$root/boot/omarchy-thor-desktop-fallback.service"
  ln -sf /etc/systemd/system/omarchy-thor-desktop-fallback.service \
    "$root/etc/systemd/system/graphical.target.wants/omarchy-thor-desktop-fallback.service"
  # load_splash prints "Initializing" until this exists on STORAGE.
  : >"$root/.configured"
  mkdir -p "$root/flash"

  mkdir -p "$root/usr/lib/udev/hwdb.d" "$root/etc/udev/rules.d" \
    "$root/usr/share/inputplumber/devices" "$root/usr/share/alsa"
  install -Dm644 "$overlay/thor/61-thor-ft5x06.hwdb" \
    "$root/usr/lib/udev/hwdb.d/61-thor-ft5x06.hwdb"
  install -Dm644 "$overlay/thor/99-thor-touch-calibration.rules" \
    "$root/etc/udev/rules.d/99-thor-touch-calibration.rules"
  install -Dm644 "$overlay/thor/02-ayn-thor-controller.yaml" \
    "$root/usr/share/inputplumber/devices/02-ayn-thor-controller.yaml"
  if [[ -d $overlay/thor/alsa/ucm2 ]]; then
    mkdir -p "$root/usr/share/alsa/ucm2"
    cp -a "$overlay/thor/alsa/ucm2/." "$root/usr/share/alsa/ucm2/"
  fi
  install -Dm755 "$overlay/install/omarchy-thor-usb-gadget.sh" \
    "$root/usr/local/bin/omarchy-thor-usb-gadget"
  install -Dm644 "$overlay/systemd/omarchy-thor-usb-gadget.service" \
    "$root/etc/systemd/system/omarchy-thor-usb-gadget.service"
  ln -sf /etc/systemd/system/omarchy-thor-usb-gadget.service \
    "$root/etc/systemd/system/multi-user.target.wants/omarchy-thor-usb-gadget.service"
  if [[ -f $root/usr/lib/systemd/system/sshd.service ]]; then
    ln -sf /usr/lib/systemd/system/sshd.service \
      "$root/etc/systemd/system/multi-user.target.wants/sshd.service"
  fi
  in_chroot bash <"$overlay/install/hardware/ayn-thor.sh"
  note "boot kernel: KERNEL (ANDROID! ABL)"
else
  install -Dm644 "$overlay/boot/config.txt" "$root/boot/config.txt"
  install -Dm644 "$overlay/boot/cmdline.txt" "$root/boot/cmdline.txt"
  sed -i "s/@ROOT_PARTUUID@/$DISK_ID-02/" "$root/boot/cmdline.txt"

  kernel_img=""
  for cand in kernel_2712.img kernel8.img; do
    [[ -f $root/boot/$cand ]] && { kernel_img=$cand; break; }
  done
  [[ -n $kernel_img ]] || { echo "no kernel*.img on the boot partition?!" >&2; exit 1; }
  sed -i "s/^kernel=.*/kernel=$kernel_img/" "$root/boot/config.txt"
  note "boot kernel: $kernel_img"

  if in_chroot mkinitcpio -P -S autodetect; then
    initramfs=$(ls "$root/boot" | grep -E "^initramfs-${kernel_pkg}(-16k)?\.img$" | head -1 || true)
    [[ -z $initramfs ]] && initramfs=$(ls "$root/boot" | grep -E '^initramfs-.*\.img$' | grep -v fallback | head -1 || true)
    if [[ -n $initramfs ]]; then
      echo "initramfs $initramfs followkernel" >>"$root/boot/config.txt"
      note "initramfs: $initramfs"
    fi
  else
    note "mkinitcpio failed — booting without initramfs (kernel mounts ext4 directly)"
  fi
  in_chroot bash <"$overlay/install/hardware/rpi-cm5.sh"
fi

# Identity + locale (the ISO gets these from archinstall; first boot lets the
# owner change hostname/timezone via omarchy-provision-owner).
echo omarchy >"$root/etc/hostname"
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$root/etc/locale.gen"
in_chroot locale-gen
echo 'LANG=en_US.UTF-8' >"$root/etc/locale.conf"
ln -sf /usr/share/zoneinfo/UTC "$root/etc/localtime"

# The ALARM tarball ships alarm/root with default passwords — drop the stock
# user; root gets the owner's password during first-boot provisioning.
in_chroot userdel -r alarm 2>/dev/null || true
in_chroot passwd -l root

# SDDM greeter config, mirroring the ISO's configure_login for a
# deferred-provisioning install (no autologin — no user exists yet;
# omarchy-provision-owner writes autologin state once the owner is created).
install -d "$root/etc/sddm.conf.d"
printf '[Theme]\nCurrent=omarchy\n\n[Users]\nRememberLastUser=true\nRememberLastSession=true\n' \
  >"$root/etc/sddm.conf.d/99-omarchy-login.conf"

# systemd-resolved stub resolver (done from outside the chroot, as upstream
# does — arch-chroot bind-mounts resolv.conf while stages run).
ln -sf ../run/systemd/resolve/stub-resolv.conf "$root/etc/resolv.conf.image"

# --- 7. first-boot provisioning (the "install" part of the install image) ----
prov="$root/var/lib/omarchy/provisioning"
install -d -m 755 "$prov"
touch "$prov/pending"
if [[ -f $root/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service ]]; then
  install -Dm644 "$root/usr/share/omarchy/install/provisioning/omarchy-provision-owner.service" \
    "$root/etc/systemd/system/omarchy-provision-owner.service"
  install -d "$root/etc/systemd/system/multi-user.target.wants"
  ln -sf /etc/systemd/system/omarchy-provision-owner.service \
    "$root/etc/systemd/system/multi-user.target.wants/omarchy-provision-owner.service"
  note "first-boot provisioning armed (omarchy-provision-owner on tty1)"
else
  note "provisioning service missing — first boot will land on SDDM with no user!"
fi

# Node tarball stash for offline user finalization. upstream's mise-work.sh
# globs node-v*-linux-x64.tar.gz (x86 ISO assumption); stage the arm64 build
# under both its real name and the glob-compatible name so first boot works
# offline. The content of both is arm64 — only the second name is a shim.
if [[ -n $NODE_TARBALL_PATH && -f $NODE_TARBALL_PATH ]]; then
  install -d -m 755 "$prov/packages"
  base=$(basename "$NODE_TARBALL_PATH")
  install -m 644 "$NODE_TARBALL_PATH" "$prov/packages/$base"
  compat=${base/linux-arm64/linux-x64}
  [[ $compat != "$base" ]] && ln -f "$prov/packages/$base" "$prov/packages/$compat"
  note "node tarball staged: $base (+ compat name $compat)"
else
  note "no node tarball staged — first-boot finalization will need the network for node"
fi

# First-boot root filesystem growth: the image is IMG_SIZE but the USB stick
# is probably bigger. sfdisk+resize2fs from base, no extra deps.
install -Dm755 "$overlay/install/omarchy-cm5-grow-root.sh" "$root/usr/local/bin/omarchy-cm5-grow-root"
install -Dm644 "$overlay/systemd/omarchy-cm5-grow-root.service" \
  "$root/etc/systemd/system/omarchy-cm5-grow-root.service"
ln -sf /etc/systemd/system/omarchy-cm5-grow-root.service \
  "$root/etc/systemd/system/multi-user.target.wants/omarchy-cm5-grow-root.service"

# USB-boot installer is a Pi/CM5 flow (eMMC/NVMe). Thor keeps Android on UFS
# and boots Linux from a spare SD — do not offer install-to-disk there.
if [[ $BOARD != ayn-thor ]]; then
  install -Dm755 "$overlay/install/omarchy-cm5-install-to-disk.sh" \
    "$root/usr/local/bin/omarchy-cm5-install-to-disk"
  install -Dm644 "$overlay/installer/disk-partitioning.sh" \
    "$root/usr/local/share/omarchy-cm5/disk-partitioning.sh"
  install -Dm644 "$overlay/installer/pi-disk-layout.sh" \
    "$root/usr/local/share/omarchy-cm5/pi-disk-layout.sh"
  install -Dm644 "$overlay/systemd/omarchy-cm5-install-to-disk.service" \
    "$root/etc/systemd/system/omarchy-cm5-install-to-disk.service"
  ln -sf /etc/systemd/system/omarchy-cm5-install-to-disk.service \
    "$root/etc/systemd/system/multi-user.target.wants/omarchy-cm5-install-to-disk.service"
fi

# --- 8. finalize -------------------------------------------------------------
# On-device [omarchy] repo: the build consumed a baked-in local pool; deployed
# devices pull package updates from the hosted release repo instead (published
# by pkgs/publish-repo.sh / the build-arm-packages workflow). Dropping the
# baked pool saves ~450 MB in the image.
DEVICE_REPO_URL=${DEVICE_REPO_URL:-https://github.com/TensorFleet/omarchy-cm5/releases/download/aarch64-pkgs}
if [[ -d $root/opt/omarchy-repo && -n $DEVICE_REPO_URL ]]; then
  sed -i "s|^Server = file:///opt/omarchy-repo|Server = $DEVICE_REPO_URL|" "$root/etc/pacman.conf"
  rm -rf "$root/opt/omarchy-repo"
  note "device [omarchy] repo: $DEVICE_REPO_URL (baked pool removed)"
fi

umount "$root/var/cache/pacman/pkg"
rm -rf "$hostcache"
rm -f "$root/usr/bin/qemu-aarch64-static"
: >"$root/etc/machine-id"
mv "$root/etc/resolv.conf.image" "$root/etc/resolv.conf" 2>/dev/null || true

# fstab: written by hand, NOT genfstab — inside a build container genfstab
# can't resolve UUIDs (no udev/blkid data) and falls back to the build host's
# loop device paths (/dev/loopXp1), and it also copies any swap active on the
# build host into the image. Both PARTUUIDs are deterministic ($DISK_ID).
cat >>"$root/etc/fstab" <<EOF
PARTUUID=$DISK_ID-02  /      ext4  defaults  0 1
PARTUUID=$DISK_ID-01  /boot  vfat  defaults  0 2
EOF

note ""
note "=== image summary ==="
note "board:     $BOARD"
if [[ $BOARD == ayn-thor ]]; then
  note "kernel:    KERNEL ($(wc -c <"$root/boot/KERNEL") bytes ANDROID!)"
  note "system:    SYSTEM stub ($(wc -c <"$root/boot/SYSTEM") bytes)"
else
  note "kernel:    $(ls "$root/boot"/kernel*.img 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
fi
note "omarchy:   $(cat "$root/usr/share/omarchy/version" 2>/dev/null || echo MISSING)"
note "disk id:   0x$DISK_ID (root PARTUUID $DISK_ID-02)"
df -h "$root" | tee -a "$REPORT"

umount -R "$root"
losetup -d "$loop"
trap - EXIT

echo "image ready: $IMG"
echo "report:      $REPORT"
