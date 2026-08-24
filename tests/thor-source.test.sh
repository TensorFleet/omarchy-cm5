#!/bin/bash
# Fast, host-independent checks for the AYN Thor image/repair payload.
set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

scripts=()
while IFS= read -r script; do
  scripts+=("$script")
done < <(
  find build overlay tests \
    \( -path build/upstream -o -path build/cache -o \
       -path build/thor-boot-update \) -prune -o \
    -type f -name '*.sh' -print | sort
)
for script in "${scripts[@]}"; do
  bash -n "$script" || fail "shell syntax: $script"
done
pass "shell syntax (${#scripts[@]} scripts)"

if printf '#include <linux/input.h>\n' | cc -E - >/dev/null 2>&1; then
  for source in \
    overlay/thor/omarchy-thor-kb.c \
    overlay/thor/omarchy-thor-gamepad-wake.c; do
    cc -fsyntax-only "$source" || fail "C syntax: $source"
  done
  pass "Thor input helpers compile"
else
  pass "Thor input helper compilation skipped (host has no Linux headers)"
fi

payload=(
  overlay/thor/thor-monitors.lua
  overlay/thor/sddm-hyprland.lua
  overlay/thor/sddm-wayland.conf
  overlay/thor/omarchy-thor-greeter.sh
  overlay/thor/omarchy-thor-osk.sh
  overlay/thor/omarchy-thor-session.sh
  overlay/thor/omarchy-thor-desktop.sh
  overlay/thor/omarchy-thor-desktop-fallback.sh
  overlay/install/omarchy-thor-display-recover.sh
  overlay/install/omarchy-thor-usb-gadget.sh
  overlay/install/omarchy-thor-wifi-import.sh
  overlay/systemd/omarchy-thor-display-recover.service
  overlay/systemd/omarchy-thor-gamepad-wake.service
  overlay/systemd/omarchy-thor-usb-gadget.service
  overlay/systemd/omarchy-thor-wifi-import.service
)
for file in "${payload[@]}"; do
  [[ -f $file ]] || fail "missing payload source: $file"
  base=$(basename "$file")
  grep -Fq "$base" build/mkimage.sh || fail "mkimage omits $base"
  grep -Fq "$base" build/mk-thor-bootfiles.sh || fail "FAT builder omits $base"
done
pass "fresh image and FAT repair carry the Thor runtime payload"

grep -Fq 'mode = "1080x1920@60"' overlay/thor/thor-monitors.lua ||
  fail "top DSI panel is not capped at 60 Hz"
[[ $(grep -c 'transform = 3' overlay/thor/thor-monitors.lua) -eq 2 ]] ||
  fail "both DSI panels must use the Thor landscape transform"
grep -Fq 'output = "DSI-1"' overlay/thor/thor-monitors.lua ||
  fail "bottom DSI is missing"
pass "dual-panel layout"

grep -Fq 'quickshell-git omarchy-keyring' build/mkimage.sh ||
  fail "Quickshell is not a required Omarchy core package"
grep -Fq 'Thor OSK binary' build/verify-image.sh ||
  fail "image verifier does not require the OSK"
grep -Fq 'Thor DSI recovery enabled' build/verify-image.sh ||
  fail "image verifier does not require DSI recovery"
grep -Fq "'*.pkg.tar.*'" .github/workflows/build-image-thor.yml ||
  fail "Thor CI does not download xz-packaged Quickshell builds"
[[ -f pkgs/aarch64-extra/wvkbd/PKGBUILD ]] ||
  fail "wvkbd is not reproducibly packaged"
grep -Fq 'build-in-chroot.sh wvkbd quickshell-git' .github/workflows/build-image-thor.yml ||
  fail "Thor CI does not rebuild its required OSK and Qt-matched desktop shell"
grep -Fq 'quickshell Qt ABI:' pkgs/build-in-chroot.sh ||
  fail "Quickshell package versions do not encode their Qt private ABI"
grep -Fq "test -x \"\$mnt/usr/bin/wvkbd-mobintl\"" build/verify-image.sh ||
  fail "image verifier does not require the packaged keyboard binary"
pass "desktop and recovery invariants"

# Debug credentials are opt-in inputs. Nothing secret may be staged by the
# release workflow or committed under its FAT payload name.
[[ ! -e omarchy-thor-wifi && ! -e overlay/thor/omarchy-thor-wifi ]] ||
  fail "Wi-Fi credential file is inside the source tree"
! grep -Fq 'THOR_WIFI_FILE=' .github/workflows/build-image-thor.yml ||
  fail "release workflow must not embed Wi-Fi credentials"
! grep -Fq 'THOR_PASSWORDLESS_SUDO=1' .github/workflows/build-image-thor.yml ||
  fail "release workflow must not enable passwordless sudo"
pass "release image remains secret-free"

# shellcheck source=../build/thor-vendor.lock
source build/thor-vendor.lock
[[ $ROCKNIX_IMAGE == *SM8550*"$ROCKNIX_RELEASE"*.img.gz ]] ||
  fail "ROCKNIX lock release/image mismatch"
[[ $ROCKNIX_SHA256 =~ ^[0-9a-f]{64}$ ]] || fail "invalid ROCKNIX SHA-256"
(( ROCKNIX_FAT_OFFSET > 0 && ROCKNIX_FAT_LENGTH > 0 )) ||
  fail "invalid ROCKNIX FAT geometry"
pass "pinned ROCKNIX vendor source"

echo "Thor source verification complete"
