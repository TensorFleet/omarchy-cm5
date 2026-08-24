#!/bin/bash
# Rebuild only FAT boot files (KERNEL cmdline + SYSTEM stub + post-flash.sh).
# Does not rebuild the 12G rootfs.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
out=${1:-$here/thor-boot-update}
kmod=$repo/pkgs/aarch64-extra/linux-rocknix-sm8550/vendor
fw=$repo/pkgs/aarch64-extra/linux-firmware-thor/vendor
stub=$fw/stub
[[ -f $kmod/KERNEL ]] || { echo "missing $kmod/KERNEL" >&2; exit 1; }
[[ -x $stub/usr/bin/busybox ]] || { echo "missing stub busybox" >&2; exit 1; }
mkdir -p "$out"
bash "$here/pack-qcom-bootimg.sh" --in "$kmod/KERNEL" --out "$out/KERNEL" \
  --cmdline "boot=LABEL=ROCKNIX disk=LABEL=STORAGE progress rootwait console=tty0 allow_mismatched_32bit_el0 fw_devlink.strict=1 pcie_ports=compat irqaffinity=0-2 cgroup.memory=nokmem,nosocket nosoftlockup"
bash "$here/mk-thor-system-stub.sh" --vendor "$stub" --out "$out/SYSTEM"
md5sum "$out/KERNEL" | awk '{print $1"  KERNEL"}' >"$out/KERNEL.md5"
md5sum "$out/SYSTEM" | awk '{print $1"  SYSTEM"}' >"$out/SYSTEM.md5"
install -m644 "$repo/overlay/thor/post-flash.sh" "$out/post-flash.sh"
install -m644 "$repo/overlay/thor/post-sysroot.sh" "$out/post-sysroot.sh"
install -m644 "$repo/overlay/thor/omarchy-log.sh" "$out/omarchy-log.sh"
install -m644 "$repo/overlay/thor/omarchy-splash.sh" "$out/omarchy-splash.sh"
install -m644 "$repo/overlay/thor/thor-apply-storage.sh" "$out/thor-apply-storage.sh"
install -m644 "$repo/overlay/thor/mount-storage.sh" "$out/mount-storage.sh"
install -m644 "$repo/overlay/thor/thor-monitors.lua" "$out/thor-monitors.lua"
install -m755 "$repo/overlay/thor/omarchy-thor-type.sh" "$out/omarchy-thor-type.sh"
install -m755 "$repo/overlay/thor/omarchy-thor-gum.sh" "$out/omarchy-thor-gum.sh"
install -m644 "$repo/overlay/systemd/omarchy-thor-kb.service" "$out/omarchy-thor-kb.service"
install -m644 "$repo/overlay/systemd/omarchy-thor-gamepad-wake.service" \
  "$out/omarchy-thor-gamepad-wake.service"
install -m755 "$repo/overlay/install/omarchy-thor-display-recover.sh" \
  "$out/omarchy-thor-display-recover"
install -m644 "$repo/overlay/systemd/omarchy-thor-display-recover.service" \
  "$out/omarchy-thor-display-recover.service"
install -m755 "$repo/overlay/install/omarchy-thor-wifi-import.sh" \
  "$out/omarchy-thor-wifi-import"
install -m644 "$repo/overlay/systemd/omarchy-thor-wifi-import.service" \
  "$out/omarchy-thor-wifi-import.service"
install -m644 "$repo/overlay/systemd/omarchy-provision-owner.service.d/thor.conf" \
  "$out/omarchy-provision-owner-thor.conf"
fwbin=$repo/pkgs/aarch64-extra/linux-firmware-thor/vendor/firmware
if [[ -d $fwbin ]]; then
  rm -rf "$out/firmware"
  mkdir -p "$out/firmware"
  cp -a "$fwbin/." "$out/firmware/"
fi
install -m644 "$repo/overlay/thor/20-ayn-thor.uwsm" "$out/20-ayn-thor.uwsm"
install -m755 "$repo/overlay/thor/omarchy-thor-wait-dri.sh" "$out/omarchy-thor-wait-dri.sh"
install -m644 "$repo/overlay/systemd/sddm.service.d/thor.conf" "$out/sddm-thor.conf"
install -m644 "$repo/overlay/thor/sddm-hyprland.lua" "$out/sddm-hyprland.lua"
install -m644 "$repo/overlay/thor/sddm-wayland.conf" "$out/sddm-wayland.conf"
install -m644 "$repo/overlay/thor/sddm-autologin.conf" "$out/sddm-autologin.conf"
install -m755 "$repo/overlay/thor/omarchy-thor-greeter.sh" "$out/omarchy-thor-greeter.sh"
install -m755 "$repo/overlay/thor/omarchy-thor-outputs.sh" "$out/omarchy-thor-outputs.sh"
install -m755 "$repo/overlay/thor/omarchy-thor-desktop.sh" "$out/omarchy-thor-desktop.sh"
install -m755 "$repo/overlay/thor/omarchy-thor-session.sh" "$out/omarchy-thor-session.sh"
install -m755 "$repo/overlay/thor/omarchy-thor-osk.sh" "$out/omarchy-thor-osk.sh"
if [[ -x ${THOR_WVKBD:-} ]]; then
  install -m755 "$THOR_WVKBD" "$out/wvkbd-mobintl"
