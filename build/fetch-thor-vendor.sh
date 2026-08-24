#!/bin/bash
# Extract ROCKNIX KERNEL + modules + firmware into the package vendor trees.
#
# Prefers an explicitly supplied/local cached FAT image. Otherwise downloads
# the exact official ROCKNIX image pinned by thor-vendor.lock, verifies it, and
# streams only its FAT system partition to disk before extracting the payload.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
extract=$here/../pkgs/aarch64-extra/linux-rocknix-sm8550/extract.sh
[[ -x $extract ]] || chmod +x "$extract"

# shellcheck source=thor-vendor.lock
source "$here/thor-vendor.lock"

ayn=${AYN_THOR_DIR:-}
if [[ -z $ayn ]]; then
  for cand in \
    "$here/../../ayn-thor" \
    "$HOME/projects/me/ayn-thor"; do
    [[ -d $cand ]] && { ayn=$cand; break; }
  done
fi

if [[ -n ${THOR_FAT_IMG:-} && -f ${THOR_FAT_IMG} ]]; then
  THOR_KERNEL=${THOR_KERNEL:-} bash "$extract" --from-fat "$THOR_FAT_IMG"
elif [[ -n $ayn && -f $ayn/.cache/rocknix-p1-system.img ]]; then
  export THOR_KERNEL=${THOR_KERNEL:-$ayn/.cache/thor-boot/KERNEL}
  [[ -f $THOR_KERNEL ]] || THOR_KERNEL=$ayn/.cache/rocknix-p1-system.img
  bash "$extract" --from-fat "$ayn/.cache/rocknix-p1-system.img"
elif [[ -n $ayn && -d $ayn/.cache/thor-boot/from-system ]]; then
  export THOR_KERNEL=${THOR_KERNEL:-$ayn/.cache/thor-boot/KERNEL}
  bash "$extract" --from-tree "$ayn/.cache/thor-boot/from-system"
else
  for tool in curl python3 sha256sum mcopy unsquashfs; do
    command -v "$tool" >/dev/null || {
      echo "missing tool for ROCKNIX vendor extraction: $tool" >&2
      exit 1
    }
  done

  cache=${THOR_VENDOR_CACHE_DIR:-$repo/build/cache/thor-vendor}
  mkdir -p "$cache"
  image=$cache/$ROCKNIX_IMAGE
  fat=$cache/rocknix-$ROCKNIX_RELEASE-p1-system.img
  url=https://github.com/ROCKNIX/distribution/releases/download/$ROCKNIX_RELEASE/$ROCKNIX_IMAGE

  if [[ -f $image ]] && ! printf '%s  %s\n' "$ROCKNIX_SHA256" "$image" | sha256sum -c -; then
    echo "discarding cached ROCKNIX image with a bad checksum" >&2
    rm -f "$image"
  fi
  if [[ ! -f $image ]]; then
    echo "downloading pinned ROCKNIX $ROCKNIX_RELEASE SM8550 image" >&2
    curl -fL --retry 3 --retry-all-errors -o "$image.part" "$url"
    mv -f "$image.part" "$image"
    printf '%s  %s\n' "$ROCKNIX_SHA256" "$image" | sha256sum -c -
  fi

  if [[ ! -f $fat || $(wc -c <"$fat") -ne $ROCKNIX_FAT_LENGTH ]]; then
    rm -f "$fat"
    python3 - "$image" "$fat" "$ROCKNIX_FAT_OFFSET" "$ROCKNIX_FAT_LENGTH" <<'PY'
import gzip
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
dest = pathlib.Path(sys.argv[2])
offset = int(sys.argv[3])
length = int(sys.argv[4])
chunk_size = 8 * 1024 * 1024

with gzip.open(source, "rb") as compressed, dest.open("wb") as output:
    remaining = offset
    while remaining:
        chunk = compressed.read(min(remaining, chunk_size))
        if not chunk:
            raise SystemExit("ROCKNIX image ended before the FAT partition")
        remaining -= len(chunk)

    remaining = length
    while remaining:
        chunk = compressed.read(min(remaining, chunk_size))
        if not chunk:
            raise SystemExit("ROCKNIX FAT partition was shorter than expected")
        output.write(chunk)
        remaining -= len(chunk)

print(f"extracted {dest} ({dest.stat().st_size} bytes)")
PY
  fi
  bash "$extract" --from-fat "$fat"
fi

# If extract --from-fat already stored KERNEL, we are done. Otherwise copy it.
kdest=$here/../pkgs/aarch64-extra/linux-rocknix-sm8550/vendor/KERNEL
if [[ ! -f $kdest && -n ${THOR_KERNEL:-} && -f ${THOR_KERNEL} && ${THOR_KERNEL} != *.img ]]; then
  mkdir -p "$(dirname "$kdest")"
  cp -a "$THOR_KERNEL" "$kdest"
fi
echo "vendor ready"
