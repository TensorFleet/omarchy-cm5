#!/bin/bash
# Publish local packages to the rolling `aarch64-pkgs` GitHub release and
# regenerate its pacman db, making the release a servable repo:
#
#   [omarchy]
#   SigLevel = Optional TrustAll
#   Server = https://github.com/TensorFleet/omarchy-cm5/releases/download/aarch64-pkgs
#
# Correctness rules (each learned the hard way):
#   1. Package assets are NEVER clobbered — a same-version re-upload changes
#      bytes under a db that records the old size and devices fail with
#      "maximum file size exceeded". First upload of a filename wins; new
#      versions get new filenames.
#   2. The db is generated ONLY from freshly downloaded release assets —
#      never from local bytes. Two builders (CI and a laptop) can build the
#      same pkgver with different bytes; whoever uploads first wins rule 1,
#      so local files may not be what clients fetch.
#   3. The db uploads last, so any db a client holds only references assets
#      that already exist.
#
# Debug packages (*-debug-*) are excluded from the db so pacman never picks
# them as providers.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${OUT:-$here/../build/pkgs-out}
REPO_TAG=${REPO_TAG:-aarch64-pkgs}
GH_REPO=${GH_REPO:-TensorFleet/omarchy-cm5}
DBNAME=omarchy

command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }

gh release create "$REPO_TAG" -R "$GH_REPO" \
  --title "aarch64 package pool (rolling)" \
  --notes "Rolling pool of aarch64-built omarchy packages; also a servable pacman repo (Server = release download URL)." \
  2>/dev/null || true

# --- 1. upload local packages the release doesn't have yet ------------------
shopt -s nullglob
local_pkgs=("$OUT"/*.pkg.tar.*)
if ((${#local_pkgs[@]})); then
  have=$(gh release view "$REPO_TAG" -R "$GH_REPO" --json assets -q '.assets[].name')
  for f in "${local_pkgs[@]}"; do
    if ! grep -qxF "$(basename "$f")" <<<"$have"; then
      echo "uploading $(basename "$f") …" >&2
      gh release upload "$REPO_TAG" -R "$GH_REPO" "$f"
    fi
  done
fi

# --- 2. regenerate the db from what the release ACTUALLY serves -------------
pool=$(mktemp -d)
trap 'rm -rf "$pool"' EXIT
echo "downloading release pool for db generation …" >&2
gh release download "$REPO_TAG" -R "$GH_REPO" -p '*.pkg.tar.*' -D "$pool"

if command -v repo-add >/dev/null; then
  (cd "$pool" && repo-add -q "$DBNAME.db.tar.gz" $(ls *.pkg.tar.* | grep -v -- '-debug-'))
else
  docker run --rm --platform linux/amd64 -v "$pool:/pool" archlinux/archlinux:latest \
    bash -c 'cd /pool && repo-add -q '"$DBNAME"'.db.tar.gz $(ls *.pkg.tar.* | grep -v -- "-debug-")'
fi

# GitHub can't host repo-add's omarchy.db symlink; upload a real copy under
# both names pacman may request. Db assets are the only clobber, always last.
rm -f "$pool/$DBNAME.db"
cp "$pool/$DBNAME.db.tar.gz" "$pool/$DBNAME.db"
gh release upload "$REPO_TAG" -R "$GH_REPO" --clobber "$pool/$DBNAME.db" "$pool/$DBNAME.db.tar.gz"

echo "repo live: https://github.com/$GH_REPO/releases/download/$REPO_TAG" >&2
