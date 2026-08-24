# Thor SDDM greeter: upside-down + Hyprland parse error

Hand-off brief. Another model should be able to work from this file plus
the repo without the chat history.

**Status (2026-08-24):** post-login Hyprland can reach a shell. The
**SDDM login** is still upside down (180°) with a Hyprland emergency-mode
red bar. Latest FAT write (greeter = official `hl.config` + same
`hl.monitor` as the user session; no `hyprctl keyword monitor`) did
**not** fix login. User reported “same issues.”

## What this project is

Omarchy Quattro (Arch + Hyprland 0.55 **Lua** configs) on an **AYN Thor**
(SM8550 / `qcs8550-ayn-thor`) as a spare-microSD OS.

| | |
|---|---|
| Device | AYN Thor, serial `5ea95b5f`, kernel **7.1.2** |
| Image builder | `/Users/hyper/projects/tensorfleet/omarchy-cm5` (`BOARD=ayn-thor`) |
| Device journal | `/Users/hyper/projects/me/ayn-thor` |
| Bootloader | ROCKNIX-ABL v1.1.7 already on `abl_a`/`abl_b` — **do not reflash** |
| Spare card | **31.9 GB** (`disk25` on the Mac). FAT `ROCKNIX` 536.9 MB + 31.4 GB ext4 |
| Hostname | `thor-omarchy`, user `hyper` already provisioned |
| Rollback | Official ROCKNIX card — swap cards, never flash the 217G ROM card |

FAT-only updates: `bash build/update-thor-fat.sh disk25` after staging
into `build/thor-boot-update/`. That copies KERNEL/SYSTEM/hooks onto the
FAT. `overlay/thor/thor-apply-storage.sh` then copies those files onto
ext4 **after** `LABEL=STORAGE` is mounted (LibreELEC init). Copies in
`post-sysroot.sh` vanish.

## Hardware facts

- Dual DSI: **DSI-2 = top lid**, **DSI-1 = bottom deck**.
- Native mode **1080×1920** portrait. DTS sets `rotation = <90>` on both
  panels (`ayn-thor/.cache/rocknix-src/thor/qcs8550-ayn-thor.dts`).
- DRM is `card0` (DSI-1, DSI-2, DP-1, renderD128).
- Clamshell is used **landscape**. First “gray desktop” with default
  `preferred` / no userspace transform looked correctly landscape.
- GPU needs `qcom/a740_sqe.fw` + `gmu_gen70200.bin` +
  `qcom/sm8550/a740_zap.mbn`. Without SQE, `fb0` still works and
  Hyprland/GLES dies. Firmware is on FAT `firmware/` and applied to
  `/usr/lib/firmware` each boot.
- Early dmesg always fails `a740_sqe.fw` (~1s, before ext4 apply). It
  loads around 31s “from new location.” SDDM starts ~19s — **greeter
  Hyprland can start before GLES firmware is present.**

## Split symptom (important)

| Surface | What the user sees |
|---|---|
| **SDDM greeter** | Purple Omarchy login, **both panels 180°**, red Hyprland emergency box. Bottom often clones the login (no OSK) or was black on one boot. |
| **User session** | After password: got further. Black frame + cursor, then a **shell**. Orientation of the shell was not reported as wrong. |

So the compositor **can** run a usable session. The greeter path is
still in **emergency mode**, which ignores monitor layout and presents
the default buffer (here: upside down + cloned).

Emergency banner text from photos (OCR, may be garbled):

1. Greeter / early: `unknown config key: handle_switch_signal` and
   `host from /home/hyprland/.host:1: unknown config key: handle_switch_signal`.
2. After login (user home):
   `/home/hyper/.config/hypr/monitors.conf:31: unknown config key 'render:explicit_sync'`.
3. Generic: `Emergency mode triggered: at least one config error occurred
   or no hosts being registered.`

Hyprland 0.55 Lua compiles modules to an internal hyprlang view and
often reports errors as `something.conf:line` even when the source is
`.lua`. `render:explicit_sync` is a **hyprlang** key from old `.conf`
snippets (`render { explicit_sync = 0 }`). `handle_switch_signal` was
seen when greeter Lua called `hl.config({ render.explicit_sync,
cursor.no_hardware_cursors })` — this build rejects those keys.

