#!/bin/bash
# Pack (or rebuild) an ABL-compatible KERNEL Android bootimg.
#
# ROCKNIX SM8550 KERNEL is ANDROID! with a gzip Image + trailing DTBs and a
# dummy 5-byte ramdisk. The real initramfs is built into the Image, so this
# script does not try to inject mkinitcpio there. It keeps the original
# kernel blob and optionally rewrites the cmdline.
#
# Usage:
#   pack-qcom-bootimg.sh --in KERNEL [--cmdline "..."] [--out KERNEL]
set -euo pipefail

in="" out="" cmdline=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --in) in=$2; shift 2 ;;
    --out) out=$2; shift 2 ;;
    --cmdline) cmdline=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[[ -n $in && -f $in ]] || { echo "usage: $0 --in KERNEL [--cmdline TEXT] [--out KERNEL]" >&2; exit 2; }
out=${out:-$in.new}

python3 - "$in" "$out" "$cmdline" <<'PY'
import struct, sys, pathlib
src, dst, new_cmd = sys.argv[1], sys.argv[2], sys.argv[3]
data = pathlib.Path(src).read_bytes()
if data[:8] != b"ANDROID!":
    sys.exit(f"{src}: not an ANDROID! bootimg (got {data[:8]!r})")
kernel_size, kernel_addr, ramdisk_size, ramdisk_addr, second_size, second_addr, tags_addr, page_size, unused, os_version = struct.unpack_from("<10I", data, 8)
name = data[48:64]
old_cmd = data[64:64+512].split(b"\0", 1)[0]
if new_cmd:
    cmd = new_cmd.encode("ascii")
    if len(cmd) >= 512:
        sys.exit("cmdline too long for bootimg header")
else:
    cmd = old_cmd
# keep kernel + ramdisk + second exactly as-is; only rewrite header cmdline
hdr = bytearray(data[:page_size])
hdr[64:64+512] = cmd.ljust(512, b"\0")
pathlib.Path(dst).write_bytes(bytes(hdr) + data[page_size:])
print(f"wrote {dst} page={page_size} kernel={kernel_size} ramdisk={ramdisk_size}")
print(f"cmdline: {cmd.decode('ascii')}")
PY
