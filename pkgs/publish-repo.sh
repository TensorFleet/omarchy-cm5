#!/bin/bash
# Publish build/pkgs-out as a servable pacman repo on the rolling
# `aarch64-pkgs` GitHub release. After this, any device (or image build) can:
#
#   [omarchy]
#   SigLevel = Optional TrustAll
#   Server = https://github.com/TensorFleet/omarchy-cm5/releases/download/aarch64-pkgs
#
# pacman requests <Server>/omarchy.db and <Server>/<pkgfile> — GitHub release
# assets are flat files under exactly that URL shape, so a release IS a repo.
# repo-add runs in a container (Arch tooling); upload needs `gh` auth.
#
# Debug packages (*-debug-*) are excluded from the db so pacman never picks
# them as providers.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${OUT:-$here/../build/pkgs-out}
REPO_TAG=${REPO_TAG:-aarch64-pkgs}
GH_REPO=${GH_REPO:-TensorFleet/omarchy-cm5}
DBNAME=omarchy

[[ -d $OUT ]] || { echo "no $OUT — build packages first" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }

# Fresh db from everything currently in the pool (minus debug packages).
rm -f "$OUT/$DBNAME".{db,files}*
if command -v repo-add >/dev/null; then
  (cd "$OUT" && repo-add -q "$DBNAME.db.tar.gz" $(ls *.pkg.tar.* | grep -v -- '-debug-'))
else
  docker run --rm --platform linux/amd64 -v "$OUT:/pool" archlinux/archlinux:latest \
    bash -c 'cd /pool && repo-add -q '"$DBNAME"'.db.tar.gz $(ls *.pkg.tar.* | grep -v -- "-debug-")'
fi

# GitHub can't host the omarchy.db -> omarchy.db.tar.gz symlink repo-add
# creates; replace it with a real copy so both asset names upload.
rm -f "$OUT/$DBNAME.db"
cp "$OUT/$DBNAME.db.tar.gz" "$OUT/$DBNAME.db"

gh release create "$REPO_TAG" -R "$GH_REPO" \
  --title "aarch64 package pool (rolling)" \
  --notes "Rolling pool of aarch64-built omarchy packages; also a servable pacman repo (Server = release download URL)." \
  2>/dev/null || true

echo "uploading packages + db to $GH_REPO release $REPO_TAG …" >&2
# Packages: never clobber (same-version re-uploads change bytes under a db
# that references the old size — devices fail with "maximum file size
# exceeded"). Only the db itself is replaced, and always last, so any db a
# client holds refers to assets that still exist.
gh release view "$REPO_TAG" -R "$GH_REPO" --json assets -q '.assets[].name' >"$OUT/.have" || true
for f in "$OUT"/*.pkg.tar.*; do
  grep -qxF "$(basename "$f")" "$OUT/.have" || gh release upload "$REPO_TAG" -R "$GH_REPO" "$f"
done
rm -f "$OUT/.have"
gh release upload "$REPO_TAG" -R "$GH_REPO" --clobber "$OUT/$DBNAME.db" "$OUT/$DBNAME.db.tar.gz"

echo "repo live: https://github.com/$GH_REPO/releases/download/$REPO_TAG" >&2