elif [[ -x $out/wvkbd-mobintl ]]; then
  :
elif command -v wvkbd-mobintl >/dev/null; then
  install -m755 "$(command -v wvkbd-mobintl)" "$out/wvkbd-mobintl"
fi
install -m755 "$repo/overlay/thor/omarchy-thor-desktop-log.sh" "$out/omarchy-thor-desktop-log.sh"
install -m644 "$repo/overlay/systemd/omarchy-thor-desktop-log.service" \
  "$out/omarchy-thor-desktop-log.service"
install -m644 "$repo/overlay/thor/omarchy-thor.desktop" "$out/omarchy-thor.desktop"
install -m755 "$repo/overlay/thor/omarchy-thor-desktop-fallback.sh" \
  "$out/omarchy-thor-desktop-fallback.sh"
install -m644 "$repo/overlay/systemd/omarchy-thor-desktop-fallback.service" \
  "$out/omarchy-thor-desktop-fallback.service"
install -m755 "$repo/overlay/install/omarchy-thor-usb-gadget.sh" \
  "$out/omarchy-thor-usb-gadget.sh"
install -m644 "$repo/overlay/systemd/omarchy-thor-usb-gadget.service" \
  "$out/omarchy-thor-usb-gadget.service"
# Optional debug inputs must describe this invocation, not a previous run in
# the same output directory. In particular, never retain plaintext Wi-Fi or a
# passwordless-sudo marker implicitly.
rm -f "$out/omarchy-thor-debug.pub" "$out/openssh-thor.pkg.tar.xz" \
  "$out/omarchy-thor-wifi" "$out/omarchy-thor-passwordless-sudo"
if [[ -n ${THOR_SSH_PUBKEY:-} && -f $THOR_SSH_PUBKEY ]]; then
  install -m644 "$THOR_SSH_PUBKEY" "$out/omarchy-thor-debug.pub"
fi
if [[ -n ${THOR_OPENSSH_PKG:-} && -f $THOR_OPENSSH_PKG ]]; then
  install -m644 "$THOR_OPENSSH_PKG" "$out/openssh-thor.pkg.tar.xz"
fi
if [[ -n ${THOR_WIFI_FILE:-} && -f $THOR_WIFI_FILE ]]; then
  install -m600 "$THOR_WIFI_FILE" "$out/omarchy-thor-wifi"
fi
if [[ ${THOR_PASSWORDLESS_SUDO:-0} == 1 ]]; then
  : >"$out/omarchy-thor-passwordless-sudo"
fi

# Quickshell links Qt private APIs.  Keep an ABI-matched emergency payload on
# the FAT update partition so an image whose Qt was refreshed after the AUR
# package was built can repair the shell without reflashing ext4.  Compress the
# single (large, debug-info-bearing) executable; the init stub has xzcat.
qs_pkg=${THOR_QUICKSHELL_PKG:-}
if [[ -z $qs_pkg ]]; then
  qs_pkg=$(find "$repo/build/pkgs-out" -maxdepth 1 \
    -name 'quickshell-git-*.pkg.tar.*' -print 2>/dev/null | head -1 || true)
fi
if [[ -n $qs_pkg && -f $qs_pkg ]]; then
  qs_tmp=$(mktemp -d)
  trap 'rm -rf "$qs_tmp"' EXIT
  tar -xpf "$qs_pkg" -C "$qs_tmp" usr/bin/quickshell
  xz -T0 -6 -c "$qs_tmp/usr/bin/quickshell" >"$out/quickshell.xz"
  sha256sum "$qs_tmp/usr/bin/quickshell" | awk '{print $1"  quickshell"}' \
    >"$out/quickshell.sha256"
  tar -xOf "$qs_pkg" .BUILDINFO | \
    awk -F' = ' '$1 == "installed" && $2 ~ /^qt6-(base|declarative)-/ {print $2}' \
    >"$out/quickshell-qt.version"
  rm -rf "$qs_tmp"
  trap - EXIT
fi
if [[ -n ${THOR_KB_BIN:-} && -x $THOR_KB_BIN ]]; then
  install -m755 "$THOR_KB_BIN" "$out/omarchy-thor-kb"
elif [[ -x $out/omarchy-thor-kb ]]; then
  # Preserve the previously cross-compiled aarch64 helper on macOS.  The host
  # clang advertises itself as gcc but has no Linux input headers.
  :
elif command -v gcc >/dev/null; then
  bash "$here/compile-thor-kb.sh" "$out/omarchy-thor-kb"
else
  echo "omarchy-thor-kb binary missing — compile with build/compile-thor-kb.sh" >&2
fi
if [[ -n ${THOR_GAMEPAD_WAKE_BIN:-} && -x $THOR_GAMEPAD_WAKE_BIN ]]; then
  install -m755 "$THOR_GAMEPAD_WAKE_BIN" "$out/omarchy-thor-gamepad-wake"
elif [[ -x $out/omarchy-thor-gamepad-wake ]]; then
  :
elif command -v gcc >/dev/null; then
  bash "$here/compile-thor-gamepad-wake.sh" "$out/omarchy-thor-gamepad-wake"
else
  echo "gamepad wake binary missing — run build/compile-thor-gamepad-wake.sh" >&2
fi
ls -lh "$out"
echo "boot files: $out"
