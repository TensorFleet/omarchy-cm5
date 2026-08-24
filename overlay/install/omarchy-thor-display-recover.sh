#!/bin/bash
# Recover the AYN Thor top command-mode DSI panel after the SM8550 DPU loses
# its frame-done interrupt.  The compositor buffer remains valid, but physical
# DSI-2 scanout stays corrupt until that connector is power-cycled.
set -euo pipefail

readonly tag=omarchy-thor-display-recover
last_recovery=0

recover_dsi2() {
  local now runtime uid user sock

  now=$(date +%s)
  (( now - last_recovery >= 5 )) || return 0
  last_recovery=$now

  for sock in /run/user/[0-9]*/hypr/*/.socket.sock; do
    [[ -S $sock ]] || continue
    runtime=${sock%%/hypr/*}
    uid=${runtime##*/}
    user=$(getent passwd "$uid" | cut -d: -f1)
    [[ -n $user ]] || continue

    if ! runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime" \
      hyprctl -i 0 monitors -j 2>/dev/null | grep -q '"name": "DSI-2"'; then
      continue
    fi

    logger -t "$tag" "encoder 38 timeout; cycling DSI-2"
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime" \
      hyprctl -i 0 dispatch \
      'hl.dsp.dpms({ action = "disable", monitor = "DSI-2" })' >/dev/null
    sleep 1
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime" \
      hyprctl -i 0 dispatch \
      'hl.dsp.dpms({ action = "enable", monitor = "DSI-2" })' >/dev/null
    logger -t "$tag" "DSI-2 recovery complete"
    return 0
  done

  logger -t "$tag" "encoder 38 timeout seen, but no DSI-2 Hyprland session is ready"
}

if [[ ${1:-} == --once ]]; then
  recover_dsi2
  exit
fi

# The object id is stable for the ROCKNIX 7.1.2 Thor DT: encoder 35/DSI-1 is
# the bottom panel and encoder 38/DSI-2 is the affected ICNA3520 top panel.
journalctl -k -f -n 0 -o cat | while IFS= read -r line; do
  if [[ $line == *dpu_encoder_frame_done_timeout*enc38* ]]; then
    recover_dsi2
  fi
done
