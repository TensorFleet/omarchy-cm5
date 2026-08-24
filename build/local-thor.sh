#!/bin/bash
# Local Thor image pipeline on Apple Silicon / Linux via Docker.
# Usage (from repo root):
#   bash build/local-thor.sh            # packages + image
#   bash build/local-thor.sh packages   # stage 1 only
#   bash build/local-thor.sh image      # mkimage + verify (needs pkgs-out)
#   bash build/local-thor.sh all        # default
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
cd "$repo"

stage=${1:-all}
builder=omarchy-builder

need_docker() {
  docker info >/dev/null 2>&1 || {
    echo "Docker daemon is not running. Open Docker Desktop and retry." >&2
    exit 1
  }
}

ensure_builder() {
  docker image inspect "$builder" >/dev/null 2>&1 || \
    docker build -t "$builder" -f "$here/Dockerfile.builder" "$here"
}

fetch_prereqs() {
  [[ -d $repo/build/upstream/.git ]] || bash "$here/fetch-upstream.sh"
  [[ -f $repo/build/resolved/alarm-names.txt ]] || bash "$here/resolve-packages.sh"
  if [[ ! -f $repo/pkgs/aarch64-extra/linux-rocknix-sm8550/vendor/KERNEL ]]; then
    ensure_builder
    docker run --rm -v "$repo:/work" "$builder" \
      bash /work/build/fetch-thor-vendor.sh
  fi
  mkdir -p "$repo/build/node" "$repo/build/pkgs-out"
  if ! ls "$repo"/build/pkgs-out/quickshell-git-*.pkg.tar.* >/dev/null 2>&1 ||
     ! ls "$repo"/build/pkgs-out/wvkbd-*.pkg.tar.* >/dev/null 2>&1; then
    echo "=== pulling aarch64-pkgs release (if published) ==="
    published=$repo/build/published-pkgs
    rm -rf "$published"
    mkdir -p "$published"
    gh release download aarch64-pkgs -p '*.pkg.tar.*' -D "$published" \
      -R TensorFleet/omarchy-cm5 || true
    cp -n "$published"/*.pkg.tar.* "$repo/build/pkgs-out/" 2>/dev/null || true
  fi
  if ! ls "$repo"/build/node/node-v*-linux-arm64.tar.gz >/dev/null 2>&1; then
    file=$(curl -fsSL https://nodejs.org/dist/latest-v22.x/ |
      grep -o 'node-v[0-9.]*-linux-arm64\.tar\.gz' | head -1)
    curl -fL --retry 3 -o "$repo/build/node/$file" "https://nodejs.org/dist/latest-v22.x/$file"
  fi
}

stage_packages() {
  echo "=== stage 1: omarchy 'any' packages ==="
  # x86 Arch container (any-arch packages). DisableSandbox under Rosetta/qemu.
  docker run --rm --platform linux/amd64 -v "$repo:/work" archlinux/archlinux:latest \
    bash -c "sed -i -e '/^\[options\]/a DisableSandbox' -e '/^DownloadUser/d' /etc/pacman.conf \
             && bash /work/build/build-any-packages.sh"
  # Prefer native arm64 for binary repacks when the host is Apple Silicon.
  echo "=== stage 2a: aarch64 binary repacks ==="
  docker run --rm --platform linux/amd64 -v "$repo:/work" archlinux/archlinux:latest \
    bash -c "sed -i -e '/^\[options\]/a DisableSandbox' -e '/^DownloadUser/d' /etc/pacman.conf \
             && bash /work/pkgs/repack-bin.sh" || echo "repack-bin skipped/failed (non-fatal)"
  echo "=== stage 2b: Qt-ABI-matched Thor desktop packages ==="
  ensure_builder
  docker run --rm --privileged -v /dev:/dev -v "$repo:/work" \
    -v omarchy-thor-wvkbd:/pkgroot "$builder" env \
    CHROOT=/pkgroot OUT=/work/build/pkgs-out REQUIRE_ALL=1 \
    bash /work/pkgs/build-in-chroot.sh wvkbd quickshell-git
}

# Keep one newest non-debug package per name so mkimage doesn't copy 2 GB of
# duplicates into the chroot (repo-add then keeps only the latest anyway).
slim_pkgs() {
  local src=$repo/build/pkgs-out dest=$repo/build/pkgs-slim
  mkdir -p "$dest"
  find "$dest" -name '*.pkg.tar.*' -delete
  python3 - <<'PY' "$src" "$dest"
import os, re, sys
src, dest = sys.argv[1], sys.argv[2]
pat = re.compile(r"^(.+)-([^-]+)-([^-]+)-(any|aarch64|x86_64)\.pkg\.tar\.(zst|xz)$")
best = {}
for name in os.listdir(src):
    if "-debug-" in name or not name.endswith((".pkg.tar.zst", ".pkg.tar.xz")):
        continue
    m = pat.match(name)
    if not m:
        continue
    pkg = m.group(1)
    path = os.path.join(src, name)
    st = os.stat(path)
    prev = best.get(pkg)
    if prev is None or st.st_mtime > prev[0]:
        best[pkg] = (st.st_mtime, name)
for _, name in best.values():
    os.link(os.path.join(src, name), os.path.join(dest, name))
print(f"slimmed {len(best)} packages → {dest}")
PY
}

stage_image() {
  echo "=== stage 3: BOARD=ayn-thor image ==="
  ls "$repo"/build/pkgs-out/wvkbd-*.pkg.tar.* >/dev/null 2>&1 || {
    echo "missing wvkbd aarch64 package; run '$0 packages' first" >&2
    exit 1
  }
  ls "$repo"/build/pkgs-out/quickshell-git-*.pkg.tar.* >/dev/null 2>&1 || {
    echo "missing quickshell-git aarch64 package; run '$0 packages' first" >&2
    exit 1
  }
  ensure_builder
  slim_pkgs
  mkdir -p "$repo/build/cache/thor-pacman"
  local node
  node=$(ls "$repo"/build/node/node-v*-linux-arm64.tar.gz | head -1)
  docker run --rm --privileged -v /dev:/dev \
    -v omarchy-thor-image:/img \
    -v "$repo:/work" \
    "$builder" env \
      BOARD=ayn-thor \
      IMG=/img/omarchy-thor.img \
      IMG_SIZE=12G \
      CACHE_DIR=/work/build/cache/thor-pacman \
      LOCAL_PKG_DIR=/work/build/pkgs-slim \
      NODE_TARBALL_PATH="/work/build/node/$(basename "$node")" \
      bash /work/build/mkimage.sh
  docker run --rm --privileged -v /dev:/dev \
    -v omarchy-thor-image:/img \
    -v "$repo:/work" \
    "$builder" env BOARD=ayn-thor \
      bash /work/build/verify-image.sh /img/omarchy-thor.img
  echo "copying image out of the volume (this is several GB)…"
  docker run --rm -v omarchy-thor-image:/img -v "$repo/build:/out" "$builder" \
    bash -c 'cp -a /img/omarchy-thor.img /out/omarchy-thor.img
             cp -a /img/omarchy-thor.img.report.txt /out/ 2>/dev/null || true
             cp -a /img/omarchy-thor.VERIFICATION.txt /out/ 2>/dev/null || true
             ls -lh /out/omarchy-thor.img*'
  echo "image: $repo/build/omarchy-thor.img"
}

need_docker
fetch_prereqs
case $stage in
  packages) stage_packages ;;
  image) stage_image ;;
  all)
    stage_packages
    stage_image
    ;;
  *) echo "usage: $0 [all|packages|image]" >&2; exit 2 ;;
esac
