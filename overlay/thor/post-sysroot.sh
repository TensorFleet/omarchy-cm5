# Sourced after the initramfs loop-mounts /flash/SYSTEM at /sysroot.
# LibreELEC mounts LABEL=STORAGE *after* this hook. Do not copy onto
# /storage here — those writes vanish when ext4 is mounted. The SYSTEM
# systemd shim sources /flash/thor-apply-storage.sh after that mount.
. /flash/omarchy-log.sh 2>/dev/null || true
omarchy_log "post-sysroot: SYSTEM mounted"
omarchy_dump post-sysroot

if grep -q ' /storage ext4' /proc/mounts 2>/dev/null && [ -f /flash/thor-apply-storage.sh ]; then
  . /flash/thor-apply-storage.sh
fi

# load_splash runs /usr/bin/rocknix-splash from the *initramfs*, not SYSTEM.
# Bind our FAT script over it so the ROCKNIX SVG wordmark never hits fb0.
if [ -f /flash/omarchy-splash.sh ]; then
  /usr/bin/busybox cp /flash/omarchy-splash.sh /tmp/omarchy-splash
  /usr/bin/busybox chmod +x /tmp/omarchy-splash
  /usr/bin/busybox mount --bind /tmp/omarchy-splash /usr/bin/rocknix-splash
  omarchy_log "post-sysroot: bound omarchy-splash over rocknix-splash"
fi
