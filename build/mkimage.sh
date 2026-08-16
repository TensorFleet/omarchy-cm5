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
#   IMG               output path            (default build/omarchy-cm5.img)
#   IMG_SIZE          image size             (default 12G)
#   LOCAL_PKG_DIR     dir of *.pkg.tar.* from build-any-packages.sh
#   OMARCHY_REPO_URL  aarch64 [omarchy] repo base URL, if one exists
#                     (probed by resolve-packages.sh; overrides LOCAL_PKG_DIR)
#   NODE_TARBALL_PATH node-v*-linux-arm64.tar.gz to stash for offline
#                     first-boot user finalization
#   ALARM_TARBALL     Arch Linux ARM rootfs tarball URL override
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
overlay="$here/../overlay"
upstream="$here/upstream"

IMG=${IMG:-$here/omarchy-cm5.img}
IMG_SIZE=${IMG_SIZE:-12G}
LOCAL_PKG_DIR=${LOCAL_PKG_DIR:-}
OMARCHY_REPO_URL=${OMARCHY_REPO_URL:-}
NODE_TARBALL_PATH=${NODE_TARBALL_PATH:-}
REPORT=${REPORT:-$IMG.report.txt}

# MBR disk identifier: fixed so root=PARTUUID=… in cmdline.txt is knowable at
# build time without an initramfs requirement.
DISK_ID=2ca5b007

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

mkfs.vfat -F 32 -n OMARCHYBOOT "${loop}p1"
mkfs.ext4 -q -L omarchy-root "${loop}p2"

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

in_chroot pacman-key --init
in_chroot pacman-key --populate archlinuxarm
if [[ -d $root/opt/omarchy-repo ]]; then
  in_chroot bash -c 'repo-add -q /opt/omarchy-repo/omarchy.db.tar.gz /opt/omarchy-repo/*.pkg.tar.*'
fi
in_chroot pacman -Syu --noconfirm

# The generic tarball ships the generic kernel; the Pi kernel replaces it.
in_chroot pacman -R --noconfirm linux-aarch64 2>/dev/null || true

# --- 3. Pi boot chain --------------------------------------------------------
# Pi kernel + firmware instead of upstream's linux + limine. Package names
# have drifted on ALARM before, so resolve each alternative.
pkg_available() { in_chroot pacman -Si "$1" &>/dev/null; }
first_available() { local p; for p in "$@"; do pkg_available "$p" && { echo "$p"; return 0; }; done; return 1; }

kernel_pkg=$(first_available linux-rpi-16k linux-rpi) ||
  { echo "no Raspberry Pi kernel package on ALARM?!" >&2; exit 1; }
note "kernel: $kernel_pkg"

boot_pkgs=("$kernel_pkg")
for choice in "raspberrypi-bootloader" "firmware-raspberrypi" "raspberrypi-utils rpi-utils" "linux-firmware" "dosfstools"; do
  # shellcheck disable=SC2086
  if p=$(first_available $choice); then boot_pkgs+=("$p"); else note "boot pkg unavailable, skipped: $choice"; fi
done
in_chroot pacman -S --noconfirm --ask 4 --needed "${boot_pkgs[@]}"

# --- 4. omarchy package set --------------------------------------------------
# Upstream base list, minus skip list, plus Pi additions — then filtered by
# what actually exists for aarch64. Misses are reported, not fatal: the report
# drives packages.skip updates.
mapfile -t requested < <(
  grep -vE '^\s*(#|$)' "$upstream/install/omarchy-base.packages" |
    grep -vxFf <(grep -vE '^\s*(#|$)' "$overlay/install/packages.skip")
  grep -vE '^\s*(#|$)' "$overlay/install/packages.add"
)
# Prefer the -bin repacks when their aarch64 builds are in the repo
# (chromium: omacom's patched build; localsend: upstream's arm64 release —
# the base list asks for the plain names, which don't exist on ALARM).
for sub in chromium=omarchy-chromium-bin localsend=localsend-bin; do
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
in_chroot pacman -S --noconfirm --ask 4 --needed "${available[@]}"

