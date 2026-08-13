# aarch64 package pipeline

Upstream serves its custom packages from `https://pkgs.omarchy.org/stable/$arch`
— x86_64 only (probed every build by `build/resolve-packages.sh`; the day an
official aarch64 repo appears, the image builder adopts it automatically).
Until then this directory builds our own pool, published to the rolling
`aarch64-pkgs` GitHub release and merged into the image's local `[omarchy]`
repo at image-build time.

## How each package class is attacked

| Class | Packages | How |
|---|---|---|
| `arch=('any')` runtime | `omarchy`, `omarchy-settings`, `omarchy-nvim`, `omarchy-keyring`, fonts, `ufw-docker`, `yaru-icon-theme`, `tobi-try`, `tzupdate` | `build/build-any-packages.sh` — built from official PKGBUILDs in an x86 Arch container (file-copy packaging, arch-independent), pinned to `upstream.lock`'s commit |
| upstream ships aarch64 binaries | `omarchy-chromium-bin` (their patched Chromium!), `aether`, `localsend-bin` | `pkgs/repack-bin.sh` — makepkg repack with CARCH=aarch64, no compilation |
| compiled, PKGBUILD already declares aarch64 | `quickshell-git` (the bar/shell — the critical one), `cliamp` (Go), `herdr` (Rust), `ttfx` (Rust), `omacalc`/`omacut`/`omawrite` (Qt6/C++) | `pkgs/build-in-chroot.sh` — real `makepkg -s` inside a qemu-emulated ALARM aarch64 chroot |
| x86-only upstream | `tensaku`, `hyprland-preview-share-picker`, `obsidian`, `pinta`, `asdcontrol`, `gpu-screen-recorder` | skipped via `overlay/install/packages.skip`; revisit individually |

Anything unresolved at image-build time is shimmed only if it's a hard
dependency (see `omarchy-cm5-shims` in `build/build-any-packages.sh`) and
always listed in the build report.

## Running it

CI: **Actions → build-arm-packages** (also triggered by pushes touching
`pkgs/`). Jobs run in parallel; each uploads into the `aarch64-pkgs` release.
`build-image` picks the pool up on its next run.

Locally: see the headers of `repack-bin.sh` and `build-in-chroot.sh`.
