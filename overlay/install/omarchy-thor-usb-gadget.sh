#!/bin/bash
# USB-C CDC-ECM so a host can reach the Thor at 172.16.42.1 without Wi-Fi.
set -euo pipefail

log=/var/log/omarchy-thor-usb.log
mkdir -p /var/log
exec >>"$log" 2>&1
echo "=== $(date -Is 2>/dev/null || date) thor usb gadget start ==="

g=/sys/kernel/config/usb_gadget/omarchy
mkdir -p /sys/kernel/config
mountpoint -q /sys/kernel/config || mount -t configfs configfs /sys/kernel/config

# The Qualcomm UDC can appear after multi-user.target has already started on
# this image.  Exiting successfully here leaves a permanently inactive usb0,
# so wait for the controller and fail visibly if it never arrives.  systemd
# will retry failures rather than considering the gadget configured.
udc=
for n in {1..300}; do
  udc=$(find /sys/class/udc -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -n 1 || true)
  [[ -n $udc ]] && break
  sleep 0.2
done
if [[ -z $udc ]]; then
  echo "ERROR: no USB device controller appeared within 60 seconds"
  exit 1
fi
echo "using UDC=$udc"
if [[ -d $g ]]; then
  # The initramfs normally creates this gadget.  Reuse it, but bind it when
  # the early one-second usb0 probe raced gadget enumeration.
  current_udc=$(cat "$g/UDC" 2>/dev/null || true)
  [[ -n $current_udc ]] || echo "$udc" >"$g/UDC"
else
  mkdir -p "$g/strings/0x409" "$g/configs/c.1/strings/0x409" "$g/functions/ecm.usb0"
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
  ln -s "$g/functions/ecm.usb0" "$g/configs/c.1/"
  echo "$udc" >"$g/UDC"
fi

wait_usb0() {
  local n
  for ((n = 0; n < 100; n++)); do
    [[ -e /sys/class/net/usb0 ]] && return 0
    sleep 0.1
  done
  return 1
}

if ! wait_usb0; then
  # A gadget may be bound while its ECM netdev failed to materialize.  A
  # controlled UDC rebind is safe here, before the debug link is in use.
  echo "" >"$g/UDC"
  sleep 0.25
  echo "$udc" >"$g/UDC"
  wait_usb0
fi

ip link set usb0 up
ip addr replace 172.16.42.1/24 dev usb0
echo "usb0 configured"
ip -brief address show dev usb0 || true

# Omarchy's default firewall drops unsolicited input.  Restrict the exception
# to SSH arriving on the private USB interface from its /24; do not expose SSH
# on Wi-Fi or any other interface.  UFW persists the rule, while the iptables
# insertion makes it effective immediately on nft-backed UFW installations.
if command -v ufw >/dev/null 2>&1; then
  ufw allow in on usb0 proto tcp from 172.16.42.0/24 to any port 22 >/dev/null || true
  ufw allow in on usb0 proto tcp from 172.16.42.0/24 to any port 53317 >/dev/null || true
  ufw reload >/dev/null 2>&1 || true
fi
if command -v iptables >/dev/null 2>&1; then
  for port in 22 53317; do
    iptables -C INPUT -i usb0 -s 172.16.42.0/24 -p tcp --dport "$port" -j ACCEPT \
      2>/dev/null || \
      iptables -I INPUT 1 -i usb0 -s 172.16.42.0/24 -p tcp --dport "$port" -j ACCEPT || true
  done
fi

# Generate host keys before the normal sshd.service starts.  systemd owns the
# primary port-22 daemon; starting another copy here races sshd.service and
# leaves that unit failed even though an unmanaged daemon is listening.
if [[ -x /usr/bin/ssh-keygen && -x /usr/bin/sshd ]]; then
  mkdir -p /run/sshd
  /usr/bin/ssh-keygen -A

  # Omarchy already permits LocalSend's 53317/tcp through UFW.  A second
  # sshd bound exclusively to the point-to-point USB address gives us a
  # recovery path even if the interface-specific UFW rule for port 22 is
  # unavailable on a particular image.  It cannot listen on Wi-Fi.
  if ! ss -H -lnt 2>/dev/null | grep -Eq '172\.16\.42\.1:53317[[:space:]]'; then
    /usr/bin/sshd \
      -o ListenAddress=172.16.42.1 \
      -o Port=53317 \
      -o PidFile=/run/sshd-usb.pid \
      -E /var/log/omarchy-thor-sshd-usb.log || true
  fi
  echo "sshd listeners:"
  ss -lntp 2>/dev/null | grep -E '(:22|:53317)' || true
else
  echo "ERROR: /usr/bin/sshd or ssh-keygen is missing"
fi
echo "=== thor usb gadget complete ==="
