# Sourced by the ROCKNIX initramfs after LABEL=ROCKNIX is mounted at /flash.
. /flash/omarchy-log.sh 2>/dev/null || true
omarchy_flash_rw
if [ -f /flash/omarchy-boot.log ]; then
  omarchy_bb mv /flash/omarchy-boot.log /flash/omarchy-boot.log.old 2>/dev/null || true
fi
omarchy_log "post-flash: FAT mounted, starting boot log"
omarchy_dump post-flash

# USB ACM serial is not in this kernel. CDC-ECM is.
omarchy_usb_ecm() {
  local g udc
  omarchy_bb mkdir -p /sys/kernel/config 2>/dev/null || true
  omarchy_bb mount -t configfs configfs /sys/kernel/config 2>/dev/null || true
  g=/sys/kernel/config/usb_gadget/omarchy
  [ -d /sys/class/udc ] || { omarchy_log "post-flash: no UDC"; return 0; }
  udc=$(ls /sys/class/udc 2>/dev/null | omarchy_bb head -n 1)
  [ -n "$udc" ] || { omarchy_log "post-flash: empty UDC"; return 0; }
  omarchy_log "post-flash: UDC=$udc"
  [ -d "$g" ] && return 0
  omarchy_bb mkdir -p "$g/strings/0x409" "$g/configs/c.1/strings/0x409" \
    "$g/functions/ecm.usb0" || { omarchy_log "post-flash: configfs mkdir failed"; return 0; }
  echo 0x0200 >"$g/bcdUSB"
  echo 0x1d6b >"$g/idVendor"
  echo 0x0104 >"$g/idProduct"
  echo Omarchy >"$g/strings/0x409/manufacturer"
  echo Thor >"$g/strings/0x409/product"
  echo 0001 >"$g/strings/0x409/serialnumber"
  echo 02:00:00:00:00:01 >"$g/functions/ecm.usb0/dev_addr"
  echo 02:00:00:00:00:02 >"$g/functions/ecm.usb0/host_addr"
  echo ECM >"$g/configs/c.1/strings/0x409/configuration"
  echo 120 >"$g/configs/c.1/MaxPower"
  omarchy_bb ln -s "$g/functions/ecm.usb0" "$g/configs/c.1/" 2>/dev/null || true
  echo "$udc" >"$g/UDC"
  omarchy_bb sleep 1
  if omarchy_bb ifconfig usb0 172.16.42.1 netmask 255.255.255.0 up 2>/dev/null ||
     /sbin/ip addr add 172.16.42.1/24 dev usb0 2>/dev/null; then
    omarchy_bb telnetd -l /bin/sh -p 23 2>/dev/null ||
      omarchy_bb telnetd -l /bin/sh 2>/dev/null || true
    omarchy_log "post-flash: USB ECM 172.16.42.1 telnet 23"
  else
    omarchy_log "post-flash: usb0 configure failed"
  fi
}
omarchy_usb_ecm
