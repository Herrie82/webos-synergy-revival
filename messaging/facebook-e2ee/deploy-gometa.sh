#!/bin/bash
# deploy-gometa.sh — install the "Facebook (E2EE)" Synergy surface onto the TouchPad:
#   * account template com.palm.gometa (service type_gometa -> prpl-gometa via the transport's
#     generic type_->prpl- mapping; no transport change needed)
#   * custom setup app com.palm.app.gometa (collects email + password)
#   * the COMBINED plugin libwhatsmeow.so (WhatsApp + Facebook/messagix in ONE Go runtime)
# Mirrors deploy-facebook.sh. The combined .so replaces the WhatsApp libwhatsmeow.so (it is a
# superset). A backup libwhatsmeow.so.b4gometa is kept. Reboot/transport-restart to load.
set -e
PKG="$(cd "$(dirname "$0")" && pwd)"
# novacom's `sh -c` word-splits, so pipe commands on stdin instead.
nr() { printf '%s\n' "$1" | novacom run file://bin/sh; }
BACKEND_PURPLE2="${BACKEND_PURPLE2:-/usr/lib/purple-2}"
PRPL="$PKG/plugin/purple-combined/build-arm/libwhatsmeow.stripped.so"

echo "== 1. push setup app com.palm.app.gometa =="
APPDIR=/media/cryptofs/apps/usr/palm/applications/com.palm.app.gometa
nr "mkdir -p $APPDIR/source $APPDIR/images"
cd "$PKG/apps/com.palm.app.gometa"
for f in appinfo.json validator.html depends.js framework_config.json source/validator.js \
         images/header-icon.png images/icon-256x256.png; do
  novacom put "file://$APPDIR/$f" < "$f"
done

echo "== 2. install account template com.palm.gometa (rootfs rw) =="
ACC=/usr/palm/public/accounts/com.palm.gometa
nr "mount -o remount,rw /dev/mapper/store-root / ; mkdir -p $ACC/images"
cd "$PKG/account/com.palm.gometa"
novacom put "file://$ACC/com.palm.gometa.json" < com.palm.gometa.json
for f in images/facebook-32x32.png images/facebook-48x48.png; do
  novacom put "file://$ACC/$f" < "$f"
done
echo "== 3. deploy combined plugin into /usr/lib/purple-2 (unlink-first, size-verified) =="
if [ -f "$PRPL" ]; then
  SZ=$(wc -c < "$PRPL")
  gzip -c "$PRPL" > /tmp/libwhatsmeow.so.gz
  novacom put "file:///media/internal/libwhatsmeow.so.gz" < /tmp/libwhatsmeow.so.gz
  nr "mount -o remount,rw /dev/mapper/store-root / ; mkdir -p $BACKEND_PURPLE2; \
      cp $BACKEND_PURPLE2/libwhatsmeow.so $BACKEND_PURPLE2/libwhatsmeow.so.b4gometa 2>/dev/null; \
      gunzip -c /media/internal/libwhatsmeow.so.gz > /media/internal/libwhatsmeow.so.new; \
      N=\$(wc -c < /media/internal/libwhatsmeow.so.new); \
      if [ \"\$N\" = \"$SZ\" ]; then rm -f $BACKEND_PURPLE2/libwhatsmeow.so; \
        mv /media/internal/libwhatsmeow.so.new $BACKEND_PURPLE2/libwhatsmeow.so; \
        chmod 755 $BACKEND_PURPLE2/libwhatsmeow.so; echo installed \$N bytes; \
      else echo SIZE-MISMATCH \$N want $SZ; fi; \
      mount -o remount,ro /dev/mapper/store-root / || true"
else
  echo "   !! $PRPL not built — run plugin/purple-combined/build-combined.sh first"
fi

echo "== 4. rescan apps + re-read account templates =="
nr "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
nr "for p in \$(pidof accounts.js 2>/dev/null); do kill \$p; done 2>/dev/null || true"
nr "P=\$(pidof LunaSysMgr); [ -n \"\$P\" ] && kill -9 \$P || true"
echo "== done. Settings > Accounts > Add an account > Facebook (E2EE): email + password =="
