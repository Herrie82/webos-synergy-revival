#!/bin/bash
# deploy-whatsapp.sh — install the WhatsApp Synergy surface onto the connected TouchPad
# via novacom: account template + custom setup app (com.palm.app.whatsapp) + the prpl
# plugin + its opus/ogg/opusfile runtime deps. Mirrors deploy-telegram.sh.
#
# libwhatsmeow.so embeds the Go runtime (whatsmeow + modernc SQLite) statically (~19 MB)
# and links libopusfile/libopus/libogg (voice-note transcoding) and libresolv (Go net).
# opus+ogg exist in the WPE staging on-device; opusfile was cross-built here — stage all
# three next to the plugin so g_module_open can resolve them (same approach as Telegram's
# libgcrypt staging).
set -e
PKG="$(cd "$(dirname "$0")" && pwd)"
NR="novacom run file://bin/sh"
# NOTE: this novacom build word-splits `sh -c "cmd"`, so run remote shell commands by
# piping the (already-expanded) command string on stdin instead of via -c.
nr() { printf '%s\n' "$1" | novacom run file://bin/sh; }
BACKEND_PURPLE2="${BACKEND_PURPLE2:-/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/lib/purple-2}"
BACKEND_LIB="$(dirname "$BACKEND_PURPLE2")"
BUILD="$PKG/plugin/purple-gowhatsapp/build-arm"
PRPL="$BUILD/libwhatsmeow.stripped.so"
STAGING=/home/herrie/webos/wpe/staging-glibc-252

echo "== 1. push custom setup app com.palm.app.whatsapp =="
APPDIR=/media/cryptofs/apps/usr/palm/applications/com.palm.app.whatsapp
nr "mkdir -p $APPDIR/source $APPDIR/images"
cd "$PKG/apps/com.palm.app.whatsapp"
for f in appinfo.json validator.html depends.js framework_config.json source/validator.js \
         images/header-icon.png images/icon-256x256.png; do
  novacom put "file://$APPDIR/$f" < "$f"
done

echo "== 2. install account template (rootfs rw) =="
ACC=/usr/palm/public/accounts/com.palm.whatsapp
nr "mount -o remount,rw /dev/mapper/store-root / ; mkdir -p $ACC/images"
cd "$PKG/account/com.palm.whatsapp"
novacom put "file://$ACC/com.palm.whatsapp.json" < com.palm.whatsapp.json
for f in images/whatsapp-32x32.png images/whatsapp-48x48.png; do
  novacom put "file://$ACC/$f" < "$f"
done
nr "mount -o remount,ro /dev/mapper/store-root / || true"

echo "== 3. stage opus/ogg/opusfile runtime libs into backend/lib =="
nr "mkdir -p $BACKEND_LIB"
for L in libopusfile.so.0 libopus.so.0 libogg.so.0; do
  [ -f "$STAGING/lib/$L" ] && novacom put "file://$BACKEND_LIB/$L" < "$STAGING/lib/$L" && echo "  staged $L"
done

echo "== 4. drop libwhatsmeow.so into the live backend plugin dir =="
if [ -f "$PRPL" ]; then
  nr "mkdir -p $BACKEND_PURPLE2"
  novacom put "file://$BACKEND_PURPLE2/libwhatsmeow.so" < "$PRPL"
else
  echo "   !! not built — run ./build-whatsapp.sh first (see README.md)"
fi

echo "== 5. rescan apps + accounts =="
nr "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
nr "for p in \$(pidof accounts.js 2>/dev/null); do kill \$p; done 2>/dev/null || true"
nr "P=\$(pidof LunaSysMgr); [ -n \"\$P\" ] && kill -9 \$P || true"
echo "== done. Add Account > WhatsApp (phone number); finish by scanning the QR in Messaging =="
