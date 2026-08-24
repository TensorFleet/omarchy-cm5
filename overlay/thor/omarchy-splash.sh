#!/bin/sh
# Replaces /usr/bin/rocknix-splash (bind-mounted from post-sysroot.sh).
# The ROCKNIX wordmark is SVG compiled into that binary; wipe fb0 and
# paint an Omarchy console banner instead.
bb=/usr/bin/busybox
[ -x "$bb" ] || bb=/bin/busybox

if [ -e /dev/fb0 ]; then
  # Drop the ROCKNIX glyph splash.
  $bb dd if=/dev/zero of=/dev/fb0 bs=1024 count=16384 >/dev/null 2>&1 || true
fi

# load_splash will also cat /sysroot/etc/issue; draw ours first so the
# framebuffer/console is already Omarchy-branded.
{
  echo
  echo "        Omarchy"
  echo "        AYN Thor"
  echo
} >/dev/console 2>/dev/null
exit 0