Omarchy 4 **official** greeter Lua (`usr/share/sddm/hyprland.lua` in
`omarchy-settings`) is only:

```lua
hl.config({
  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    force_default_wallpaper = 0,
  },
  animations = { enabled = false },
})
```

Official SDDM: `CompositorCommand=start-hyprland -- --config /usr/share/sddm/hyprland.lua`
(`etc/sddm.conf.d/10-wayland.conf`). Official session:
`uwsm start -g -1 -e -D Hyprland hyprland.desktop`.

User session entry is `~/.config/hypr/hyprland.lua` →
`require("hypr.monitors")` etc. Default autostart:

```lua
hl.on("hyprland.start", function()
  hl.exec_cmd("omarchy-launch-shell")  -- quickshell
  ...
end)
```

`hl.exec_cmd` / `hl.on` / `hl.monitor` / `hl.config({ misc, animations })`
are used by stock Omarchy and **work after login**. Rejected keys we have
actually seen: `render:explicit_sync`, `handle_switch_signal`, and
hyprlang `monitor =` in a `.conf` on a Lua-first compositor.

## What already works

- Stock KERNEL + SYSTEM stub pivot onto ext4 Arch.
- First-boot provision done; account exists.
- Firmware apply: `thor-apply-storage: wrote firmware + desktop files onto ext4`.
- SDDM comes up (purple theme on both panels).
- User can authenticate and get a shell.
- `dev-dri-card0.device` must **not** be in `Wants=` (90s hang). Drop-in
  is ExecStartPre `omarchy-thor-wait-dri` only.

## Dead ends (do not repeat)

1. **`transform = 1` on top of DTS `rotation = 90`.** Stacked to 180°.
   First correct landscape look was **no** userspace transform.
2. **`monitor =` in `.conf` / `ayn-thor.conf`.** Lua Hyprland: unknown
   keyword `monitor`; red bar; autostart never runs.
3. **`hl.config({ render = { explicit_sync = 0 }, cursor = { no_hardware_cursors = true } })`.**
   Emergency; keys show up as `handle_switch_signal` / `explicit_sync`.
4. **`hyprctl keyword monitor "DSI-2,preferred,0x0,1"`.** Injects hyprlang
   `monitor` into a Lua compositor. Suspected greeter poison. Now a no-op
   in `omarchy-thor-outputs.sh`.
5. **OSK via `hl.exec` in greeter Lua, or start OSK before the Wayland
   socket exists.** Silent fail; DSI-1 black. wvkbd has **no** `--output`.
6. **`Wants=dev-dri-card0.device`.** Boot hang.
7. **Cherry-picked firmware.** Need the full Thor overlay including
   `a740_sqe.fw`.
8. **Trusting `post-sysroot: installed *`.** Those copies are onto empty
   `/storage` before ext4 mounts and disappear.
9. **Reflash ABL / write the 217G ROM card / write the 1 TB T7.**

## Current greeter / session wiring

FAT → ext4 via `thor-apply-storage.sh` (only if
`/storage/usr/lib/systemd/systemd` exists).

| FAT file | Live path |
|---|---|
| `sddm-hyprland.lua` | `/usr/share/sddm/hyprland.lua` |
| `sddm-wayland.conf` | `/etc/sddm.conf.d/{10,99,thor}-wayland.conf` — `CompositorCommand=/usr/local/bin/omarchy-thor-greeter` |
| `omarchy-thor-greeter.sh` | `/usr/local/bin/omarchy-thor-greeter` |
| `thor-monitors.lua` | `~/.config/hypr/monitors.lua` (and skel / omarchy share) |
| `omarchy-thor-session.sh` | `/usr/local/bin/omarchy-thor-session` (`omarchy-thor.desktop`) |
| `omarchy-thor-desktop.sh` | starts `omarchy-launch-shell` + `xdg-terminal-exec` |
| `omarchy-thor-osk.sh` + `wvkbd-mobintl` | bottom-deck OSK (not proven) |

Greeter wrapper (latest):

```bash
export XDG_CONFIG_HOME=/tmp/thor-sddm-hypr
unset OMARCHY_PATH
mkdir -p "$XDG_CONFIG_HOME/hypr"
exec Hyprland --config /usr/share/sddm/hyprland.lua
```

