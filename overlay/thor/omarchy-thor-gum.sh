#!/bin/bash
# Prefer the Thor letter picker for `gum input` so setup works without USB.
real=/usr/bin/gum
if [[ ${1:-} == input && -x /usr/local/bin/omarchy-thor-type ]]; then
  exec /usr/local/bin/omarchy-thor-type "$@"
fi
exec "$real" "$@"
