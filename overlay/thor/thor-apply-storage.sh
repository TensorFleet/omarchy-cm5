# Copy FAT overlays onto the Arch root. Must run only after
# /dev/mmcblk0p2 is mounted on /storage (LibreELEC mounts STORAGE *after*
# post-sysroot). Sourced from the SYSTEM systemd shim.
[ -x /storage/usr/lib/systemd/systemd ] || return 0

bb() {
  if [ -x /bin/busybox ]; then /bin/busybox "$@"
  elif [ -x /usr/bin/busybox ]; then /usr/bin/busybox "$@"
  else "$@"; fi
}

if [ -f /flash/thor-monitors.lua ]; then
  bb mkdir -p /storage/etc/skel/.config/hypr /storage/usr/share/omarchy/config/hypr
  bb cp /flash/thor-monitors.lua /storage/etc/skel/.config/hypr/monitors.lua
  bb cp /flash/thor-monitors.lua /storage/usr/share/omarchy/config/hypr/monitors.lua
  if [ -d /storage/home ]; then
    for d in /storage/home/*; do
      [ -d "$d/.config/hypr" ] && bb cp /flash/thor-monitors.lua "$d/.config/hypr/monitors.lua"
    done
  fi
fi
# Hyprland 0.55+ Lua parser: leftover .conf (ayn-thor, monitors.conf with
# render:explicit_sync) is a hard error (red bar, upside-down desktop).
# Keep monitors.lua only. Do not leave a monitors.conf for require().
for f in /storage/etc/skel/.config/hypr/hyprland.conf /storage/home/*/.config/hypr/hyprland.conf; do
  [ -f "$f" ] || continue
  bb sed -i '/ayn-thor.conf/d; /monitors.conf/d; /explicit_sync/d' "$f"
done
for d in /storage/etc/skel/.config/hypr /storage/usr/share/omarchy/config/hypr /storage/home/*/.config/hypr; do
  [ -d "$d" ] || continue
  bb rm -f "$d/ayn-thor.conf" "$d/monitors.conf" "$d/rpi-cm5.conf"
  if [ -f "$d/autostart.lua" ] && ! grep -q 'thor: desktop hook' "$d/autostart.lua"; then
    printf '\n-- thor: desktop hook\nhl.on("hyprland.start", function()\n  hl.exec_cmd("/usr/local/bin/omarchy-thor-desktop")\nend)\n' >>"$d/autostart.lua"
  fi
done
bb rm -f /storage/var/lib/omarchy-thor/direct-session-tried

# Repair a quickshell/Qt private-ABI mismatch before systemd starts SDDM.
# The FAT carries an xz-compressed binary rebuilt against the image's current
# Qt.  Compare hashes so this is a one-time, atomic replacement rather than a
# 200+ MB decompression on every boot.
if [ -f /flash/quickshell.xz ] && [ -f /flash/quickshell.sha256 ]; then
  qs_expected=$(awk 'NR == 1 {print $1}' /flash/quickshell.sha256)
  qs_current=
  [ -x /storage/usr/bin/quickshell ] && \
    qs_current=$(bb sha256sum /storage/usr/bin/quickshell 2>/dev/null | awk '{print $1}')
  if [ -n "$qs_expected" ] && [ "$qs_current" != "$qs_expected" ]; then
    qs_new=/storage/usr/bin/.quickshell.thor-new
    bb rm -f "$qs_new"
    if bb xzcat /flash/quickshell.xz >"$qs_new"; then
      qs_actual=$(bb sha256sum "$qs_new" 2>/dev/null | awk '{print $1}')
      if [ "$qs_actual" = "$qs_expected" ]; then
        bb chmod 755 "$qs_new"
        bb mv -f "$qs_new" /storage/usr/bin/quickshell
      else
        bb rm -f "$qs_new"
      fi
    else
      bb rm -f "$qs_new"
    fi
  fi
fi

# Use the Thor-controlled session: it supplies the required Qualcomm renderer
# environment, starts through start-hyprland, and deterministically launches
# the Omarchy shell after the compositor socket is ready.
autologin=/storage/etc/sddm.conf.d/autologin.conf
if [ -f "$autologin" ]; then
  if grep -q '^Session=' "$autologin"; then
    bb sed -i 's/^Session=.*/Session=omarchy-thor.desktop/' "$autologin"
  else
    printf '\nSession=omarchy-thor.desktop\n' >>"$autologin"
  fi
