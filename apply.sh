#!/usr/bin/env bash
#
# Install the theme into the running code-server.
#
# code-server serves its login and error pages from files inside its own
# install tree, and `dpkg -i` of a new release replaces that tree wholesale —
# so every upgrade reverts the theme. Run this afterwards to put it back.
# Idempotent; safe to run any number of times.
#
#   ./apply.sh
#
# Only the theme is handled here, because it is the only part that an upgrade
# destroys. The nginx and systemd files under nginx/ and systemd/ are one-time
# setup — see README.md.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/theme"
DEST="${CODE_SERVER_PAGES:-/usr/lib/code-server/src/browser/pages}"

if [[ ! -d $DEST ]]; then
  echo "error: $DEST not found — is code-server installed?" >&2
  echo "       override with CODE_SERVER_PAGES=/path/to/src/browser/pages" >&2
  exit 1
fi

# Installing as root into a root-owned tree. If we are already root, skip sudo
# so this works in a container or from a provisioning script.
SUDO=sudo
[[ $EUID -eq 0 ]] && SUDO=""

# Back up the genuine upstream files exactly once. Re-running must never
# clobber a .orig with a themed file, or the originals are lost forever.
for f in global.css login.css login.html error.css; do
  if [[ -f "$DEST/$f" && ! -f "$DEST/$f.orig" ]]; then
    $SUDO cp -p "$DEST/$f" "$DEST/$f.orig"
    echo "backed up $f -> $f.orig"
  fi
done

# The repo keeps fonts in theme/fonts/ for tidiness, but they deploy flat
# beside the CSS because global.css references them relatively (./x.woff2) —
# that is what makes the theme survive any {{CS_STATIC_BASE}} change.
n=0
for f in "$SRC"/*.css "$SRC"/*.html "$SRC"/favicon.svg "$SRC"/fonts/*.woff2; do
  $SUDO install -m 0644 "$f" "$DEST/$(basename "$f")"
  n=$((n + 1))
done

echo "installed $n files into $DEST"
echo
echo "No restart needed: login.html is read from disk per request."
echo "Hard-reload the browser (cmd-shift-r) if the old styling persists."
