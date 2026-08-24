-- Keep the base greeter at the official Omarchy configuration.  The kernel
-- panel orientation leaves SDDM sideways even after config errors are gone.
-- Transform 2 produced the opposite sideways orientation; 3 completes the
-- kernel panel rotation to the clamshell's landscape orientation.
hl.config({
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
  },
  animations = {
    enabled = false,
  },
})

hl.monitor({
  output = "DSI-2",
  -- Keep the top command-mode DSI panel off its unstable preferred 120 Hz
  -- mode.  At 120 Hz the DPU can time out and leave scanout visibly corrupt.
  mode = "1080x1920@60",
  position = "0x0",
  scale = 1,
  transform = 3,
})

hl.monitor({
  output = "DSI-1",
  mode = "preferred",
  position = "0x1080",
  scale = 1,
  transform = 3,
})

-- Bind each touchscreen to the panel it physically covers. Leave the input
-- transform automatic so Hyprland composes the libinput calibration matrix
-- with the corresponding output transform.
hl.device({
  name = "top_touchscreen",
  output = "DSI-2",
})

hl.device({
  name = "bottom_touchscreen",
  output = "DSI-1",
})
