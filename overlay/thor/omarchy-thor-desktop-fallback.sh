#!/bin/bash
# If uwsm/Hyprland never maps a session, retry once with a direct Hyprland
# session so we are not stuck on the purple setup framebuffer.
set -euo pipefail
sleep 18
pgrep -x Hyprland >/dev/null && exit 0
flag=/var/lib/omarchy-thor/direct-session-tried
mkdir -p /var/lib/omarchy-thor
[[ -f $flag ]] && exit 0
conf=/etc/sddm.conf.d/autologin.conf
[[ -f $conf ]] || exit 0
touch "$flag"
if grep -q '^Session=' "$conf"; then
  sed -i 's/^Session=.*/Session=omarchy-thor.desktop/' "$conf"
else
  printf '\nSession=omarchy-thor.desktop\n' >>"$conf"
fi
systemctl restart sddm.service || true