Apply-storage **deletes** `monitors.conf`, `ayn-thor.conf`,
`/usr/share/sddm/hyprland.conf` and overwrites official
`10-wayland.conf` so `start-hyprland` is not used.

Stock leftover `overlay/thor/sddm-hyprland.conf` still exists in git
(hyprlang `monitor =` + `explicit_sync`). It must **not** land on
`/usr/share/sddm/hyprland.conf`.

## Log evidence (last `omarchy-desktop.log` on FAT)

Device clock in logs is wrong (2026-07-24 / Jul 25).

- `sddm: active`, greeter session started.
- Process: `Hyprland --config /usr/share/sddm/hyprland.lua` (our wrapper
  path). Greeter binary present (437 B at that snapshot).
- No `journalctl` lines for `_COMM=Hyprland` or `omarchy-shell` in that
  12s snapshot (log runs too early — greeter only).
- `a740_sqe.fw` fail at 0.94s, apply-storage at 12.7s and 17.0s, SQE
  loaded at 31.5s. SDDM started ~18.8s.
- No `omarchy-osk.log` was present.

`update-thor-fat.sh` auto-detect used `whole=${ident%%s*}` which turns
`disk25s1` into `di`. Fixed to `${ident%%s[0-9]*}`. Prefer
`bash build/update-thor-fat.sh disk25`.

## 2026-08-24: greeter fixed; black desktop root cause

The greeter now starts cleanly, both DSI panels use `transform = 3`, touch is
mapped to its corresponding output, and `wvkbd-mobintl` runs on DSI-1.

The later “black desktop with only a movable pointer” was not a Hyprland or
autostart failure. The delayed desktop snapshot proved that the user session,
UWSM, Hyprland socket, monitor layout, Omarchy path, shell launcher, and QML
tree were all present. `omarchy-launch-shell` repeatedly exited with:

```
quickshell: undefined symbol: _ZN23QUntypedPropertyBindingC1EP23QPropertyBindingPrivate,
version Qt_6_PRIVATE_API
```

The installed image had `qt6-base 6.11.2-2` and `qt6-declarative 6.11.2-1`,
but QuickShell's `.BUILDINFO` recorded Qt 6.11.1. QuickShell consumes Qt
private API, so this patch-version mismatch is ABI-breaking even though pacman
accepts the package.

The package builder now upgrades every reused build chroot before compiling,
and the image build runs `quickshell --version` as an ABI gate. For already
flashed cards, `mk-thor-bootfiles.sh` stages an ABI-matched `quickshell.xz`;
`thor-apply-storage.sh` verifies its SHA-256 and atomically installs it before
SDDM starts.

The hypotheses below describe the earlier greeter investigation and are kept
as historical context; they are no longer the active desktop diagnosis.

## Top-panel corruption after login

The top DSI panel later developed a full-screen noisy magenta/white scanout
while the bottom panel remained correct. `grim -o DSI-2` captured a completely
clean Omarchy desktop at the same time, proving that QuickShell and Hyprland's
rendered buffer were intact. The kernel logged the corresponding hardware
failure on DSI-2's encoder (`enc38`, CRTC-1 at 120 Hz):

```
[drm:dpu_encoder_frame_done_timeout] [dpu error]enc38 frame done timeout
[drm:_dpu_encoder_phys_cmd_wait_for_idle] *ERROR* id:38 pp:2 kickoff timeout
[drm:dpu_encoder_phys_cmd_prepare_for_kickoff] *ERROR* ret:-110 pp:2
```

A DSI-2-only DPMS off/on cycle recovered the panel. Selecting the panel's
advertised `1080x1920@60` mode instead of `preferred` (120 Hz) reduces load,
but a longer capture soak reproduced the same timeout at 60 Hz; it is not a
complete fix.

The ROCKNIX SM8550 build uses the older ICNA35xx driver. ROCKNIX's newer
SM8750 copy contains a relevant fix: it caches brightness reads and suppresses
DSI brightness writes until the panel is enabled because a brightness
operation racing panel bring-up or a frame kickoff can wedge the DSI command
engine. That change still needs to be ported into a rebuilt SM8550 kernel.

