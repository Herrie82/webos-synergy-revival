#!/bin/bash
# deploy-googlechat.sh — install the Google Chat Synergy surface onto the connected
# TouchPad via novacom: account template + custom setup app (com.palm.app.googlechat)
# + the prpl plugin + its libprotobuf-c runtime. Mirrors deploy-facebook.sh.
#
# Auth is 5 browser cookies (COMPASS/SSID/SID/OSID/HSID) collected by the setup app and
# stored as prpl protocol options (COMPASS_token, ...). No password/OAuth. libgooglechat.so
# links libprotobuf-c.so.1 (Google Chat's protobuf wire format), which is NOT part of the
# stock backend, so we stage it next to the plugin. json-glib is already on-device (Discord).
set -e
PKG="$(cd "$(dirname "$0")" && pwd)"
NR="novacom run file://bin/sh"
# NOTE: this novacom build word-splits `sh -c "cmd"`, so run remote shell commands by
# piping the (already-expanded) command string on stdin instead of via -c.
nr() { printf '%s\n' "$1" | novacom run file://bin/sh; }
BACKEND_PURPLE2="${BACKEND_PURPLE2:-/usr/lib/purple-2}"
BUILD="$PKG/plugin/purple-googlechat/build-arm"
PRPL="$BUILD/libgooglechat.stripped.so"
PBC="$BUILD/libprotobuf-c.stripped.so"

echo "== 1. push custom setup app com.palm.app.googlechat =="
APPDIR=/media/cryptofs/apps/usr/palm/applications/com.palm.app.googlechat
nr "mkdir -p $APPDIR/source $APPDIR/images"
cd "$PKG/apps/com.palm.app.googlechat"
for f in appinfo.json validator.html depends.js framework_config.json source/validator.js \
         images/header-icon.png images/icon-256x256.png; do
  novacom put "file://$APPDIR/$f" < "$f"
done

echo "== 2. install account template (rootfs rw) =="
ACC=/usr/palm/public/accounts/com.palm.googlechat
nr "mount -o remount,rw /dev/mapper/store-root / ; mkdir -p $ACC/images"
cd "$PKG/account/com.palm.googlechat"
novacom put "file://$ACC/com.palm.googlechat.json" < com.palm.googlechat.json
for f in images/googlechat-32x32.png images/googlechat-48x48.png; do
  novacom put "file://$ACC/$f" < "$f"
done
echo "== 3. drop libprotobuf-c.so.1 (private synergy-runtime dir) + libgooglechat.so (/usr/lib/purple-2) =="
BACKEND_LIB="${BACKEND_LIB:-/usr/lib/synergy-runtime}"
if [ -f "$PRPL" ] && [ -f "$PBC" ]; then
  nr "mount -o remount,rw /dev/mapper/store-root / ; mkdir -p $BACKEND_PURPLE2 $BACKEND_LIB"
  novacom put "file://$BACKEND_LIB/libprotobuf-c.so.1" < "$PBC"
  novacom put "file://$BACKEND_PURPLE2/libgooglechat.so" < "$PRPL"
  nr "mount -o remount,ro /dev/mapper/store-root / || true"
else
  echo "   !! not built — run ./build-googlechat.sh first (see README.md)"
fi

echo "== 4. rescan apps + accounts =="
nr "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
nr "for p in \$(pidof accounts.js 2>/dev/null); do kill \$p; done 2>/dev/null || true"
nr "P=\$(pidof LunaSysMgr); [ -n \"\$P\" ] && kill -9 \$P || true"
echo "== done. Settings > Accounts > Add > Google Chat: email + the five cookie values =="
