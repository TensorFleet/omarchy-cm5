#!/bin/bash
# Cross-friendly static build of omarchy-thor-kb for the FAT update path.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
out=${1:-$here/thor-boot-update/omarchy-thor-kb}
mkdir -p "$(dirname "$out")"
cc=${CC:-gcc}
$cc -static -O2 -o "$out" "$repo/overlay/thor/omarchy-thor-kb.c"
chmod 755 "$out"
file "$out" || true
echo "thor-kb: $out"