Until that kernel is available, `omarchy-thor-display-recover.service` follows
the kernel log for the encoder-38 timeout and immediately performs a DSI-2-only
DPMS cycle. It is an automatic recovery, not a claim that the underlying
driver race is resolved.

## Open hypotheses (ranked)

1. **Greeter still parses a leftover `.conf`.** Isolation may be
   incomplete (`start-hyprland` still winning a drop-in, Hyprland
   loading `/usr/share/sddm/hyprland.conf` or sddm user
   `/var/lib/sddm/.config/hypr/*`, or AppleDouble/`._*` junk). Need a
   live listing of every file Hyprland opens at greeter start
   (`strace -e openat` or Hyprland debug log to FAT).
2. **A key in the current greeter Lua is still illegal**
   (`force_default_wallpaper`, `hl.on`, `hl.exec_cmd` in the greeter
   process). User session uses those after login; greeter Hyprland is a
   different argv/`XDG_CONFIG_HOME`. Bisect: empty `hl.monitor` only vs
   official-only `hl.config` vs both.
3. **Emergency = “no hosts registered”** because wildcard/named
   `hl.monitor` does not bind these DSI names at greeter time (panels
   not up, or names differ). Then default scan is 180° off.
4. **Orientation is not a parse bug.** Kernel `rotation = 90` plus
   how the greeter Qt theme draws vs how the user session draws. Then
   the red bar is a separate leftover, and login needs `transform = 2`
   (180°) **only after** emergency is gone. Do **not** add `transform = 1`
   again.
5. **GPU firmware race.** Greeter starts before SQE; compositor
   emergency or broken output config; user session starts later and is
   fine. Fix: delay SDDM until `a740_sqe.fw` has loaded (wait-dri
   already waits for `/dev/dri/card0` only).
6. **SDDM Qt theme** is 180° independently of Hyprland (less likely
   given the Hyprland emergency chrome is also upside down).

## Suggested next debug (on device or next FAT)

1. Write Hyprland stderr / `--verbose` from the greeter wrapper to
   `/flash/omarchy-greeter.log` so the **exact** unknown key is known.
2. On the live root (or from a chroot of ext4):
   `ls -la /usr/share/sddm/`
   `ls -la /etc/sddm.conf.d/`
   `ls -la /var/lib/sddm/.config/hypr/`
   `cat /usr/share/sddm/hyprland.lua`
   confirm no `hyprland.conf` / `monitors.conf` / `explicit_sync`.
3. Bisect greeter Lua to **one** of: official-only `hl.config`;
   monitors-only; empty file. See which one loses the red bar.
4. Only after the red bar is gone: if login is still 180°, try
   `transform = 2` on both `hl.monitor`s. If sideways, try `3`.
5. Delay SDDM until SQE is loaded; compare greeter.
6. OSK is secondary. Bottom clone/black is emergency or no layer-shell
   client. Pin with `hyprctl keyword layerrule` after a clean compositor.

## Constraints for anyone changing this

- Do not commit unless asked. Do not edit the Cursor plan file.
- Do not flash ABL. Do not write the 217G ROM card or the T7.
- Incremental path is FAT + `thor-apply-storage.sh`, not a 12G image
  rebuild.
- Omarchy 4 is Lua. Do not put `monitor =` in `.conf`.
- Built-in Mac SD reader sometimes shows `Link Speed: Off` until reseated.

## Key source paths

```
overlay/thor/sddm-hyprland.lua          # greeter Hyprland --config
overlay/thor/omarchy-thor-greeter.sh    # SDDM CompositorCommand
overlay/thor/sddm-wayland.conf
overlay/thor/thor-monitors.lua          # user session monitors
overlay/thor/thor-apply-storage.sh      # FAT → ext4
overlay/thor/omarchy-thor-session.sh
overlay/thor/omarchy-thor-desktop.sh
overlay/thor/omarchy-thor-osk.sh
overlay/thor/sddm-hyprland.conf         # leftover hyprlang — do not install
overlay/systemd/sddm.service.d/thor.conf
build/update-thor-fat.sh
build/thor-boot-update/                 # staged FAT payload (gitignored)
docs/thor.md
```
