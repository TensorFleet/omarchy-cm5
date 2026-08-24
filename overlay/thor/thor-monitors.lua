-- AYN Thor dual DSI. Same field set as the Hyprland 0.55 example.
-- Leftover monitors.conf (render:explicit_sync / transform) must stay
-- deleted — that file is what put the session in emergency mode.
--
-- See https://wiki.hypr.land/Configuring/Basics/Monitors/

local omarchy_gdk_scale = 2
local omarchy_monitor_scale = 1

hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))

hl.monitor({
  output = "DSI-2",
  -- The preferred 120 Hz mode intermittently wedges the SM8550 DPU command
  -- encoder (frame-done/kickoff timeout) and leaves the physical panel showing
  -- noise even though compositor screenshots remain clean.  The panel also
  -- advertises 60 Hz, which avoids the unstable high-rate path.
  mode = "1080x1920@60",
  position = "0x0",
  scale = omarchy_monitor_scale,
  transform = 3,
})
hl.monitor({
  output = "DSI-1",
  mode = "preferred",
  position = "0x1080",
  scale = omarchy_monitor_scale,
  transform = 3,
})

hl.device({
  name = "top_touchscreen",
  output = "DSI-2",
})

hl.device({
  name = "bottom_touchscreen",
  output = "DSI-1",
})