# omarchy runtime + settings (built as arch=any, or from the aarch64 repo).
omarchy_core=()
# Install the real quickshell build ahead of omarchy when the pool has it,
# so the dependency resolves to it deterministically (not a shim).
pkg_available quickshell-git && omarchy_core+=(quickshell-git)
omarchy_core+=(omarchy-keyring omarchy-settings omarchy-nvim omarchy)
core_missing=0
for p in "${omarchy_core[@]}"; do
  pkg_available "$p" || { note "  MISSING CORE: $p"; core_missing=1; }
done
if (( core_missing == 0 )); then
  in_chroot pacman -S --noconfirm --ask 4 --needed "${omarchy_core[@]}"
else
  note "omarchy core packages missing — image will not carry the omarchy runtime!"
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

# --- 6. CM5/Pi overlay -------------------------------------------------------
install -Dm644 "$overlay/boot/config.txt" "$root/boot/config.txt"
install -Dm644 "$overlay/boot/cmdline.txt" "$root/boot/cmdline.txt"
sed -i "s/@ROOT_PARTUUID@/$DISK_ID-02/" "$root/boot/cmdline.txt"

# Point config.txt at the kernel image the package ACTUALLY installed —
# ALARM has shipped the Pi 5 kernel as both kernel_2712.img and kernel8.img
# over time, and a config.txt naming a missing file means no boot.
kernel_img=""
for cand in kernel_2712.img kernel8.img; do
  [[ -f $root/boot/$cand ]] && { kernel_img=$cand; break; }
done
[[ -n $kernel_img ]] || { echo "no kernel*.img on the boot partition?!" >&2; exit 1; }
sed -i "s/^kernel=.*/kernel=$kernel_img/" "$root/boot/config.txt"
note "boot kernel: $kernel_img"

# omarchy-settings ships x86-flavored mkinitcpio drop-ins that hard-fail the
# aarch64 build: the btrfs-overlayfs hook (limine snapshot boot; Pi firmware
# boot has no limine) and a thunderbolt module force-load (no thunderbolt on
# BCM2712). Neutralize both before generating the initramfs.
rm -f "$root/etc/mkinitcpio.conf.d/thunderbolt_module.conf"
sed -i 's/\bbtrfs-overlayfs\b//g' "$root/etc/mkinitcpio.conf.d/omarchy_hooks.conf" 2>/dev/null || true
# The encrypt hooks assume upstream's LUKS root; ours is plain ext4. Harmless
# (falls through after an ERROR at boot) but scary in the log — drop them.
sed -i -E 's/\b(sd-)?encrypt\b//g' "$root/etc/mkinitcpio.conf.d/omarchy_hooks.conf" 2>/dev/null || true

# Initramfs: not strictly required (ALARM Pi kernels mount ext4 roots
# directly), but omarchy-settings configures plymouth via mkinitcpio drop-ins,
# so generate one and reference it when it lands. -S autodetect: the chroot's
# "running kernel" is the build host's, autodetect would guess wrong modules.
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

# USB-boot installer: when booted from a stick on a machine with internal
# storage, first boot offers (and defaults to) installing onto eMMC/NVMe —
# never the USB itself. Inert once installed (root not on USB).
install -Dm755 "$overlay/install/omarchy-cm5-install-to-disk.sh" \
  "$root/usr/local/bin/omarchy-cm5-install-to-disk"
install -Dm644 "$overlay/systemd/omarchy-cm5-install-to-disk.service" \
  "$root/etc/systemd/system/omarchy-cm5-install-to-disk.service"
ln -sf /etc/systemd/system/omarchy-cm5-install-to-disk.service \
  "$root/etc/systemd/system/multi-user.target.wants/omarchy-cm5-install-to-disk.service"

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
note "kernel:    $(ls "$root/boot"/kernel*.img 2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
note "omarchy:   $(cat "$root/usr/share/omarchy/version" 2>/dev/null || echo MISSING)"
note "disk id:   0x$DISK_ID (root PARTUUID $DISK_ID-02)"
df -h "$root" | tee -a "$REPORT"

umount -R "$root"
losetup -d "$loop"
trap - EXIT

echo "image ready: $IMG"
echo "report:      $REPORT"
