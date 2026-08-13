#!/bin/bash
# Clone upstream omarchy at the ref pinned in upstream.lock into build/upstream.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../upstream.lock
source "$here/../upstream.lock"

dest="$here/upstream"

if [[ ! -d $dest/.git ]]; then
  git clone --branch "$OMARCHY_BRANCH" "$OMARCHY_REPO" "$dest"
fi

# The pinned ref may be a release-cut commit not at the branch tip; GitHub
# serves direct-SHA fetches for reachable commits, so try that before a full
# branch fetch.
if ! git -C "$dest" cat-file -e "$OMARCHY_REF^{commit}" 2>/dev/null; then
  git -C "$dest" fetch origin "$OMARCHY_REF" ||
    git -C "$dest" fetch origin "$OMARCHY_BRANCH"
fi

git -C "$dest" checkout --detach "$OMARCHY_REF"
echo "upstream omarchy at $(git -C "$dest" rev-parse --short HEAD) ($OMARCHY_VERSION)"
