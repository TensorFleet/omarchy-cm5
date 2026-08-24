# Official LibreELEC/ROCKNIX hook. Sourced from init's mount_storage()
# INSTEAD of the default mount. $disk and mount_part come from that init.
# https://github.com/ROCKNIX/distribution/blob/master/packages/sysutils/busybox/scripts/init
. /flash/omarchy-log.sh 2>/dev/null || true
omarchy_log "mount-storage: mounting $disk on /storage"
mount_part "$disk" "/storage" "rw,noatime"
omarchy_dump mount-storage
if [ -f /flash/thor-apply-storage.sh ]; then
  . /flash/thor-apply-storage.sh
fi