fi
# This fixed-user file is a repair overlay for the already-provisioned debug
# card. Fresh images let provision-owner create autologin for the chosen owner.
if [ -f /flash/sddm-autologin.conf ] && [ -d /storage/home/hyper ]; then
  bb mkdir -p /storage/etc/sddm.conf.d
  bb cp /flash/sddm-autologin.conf \
    /storage/etc/sddm.conf.d/99-thor-autologin.conf
fi

if [ -f /flash/omarchy-thor-kb ]; then
  bb mkdir -p /storage/usr/local/bin /storage/usr/local/lib/omarchy-thor \
    /storage/etc/systemd/system/omarchy-provision-owner.service.d \
    /storage/etc/systemd/system/multi-user.target.wants
  bb cp /flash/omarchy-thor-kb /storage/usr/local/bin/omarchy-thor-kb
  bb chmod 755 /storage/usr/local/bin/omarchy-thor-kb
  [ -f /flash/omarchy-thor-type.sh ] && {
    bb cp /flash/omarchy-thor-type.sh /storage/usr/local/bin/omarchy-thor-type
    bb chmod 755 /storage/usr/local/bin/omarchy-thor-type
  }
  [ -f /flash/omarchy-thor-gum.sh ] && {
    bb mkdir -p /storage/usr/local/lib/omarchy-thor
    bb cp /flash/omarchy-thor-gum.sh /storage/usr/local/lib/omarchy-thor/gum
    bb chmod 755 /storage/usr/local/lib/omarchy-thor/gum
  }
  [ -f /flash/omarchy-thor-kb.service ] && {
    bb cp /flash/omarchy-thor-kb.service /storage/etc/systemd/system/omarchy-thor-kb.service
    bb ln -sf /etc/systemd/system/omarchy-thor-kb.service \
      /storage/etc/systemd/system/multi-user.target.wants/omarchy-thor-kb.service
  }
  [ -f /flash/omarchy-provision-owner-thor.conf ] && \
    bb cp /flash/omarchy-provision-owner-thor.conf \
      /storage/etc/systemd/system/omarchy-provision-owner.service.d/thor.conf
fi

# Keep gamepad buttons visible to games, while mirroring button activity to a
# tiny virtual wake keyboard so QuickShell's Wayland idle monitor notices it.
if [ -f /flash/omarchy-thor-gamepad-wake ] && \
   [ -f /flash/omarchy-thor-gamepad-wake.service ]; then
  bb mkdir -p /storage/usr/local/bin \
    /storage/etc/systemd/system/multi-user.target.wants
  bb cp /flash/omarchy-thor-gamepad-wake \
    /storage/usr/local/bin/omarchy-thor-gamepad-wake
  bb chmod 755 /storage/usr/local/bin/omarchy-thor-gamepad-wake
  bb cp /flash/omarchy-thor-gamepad-wake.service \
    /storage/etc/systemd/system/omarchy-thor-gamepad-wake.service
  bb ln -sf /etc/systemd/system/omarchy-thor-gamepad-wake.service \
    /storage/etc/systemd/system/multi-user.target.wants/omarchy-thor-gamepad-wake.service
fi

