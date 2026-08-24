#!/bin/bash
# Cross-friendly static build of the non-exclusive gamepad wake helper.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
out=${1:-$here/thor-boot-update/omarchy-thor-gamepad-wake}
mkdir -p "$(dirname "$out")"
cc=${CC:-gcc}
$cc -static -O2 -Wall -Wextra -o "$out" \
  "$repo/overlay/thor/omarchy-thor-gamepad-wake.c"
chmod 755 "$out"
file "$out" || true
echo "thor-gamepad-wake: $out"
