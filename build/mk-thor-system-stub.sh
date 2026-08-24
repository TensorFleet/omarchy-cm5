#!/bin/bash
# LibreELEC-shaped SYSTEM squashfs. The ROCKNIX KERNEL initramfs loop-mounts
# /flash/SYSTEM as /sysroot, then:
#   chroot /sysroot /usr/sbin/kernel-overlays-setup
#   switch_root /sysroot /usr/lib/systemd/systemd
# Our /init is never exec'd. The "systemd" path must be the Arch pivot.
#
# Usage:
#   mk-thor-system-stub.sh --vendor DIR --out SYSTEM
set -euo pipefail

vendor="" out=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --vendor) vendor=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n $vendor && -d $vendor && -n $out ]] || {
  echo "usage: $0 --vendor DIR --out SYSTEM" >&2
  exit 2
}
for f in usr/lib/ld-linux-aarch64.so.1 usr/lib/libc.so.6; do
  [[ -e $vendor/$f ]] || { echo "missing $vendor/$f" >&2; exit 1; }
done
# Prefer the LibreELEC initramfs busybox (NEEDED: libc only). The ALARM
# busybox also needs libm.so.6; a previous stub omitted it and PID 1 exited
# 127 → "Attempted to kill init".
bb=$vendor/usr/bin/busybox-le
[[ -x $bb ]] || bb=$vendor/usr/bin/busybox
[[ -x $bb ]] || { echo "missing busybox in $vendor" >&2; exit 1; }

command -v mksquashfs >/dev/null || { echo "need mksquashfs" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp"/{bin,lib,proc,sys,dev,run,tmp,flash,storage,sysroot,update,sbin}
mkdir -p "$tmp/usr/bin" "$tmp/usr/sbin" "$tmp/usr/lib/systemd" "$tmp/etc"
mkdir -p "$tmp/usr/lib/kernel-overlays/base/lib/modules/7.1.2"

cp -a "$bb" "$tmp/bin/busybox"
cp -a "$bb" "$tmp/usr/bin/busybox"
cp -a "$vendor/usr/lib/ld-linux-aarch64.so.1" "$tmp/lib/ld-linux-aarch64.so.1"
cp -a "$vendor/usr/lib/libc.so.6" "$tmp/lib/libc.so.6"
mkdir -p "$tmp/usr/lib"
cp -a "$vendor/usr/lib/ld-linux-aarch64.so.1" "$tmp/usr/lib/ld-linux-aarch64.so.1"
cp -a "$vendor/usr/lib/libc.so.6" "$tmp/usr/lib/libc.so.6"
if [[ -e $vendor/usr/lib/libm.so.6 ]]; then
  cp -a "$vendor/usr/lib/libm.so.6" "$tmp/lib/libm.so.6"
  cp -a "$vendor/usr/lib/libm.so.6" "$tmp/usr/lib/libm.so.6"
fi
chmod 755 "$tmp/bin/busybox" "$tmp/lib/ld-linux-aarch64.so.1"
for app in sh ash mount umount switch_root mkdir ls cat sleep date dmesg tail mv cp sync head chroot ln chmod; do
  ln -sf busybox "$tmp/bin/$app"
done
ln -sf /bin/busybox "$tmp/usr/bin/sh"
: >"$tmp/usr/lib/kernel-overlays/base/lib/modules/7.1.2/.keep"

cat >"$tmp/etc/os-release" <<'EOF'
NAME="Omarchy"
OS_NAME=Omarchy
VERSION="thor-stub"
ID=omarchy
OS_ARCH=aarch64
HW_DEVICE=ayn-thor
GIT_ORGANIZATION=basecamp
EOF
printf 'Omarchy\nAYN Thor\n' >"$tmp/etc/issue"
printf 'Omarchy Thor\n' >"$tmp/etc/motd"

overlay=$(cd "$(dirname "${BASH_SOURCE[0]}")/../overlay" && pwd)
if [[ -f $overlay/thor/omarchy-log.sh ]]; then
  install -m644 "$overlay/thor/omarchy-log.sh" "$tmp/bin/omarchy-log.sh"
fi

cat >"$tmp/usr/sbin/kernel-overlays-setup" <<'EOF'
#!/bin/busybox sh
. /bin/omarchy-log.sh 2>/dev/null || true
omarchy_log "kernel-overlays-setup (chroot)" 2>/dev/null || true
omarchy_dump kernel-overlays-setup 2>/dev/null || true
exit 0
EOF
chmod 755 "$tmp/usr/sbin/kernel-overlays-setup"

# PID 1 after LibreELEC switch_root. Keep this script tiny: a missing
# helper must not exit 127 and panic the kernel.
cat >"$tmp/usr/lib/systemd/systemd" <<'EOF'
#!/bin/busybox sh
echo "omarchy-thor: pivot" >/dev/kmsg 2>/dev/null
echo "omarchy-thor: pivot" >/dev/console 2>/dev/null
. /bin/omarchy-log.sh 2>/dev/null || true
omarchy_log "pivot: entered SYSTEM systemd shim" 2>/dev/null || true
omarchy_dump pivot-before 2>/dev/null || true
new=/storage
init=
if [ -x "$new/usr/lib/systemd/systemd" ]; then
  init=/usr/lib/systemd/systemd
elif [ -x "$new/sbin/init" ]; then
  init=/sbin/init
fi
# STORAGE is mounted by here. post-sysroot runs too early (before ext4).
if [ -f /flash/thor-apply-storage.sh ]; then
  . /flash/thor-apply-storage.sh
fi
if [ -n "$init" ]; then
  if /bin/busybox switch_root "$new" "$init"; then
    exit 0
  fi
  echo "omarchy-thor: switch_root failed, mount-move+chroot" >/dev/console
  for d in dev proc sys run flash tmp; do
    mkdir -p "$new/$d"
    /bin/busybox mount --move "/$d" "$new/$d" 2>/dev/null || true
  done
  exec /bin/busybox chroot "$new" "$init"
fi
echo "omarchy-thor: no Arch init on /storage" >/dev/console
exec /bin/busybox sh
EOF
chmod 755 "$tmp/usr/lib/systemd/systemd"
ln -sf /usr/lib/systemd/systemd "$tmp/sbin/init"

cat >"$tmp/init" <<'EOF'
#!/bin/busybox sh
exec /usr/lib/systemd/systemd
EOF
chmod 755 "$tmp/init"

rm -f "$out"
mksquashfs "$tmp" "$out" -comp zstd -noappend -all-root -quiet
echo "SYSTEM stub: $out ($(wc -c <"$out") bytes) busybox=$(basename "$bb")"
