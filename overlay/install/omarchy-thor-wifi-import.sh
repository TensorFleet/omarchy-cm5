#!/bin/bash
# Import a two-line credential file (SSID, then WPA passphrase) into
# NetworkManager without printing either value.
set -euo pipefail

credential=${1:-/boot/omarchy-thor-wifi}
delete_after=${2:-}
[[ -f $credential ]] || exit 0
command -v nmcli >/dev/null 2>&1 || {
  echo "omarchy-thor-wifi-import: nmcli is unavailable" >&2
  exit 1
}

mapfile -t wifi_lines < <(sed -e 's/\r$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$credential")
(( ${#wifi_lines[@]} >= 2 )) || {
  echo "omarchy-thor-wifi-import: expected SSID and passphrase on separate lines" >&2
  exit 1
}
ssid=${wifi_lines[0]}
psk=${wifi_lines[1]}
[[ -n $ssid && -n $psk ]] || exit 1

wifi_if=$(nmcli -t -f DEVICE,TYPE device status | awk -F: '$2 == "wifi" {print $1; exit}')
[[ -n $wifi_if ]] || {
  echo "omarchy-thor-wifi-import: no Wi-Fi device found" >&2
  exit 1
}

connection=thor-debug-wifi
nmcli radio wifi on >/dev/null
if nmcli -t -f NAME connection show | grep -Fqx "$connection"; then
  nmcli connection modify "$connection" 802-11-wireless.ssid "$ssid" >/dev/null
else
  nmcli connection add type wifi ifname "$wifi_if" con-name "$connection" \
    ssid "$ssid" >/dev/null
fi
nmcli connection modify "$connection" \
  connection.autoconnect yes \
  connection.autoconnect-priority 100 \
  802-11-wireless-security.key-mgmt wpa-psk \
  802-11-wireless-security.psk "$psk" \
  ipv4.method auto ipv6.method auto >/dev/null

# This importer is an explicit debug provisioning action. Permit SSH only on
# the Wi-Fi interface it configured; the default image remains closed because
# the importer never runs without a credential file on the FAT.
if command -v ufw >/dev/null 2>&1; then
  ufw allow in on "$wifi_if" proto tcp to any port 22 >/dev/null
  ufw reload >/dev/null 2>&1 || true
fi

# Importing the profile is the durable operation.  Association may fail when
# the access point is temporarily absent; NetworkManager will keep retrying.
nmcli connection up "$connection" >/dev/null 2>&1 || true

if [[ $delete_after == --delete ]]; then
  rm -f -- "$credential"
fi
echo "omarchy-thor-wifi-import: NetworkManager profile installed"
