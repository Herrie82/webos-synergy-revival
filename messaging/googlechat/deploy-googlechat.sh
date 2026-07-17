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
BACKEND_PURPLE2="${BACKEND_PURPLE2:-/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/lib/purple-2}"
BUILD="$PKG/plugin/purple-googlechat/build-arm"
PRPL="$BUILD/libgooglechat.stripped.so"
PBC="$BUILD/libprotobuf-c.stripped.so"

echo "== 1. push custom setup app com.palm.app.googlechat =="
APPDIR=/media/cryptofs/apps/usr/palm/applications/com.palm.app.googlechat
$NR -- -c "mkdir -p $APPDIR/source $APPDIR/images"
cd "$PKG/apps/com.palm.app.googlechat"
for f in appinfo.json validator.html depends.js framework_config.json source/validator.js \
         images/header-icon.png images/icon-256x256.png; do
  novacom put "file://$APPDIR/$f" < "$f"
done

echo "== 2. install account template (rootfs rw) =="
ACC=/usr/palm/public/accounts/com.palm.googlechat
$NR -- -c "mount -o remount,rw / ; mkdir -p $ACC/images"
cd "$PKG/account/com.palm.googlechat"
novacom put "file://$ACC/com.palm.googlechat.json" < com.palm.googlechat.json
for f in images/googlechat-32x32.png images/googlechat-48x48.png; do
  novacom put "file://$ACC/$f" < "$f"
done
$NR -- -c "mount -o remount,ro / || true"

echo "== 3. drop libprotobuf-c.so.1 + libgooglechat.so into the live backend plugin dir =="
BACKEND_LIB="$(dirname "$BACKEND_PURPLE2")"
if [ -f "$PRPL" ] && [ -f "$PBC" ]; then
  $NR -- -c "mkdir -p $BACKEND_PURPLE2"
  novacom put "file://$BACKEND_LIB/libprotobuf-c.so.1" < "$PBC"
  novacom put "file://$BACKEND_PURPLE2/libgooglechat.so" < "$PRPL"
else
  echo "   !! not built — run ./build-googlechat.sh first (see README.md)"
fi

echo "== 4. rescan apps + accounts =="
$NR -- -c "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
$NR -- -c "for p in \$(pidof accounts.js 2>/dev/null); do kill \$p; done 2>/dev/null || true"
$NR -- -c "P=\$(pidof LunaSysMgr); [ -n \"\$P\" ] && kill -9 \$P || true"
echo "== done. Settings > Accounts > Add > Google Chat: email + the five cookie values =="
