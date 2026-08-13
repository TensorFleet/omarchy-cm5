#!/bin/bash
# Resolve aarch64 package availability BEFORE the image build starts.
#
# Produces, in $OUT (default build/resolved/):
#   alarm-names.txt   every package name (and provides) ALARM serves for aarch64
#   omarchy-repo.txt  the pkgs.omarchy.org aarch64 repo URL, if one exists
#
# build-any-packages.sh uses alarm-names.txt to decide which arch=('any')
# omarchy packages to build and which runtime dependencies need a shim
# provider on aarch64 (e.g. limine: x86-bootloader-shaped, unused on a Pi
# where the firmware boots the kernel directly).
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${OUT:-$here/resolved}
mkdir -p "$OUT"

MIRROR=${ALARM_MIRROR:-http://mirror.archlinuxarm.org}
REPOS=(core extra alarm aur)

: >"$OUT/alarm-names.txt"
for repo in "${REPOS[@]}"; do
  echo "fetching $repo.db …" >&2
  curl -fsSL --retry 3 "$MIRROR/aarch64/$repo/$repo.db" -o "$OUT/$repo.db"
  # db = gzipped tar of <pkg-ver>/desc files; collect %NAME% and %PROVIDES%
  bsdtar -xOf "$OUT/$repo.db" '*/desc' | awk '
    /^%NAME%$/     { grab=1; next }
    /^%PROVIDES%$/ { grab=2; next }
    /^%/           { grab=0; next }
    /^$/           { grab=0; next }
    grab==1 { print $0 }
    grab==2 { sub(/[<>=].*/, ""); print $0 }
  ' >>"$OUT/alarm-names.txt"
done
sort -u -o "$OUT/alarm-names.txt" "$OUT/alarm-names.txt"
echo "ALARM aarch64 provides $(wc -l <"$OUT/alarm-names.txt") package names" >&2

# Does the official omarchy package repo serve aarch64 yet? (Upstream's own
# aarch64 plan says no as of writing; probe every build so we adopt it the
# day it appears.)
: >"$OUT/omarchy-repo.txt"
for channel in stable; do
  url="https://pkgs.omarchy.org/$channel"
  if curl -fsSL --retry 2 -o /dev/null "$url/aarch64/omarchy.db" 2>/dev/null; then
    echo "$url" >"$OUT/omarchy-repo.txt"
    echo "official [omarchy] aarch64 repo EXISTS: $url" >&2
    break
  fi
done
[[ -s $OUT/omarchy-repo.txt ]] || echo "no official [omarchy] aarch64 repo (expected) — will build 'any' packages locally" >&2
