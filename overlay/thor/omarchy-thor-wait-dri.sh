#!/bin/bash
# SDDM ExecStartPre: do not launch the greeter while MSM has only registered
# the display controller.  On Thor, card0 appears roughly 20 seconds before
# the Adreno SQE firmware fallback completes; starting Hyprland in that gap
# leaves the greeter in emergency mode.

runtime=/run/omarchy-thor
mkdir -p "$runtime"
if ! chown sddm: "$runtime" 2>/dev/null; then
  chmod 0777 "$runtime"
else
  chmod 0755 "$runtime"
fi

card=""
render=""
ready=0
attempt=0
max_attempts=250 # 50 seconds; never recreate the previous 90-second stall.
min_uptime=35    # Let late firmware files and udev settle before first EGL use.

while (( attempt < max_attempts )); do
  attempt=$((attempt + 1))

  for conn in /sys/class/drm/card*-DSI-*; do
    [[ -e $conn ]] || continue
    n=${conn#/sys/class/drm/card}
    n=${n%%-*}
    if [[ -e /dev/dri/card$n ]]; then
      card=$n
      break
    fi
  done
  [[ -n $card ]] || { [[ -e /dev/dri/card0 ]] && card=0; }

  render=""
  for node in /dev/dri/renderD*; do
    [[ -e $node ]] || continue
    render=$node
    break
  done

  firmware_present=0
  if [[ -s /usr/lib/firmware/qcom/a740_sqe.fw &&
        -s /usr/lib/firmware/qcom/gmu_gen70200.bin &&
        -s /usr/lib/firmware/qcom/sm8550/a740_zap.mbn ]]; then
    firmware_present=1
  fi

  # A sysfs firmware-fallback request exists until the kernel has consumed
  # the late-installed blob.  Wait for the a740 request specifically; other
  # devices must not hold the display manager indefinitely.
  firmware_pending=0
  for request in /sys/class/firmware/*; do
    [[ -e $request ]] || continue
    name=$(cat "$request/name" 2>/dev/null || true)
    if [[ $name == *a740_sqe.fw* || $name == *a740_zap.mbn* ]]; then
      firmware_pending=1
      break
    fi
  done

  read -r uptime _ </proc/uptime
  uptime=${uptime%%.*}
  if [[ -n $card && -n $render && $firmware_present == 1 &&
        $firmware_pending == 0 && $uptime -ge $min_uptime ]]; then
    ready=1
    break
  fi
  sleep 0.2
done

[[ -n $card ]] || card=0
firmware_loaded=0
dmesg 2>/dev/null | grep -Fq \
  'loaded qcom/a740_sqe.fw from new location' && firmware_loaded=1
tmp="$runtime/gpu.env.tmp"
cat >"$tmp" <<EOF
AQ_DRM_DEVICES=/dev/dri/card${card}
WLR_DRM_DEVICES=/dev/dri/card${card}
WLR_BACKENDS=drm,libinput
WLR_RENDERER=gles2
AQ_NO_MODIFIERS=1
HYPRLAND_EGL_NO_MODIFIERS=1
THOR_DRM_READY=${ready}
THOR_RENDER_NODE=${render}
THOR_SQE_LOADED=${firmware_loaded:-0}
EOF
mv -f "$tmp" "$runtime/gpu.env"
chmod 0644 "$runtime/gpu.env"

echo "thor-wait-dri: ready=$ready card=/dev/dri/card${card} render=${render:-missing} uptime=${uptime:-unknown}s attempts=$attempt"
exit 0
