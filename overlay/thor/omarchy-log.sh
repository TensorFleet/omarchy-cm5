# Shared boot-log helper. Sourced from FAT hooks and the SYSTEM pivot.
# Writes /flash/omarchy-boot.log (FAT, readable on a Mac) and a copy on
# /storage when that mount exists. Remounts FAT rw; syncs after each dump.
omarchy_bb() {
  if [ -x /usr/bin/busybox ]; then
    /usr/bin/busybox "$@"
  elif [ -x /bin/busybox ]; then
    /bin/busybox "$@"
  else
    "$@"
  fi
}

omarchy_flash_rw() {
  omarchy_bb mount -o remount,rw /flash 2>/dev/null || true
}

omarchy_log() {
  _line="$(omarchy_bb date 2>/dev/null) $*"
  echo "$_line" >/dev/console 2>/dev/null || true
  echo "$_line" >/dev/kmsg 2>/dev/null || true
  omarchy_flash_rw
  for _f in /flash/omarchy-boot.log /storage/omarchy-boot.log \
            /sysroot/flash/omarchy-boot.log /sysroot/storage/omarchy-boot.log; do
    echo "$_line" >>"$_f" 2>/dev/null || true
  done
  omarchy_bb sync 2>/dev/null || true
}

omarchy_dump() {
  _tag=$1
  omarchy_flash_rw
  _out=/flash/omarchy-boot.log
  {
    echo ""
    echo "========== ${_tag} =========="
    omarchy_bb date 2>/dev/null || true
    echo "cmdline: $(omarchy_bb cat /proc/cmdline 2>/dev/null)"
    echo "--- mounts ---"
    omarchy_bb cat /proc/mounts 2>/dev/null
    echo "--- /flash ---"
    omarchy_bb ls -la /flash 2>/dev/null
    echo "--- /sysroot ---"
    omarchy_bb ls -la /sysroot 2>/dev/null
    echo "--- /storage ---"
    omarchy_bb ls -la /storage 2>/dev/null
    echo "--- systemd paths ---"
    omarchy_bb ls -la /usr/lib/systemd/systemd /sysroot/usr/lib/systemd/systemd \
      /storage/usr/lib/systemd/systemd 2>/dev/null
    echo "--- dmesg tail ---"
    omarchy_bb dmesg 2>/dev/null | omarchy_bb tail -120
  } >>"$_out" 2>/dev/null
  omarchy_bb cp "$_out" /storage/omarchy-boot.log 2>/dev/null || true
  omarchy_bb sync 2>/dev/null || true
  echo "omarchy-thor: dumped ${_tag} -> /flash/omarchy-boot.log" >/dev/console
}