# ROCKNIX 7.1.2 can lose the frame-done interrupt for the top ICNA3520 panel
# (encoder 38 / DSI-2), leaving physical scanout noisy while compositor
# screenshots stay clean. Automatically cycle only that connector on timeout.
if [ -f /flash/omarchy-thor-display-recover ] && \
   [ -f /flash/omarchy-thor-display-recover.service ]; then
  bb mkdir -p /storage/usr/local/bin \
    /storage/etc/systemd/system/multi-user.target.wants
  bb cp /flash/omarchy-thor-display-recover \
    /storage/usr/local/bin/omarchy-thor-display-recover
  bb chmod 755 /storage/usr/local/bin/omarchy-thor-display-recover
  bb cp /flash/omarchy-thor-display-recover.service \
    /storage/etc/systemd/system/omarchy-thor-display-recover.service
  bb ln -sf /etc/systemd/system/omarchy-thor-display-recover.service \
    /storage/etc/systemd/system/multi-user.target.wants/omarchy-thor-display-recover.service
fi

# Optional, secret-free base-image hooks.  A user can place a two-line
# omarchy-thor-wifi file on the FAT after flashing, and can explicitly opt a
# debug card into passwordless sudo with an empty marker file.  Neither is
# present in release images by default.
owner_name=
owner_home=
if [ -f /storage/etc/passwd ]; then
  owner_record=$(awk -F: '$3 == 1000 { print $1 ":" $6; exit }' /storage/etc/passwd)
  owner_name=${owner_record%%:*}
  owner_home=${owner_record#*:}
  [ "$owner_home" = "$owner_record" ] && owner_home=
fi
if [ -f /flash/omarchy-thor-wifi-import ] && \
   [ -f /flash/omarchy-thor-wifi-import.service ]; then
  bb mkdir -p /storage/usr/local/bin \
    /storage/etc/systemd/system/multi-user.target.wants
  bb cp /flash/omarchy-thor-wifi-import \
    /storage/usr/local/bin/omarchy-thor-wifi-import
  bb chmod 755 /storage/usr/local/bin/omarchy-thor-wifi-import
  bb cp /flash/omarchy-thor-wifi-import.service \
    /storage/etc/systemd/system/omarchy-thor-wifi-import.service
  bb ln -sf /etc/systemd/system/omarchy-thor-wifi-import.service \
    /storage/etc/systemd/system/multi-user.target.wants/omarchy-thor-wifi-import.service
fi
if [ -f /flash/omarchy-thor-passwordless-sudo ]; then
  if [ -n "$owner_name" ]; then
    bb mkdir -p /storage/etc/sudoers.d
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$owner_name" \
      >/storage/etc/sudoers.d/99-thor-debug
    bb chmod 440 /storage/etc/sudoers.d/99-thor-debug
  fi
else
  # Removing the FAT marker must also revoke a previously enabled debug rule.
  bb rm -f /storage/etc/sudoers.d/99-thor-debug
fi

# Full ROCKNIX Thor firmware tree (not individual blobs).
if [ -d /flash/firmware ]; then
  bb mkdir -p /storage/usr/lib/firmware
  bb cp -a /flash/firmware/. /storage/usr/lib/firmware/
  bb rm -f /storage/etc/modprobe.d/blacklist-qcom-iris.conf
fi
# Plymouth-quit-wait holds graphical.target while SDDM's greeter dies on a
# GPU that has no SQE yet. Mask it so the session can start on the console.
bb mkdir -p /storage/etc/systemd/system
bb ln -sf /dev/null /storage/etc/systemd/system/plymouth-quit-wait.service
bb ln -sf /dev/null /storage/etc/systemd/system/plymouth-start.service
bb ln -sf /dev/null /storage/etc/systemd/system/power-profiles-daemon.service

if [ -f /flash/20-ayn-thor.uwsm ]; then
  bb mkdir -p /storage/usr/share/uwsm/env.d
  bb cp /flash/20-ayn-thor.uwsm /storage/usr/share/uwsm/env.d/20-ayn-thor
  for d in /storage/etc/skel /storage/home/*; do
    [ -d "$d" ] || continue
    bb mkdir -p "$d/.config/uwsm/env.d"
    bb cp /flash/20-ayn-thor.uwsm "$d/.config/uwsm/env.d/20-ayn-thor"
  done
fi

# Persistent USB-C debug link.  The initramfs creates the ECM gadget early;
# this rootfs service finishes configuration after usb0 exists, then sshd
# serves 172.16.42.1.  Install one host key without clobbering user keys.
# Carry a matching Arch ARM OpenSSH package as a recovery payload.  Normal
# images already include it; extraction only happens when sshd is absent.
if [ ! -x /storage/usr/bin/sshd ] && \
   [ -f /flash/openssh-thor.pkg.tar.xz ]; then
  if (cd /storage && bb xzcat /flash/openssh-thor.pkg.tar.xz | bb tar -xpf -); then
    bb rm -f /storage/.BUILDINFO /storage/.INSTALL /storage/.MTREE /storage/.PKGINFO
    omarchy_log "thor-apply-storage: restored OpenSSH recovery payload" 2>/dev/null || true
  else
    omarchy_log "thor-apply-storage: OpenSSH recovery payload failed" 2>/dev/null || true
  fi
fi
if [ -f /flash/omarchy-thor-usb-gadget.sh ] && \
   [ -f /flash/omarchy-thor-usb-gadget.service ]; then
  bb mkdir -p /storage/usr/local/bin /storage/etc/systemd/system/multi-user.target.wants
  bb cp /flash/omarchy-thor-usb-gadget.sh /storage/usr/local/bin/omarchy-thor-usb-gadget
  bb chmod 755 /storage/usr/local/bin/omarchy-thor-usb-gadget
  bb cp /flash/omarchy-thor-usb-gadget.service \
    /storage/etc/systemd/system/omarchy-thor-usb-gadget.service
  bb ln -sf /etc/systemd/system/omarchy-thor-usb-gadget.service \
    /storage/etc/systemd/system/multi-user.target.wants/omarchy-thor-usb-gadget.service
  if [ -f /storage/usr/lib/systemd/system/sshd.service ]; then
    bb ln -sf /usr/lib/systemd/system/sshd.service \
      /storage/etc/systemd/system/multi-user.target.wants/sshd.service
  fi
fi
if [ -f /flash/omarchy-thor-debug.pub ] && [ -n "$owner_home" ] && \
   [ -d "/storage$owner_home" ]; then
  bb mkdir -p "/storage$owner_home/.ssh"
  if [ ! -f "/storage$owner_home/.ssh/authorized_keys" ] || \
     ! grep -Fqx "$(bb cat /flash/omarchy-thor-debug.pub)" \
       "/storage$owner_home/.ssh/authorized_keys"; then
    bb cat /flash/omarchy-thor-debug.pub >>"/storage$owner_home/.ssh/authorized_keys"
  fi
  bb chmod 700 "/storage$owner_home/.ssh"
  bb chmod 600 "/storage$owner_home/.ssh/authorized_keys"
  bb chown -R 1000:1000 "/storage$owner_home/.ssh"
fi

if [ -f /flash/omarchy-thor-wait-dri.sh ]; then
  bb mkdir -p /storage/usr/local/bin \
    /storage/etc/systemd/system/sddm.service.d \
    /storage/etc/systemd/system/graphical.target.wants \
    /storage/usr/local/share/wayland-sessions
  bb cp /flash/omarchy-thor-wait-dri.sh /storage/usr/local/bin/omarchy-thor-wait-dri
  bb chmod 755 /storage/usr/local/bin/omarchy-thor-wait-dri
  [ -f /flash/sddm-thor.conf ] && \
    bb cp /flash/sddm-thor.conf /storage/etc/systemd/system/sddm.service.d/thor.conf
  [ -f /flash/sddm-hyprland.lua ] && {
    bb mkdir -p /storage/usr/share/sddm /storage/etc/sddm.conf.d
    bb cp /flash/sddm-hyprland.lua /storage/usr/share/sddm/hyprland.lua
    bb rm -f /storage/usr/share/sddm/hyprland.conf \
      /storage/usr/share/sddm/._hyprland.conf \
      /storage/usr/share/sddm/._hyprland.lua \
      /storage/boot/sddm-hyprland.conf
    # The wrapper uses a boot-local HOME, but remove the known poisonous
    # SDDM-user leftovers as well so alternate launch paths stay safe.
    bb rm -f /storage/var/lib/sddm/.config/hypr/hyprland.conf \
      /storage/var/lib/sddm/.config/hypr/monitors.conf \
      /storage/var/lib/sddm/.config/hypr/ayn-thor.conf
  }
  [ -f /flash/sddm-wayland.conf ] && {
    bb cp /flash/sddm-wayland.conf /storage/etc/sddm.conf.d/thor-wayland.conf
    bb cp /flash/sddm-wayland.conf /storage/etc/sddm.conf.d/99-thor-wayland.conf
    bb cp /flash/sddm-wayland.conf /storage/etc/sddm.conf.d/10-wayland.conf
  }
  [ -f /flash/omarchy-thor-greeter.sh ] && {
    bb cp /flash/omarchy-thor-greeter.sh /storage/usr/local/bin/omarchy-thor-greeter
    bb chmod 755 /storage/usr/local/bin/omarchy-thor-greeter
  }
  [ -f /flash/omarchy-thor-outputs.sh ] && {
    bb cp /flash/omarchy-thor-outputs.sh /storage/usr/local/bin/omarchy-thor-outputs
    bb chmod 755 /storage/usr/local/bin/omarchy-thor-outputs
  }
  [ -f /flash/omarchy-thor-desktop.sh ] && {
    bb cp /flash/omarchy-thor-desktop.sh /storage/usr/local/bin/omarchy-thor-desktop
    bb chmod 755 /storage/usr/local/bin/omarchy-thor-desktop
  }
  [ -f /flash/omarchy-thor-session.sh ] && {
    bb cp /flash/omarchy-thor-session.sh /storage/usr/local/bin/omarchy-thor-session
    bb chmod 755 /storage/usr/local/bin/omarchy-thor-session
  }
  [ -f /flash/omarchy-thor-osk.sh ] && {
    bb cp /flash/omarchy-thor-osk.sh /storage/usr/local/bin/omarchy-thor-osk
    bb chmod 755 /storage/usr/local/bin/omarchy-thor-osk
  }
  [ -f /flash/wvkbd-mobintl ] && {
    bb cp /flash/wvkbd-mobintl /storage/usr/local/bin/wvkbd-mobintl
    bb chmod 755 /storage/usr/local/bin/wvkbd-mobintl
  }
  [ -f /flash/omarchy-thor-desktop-log.sh ] && {
    bb cp /flash/omarchy-thor-desktop-log.sh /storage/usr/local/bin/omarchy-thor-desktop-log
    bb chmod 755 /storage/usr/local/bin/omarchy-thor-desktop-log
  }
  [ -f /flash/omarchy-thor-desktop-log.service ] && {
    bb cp /flash/omarchy-thor-desktop-log.service \
      /storage/etc/systemd/system/omarchy-thor-desktop-log.service
    bb ln -sf /etc/systemd/system/omarchy-thor-desktop-log.service \
      /storage/etc/systemd/system/graphical.target.wants/omarchy-thor-desktop-log.service
  }
  [ -f /flash/omarchy-thor.desktop ] && \
    bb cp /flash/omarchy-thor.desktop \
      /storage/usr/local/share/wayland-sessions/omarchy-thor.desktop
  [ -f /flash/omarchy-thor-desktop-fallback.sh ] && {
    bb cp /flash/omarchy-thor-desktop-fallback.sh \
      /storage/usr/local/bin/omarchy-thor-desktop-fallback
    bb chmod 755 /storage/usr/local/bin/omarchy-thor-desktop-fallback
  }
  [ -f /flash/omarchy-thor-desktop-fallback.service ] && {
    bb cp /flash/omarchy-thor-desktop-fallback.service \
      /storage/etc/systemd/system/omarchy-thor-desktop-fallback.service
    bb ln -sf /etc/systemd/system/omarchy-thor-desktop-fallback.service \
      /storage/etc/systemd/system/graphical.target.wants/omarchy-thor-desktop-fallback.service
  }
fi

omarchy_log "thor-apply-storage: wrote firmware + desktop files onto ext4" 2>/dev/null || true
