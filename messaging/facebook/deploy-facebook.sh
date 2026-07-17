#!/bin/bash
# deploy-facebook.sh — install the Facebook Synergy surface onto the connected
# TouchPad via novacom: account template + custom setup app (com.palm.app.facebook)
# + the prpl plugin. Mirrors deploy-discord.sh / deploy-telegram.sh.
#
# Facebook is a plain username(email)/password libpurple account (prpl-facebook), so
# there is no QR / OAuth flow — the customUI app just collects email + password and
# stores the password as the account credential; prpl-facebook logs in on connect.
#
# The modern libpurple 2.14 + ssl-openssl backend is ALREADY on the device from the
# teams-port work; Facebook reuses it. json-glib is already staged there too (Discord
# needs it), so libfacebook.so's only extra runtime dep beyond libpurple/glib is zlib,
# which the base system already provides. Point BACKEND_PURPLE2 at that plugin dir.
set -e
PKG="$(cd "$(dirname "$0")" && pwd)"
NR="novacom run file://bin/sh"
# NOTE: this novacom build word-splits `sh -c "cmd"`, so run remote shell commands by
# piping the (already-expanded) command string on stdin instead of via -c.
nr() { printf '%s\n' "$1" | novacom run file://bin/sh; }
BACKEND_PURPLE2="${BACKEND_PURPLE2:-/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/lib/purple-2}"
PRPL="$PKG/plugin/purple-facebook/build-arm/libfacebook.stripped.so"

echo "== 1. push custom setup app com.palm.app.facebook =="
APPDIR=/media/cryptofs/apps/usr/palm/applications/com.palm.app.facebook
nr "mkdir -p $APPDIR/source $APPDIR/images"
cd "$PKG/apps/com.palm.app.facebook"
for f in appinfo.json validator.html depends.js framework_config.json source/validator.js \
         images/header-icon.png images/icon-256x256.png; do
  novacom put "file://$APPDIR/$f" < "$f"
done

echo "== 2. install account template (rootfs rw) =="
ACC=/usr/palm/public/accounts/com.palm.facebook
nr "mount -o remount,rw /dev/mapper/store-root / ; mkdir -p $ACC/images"
cd "$PKG/account/com.palm.facebook"
novacom put "file://$ACC/com.palm.facebook.json" < com.palm.facebook.json
for f in images/facebook-32x32.png images/facebook-48x48.png; do
  novacom put "file://$ACC/$f" < "$f"
done
nr "mount -o remount,ro /dev/mapper/store-root / || true"

echo "== 3. drop libfacebook.so into the live backend plugin dir =="
if [ -f "$PRPL" ]; then
  nr "mkdir -p $BACKEND_PURPLE2"
  novacom put "file://$BACKEND_PURPLE2/libfacebook.so" < "$PRPL"
else
  echo "   !! $PRPL not built yet — run ./build-facebook.sh first (see README.md)"
fi

echo "== 4. rescan apps + accounts =="
nr "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
# re-read templates + re-scan cryptofs apps (kill = respawn)
nr "for p in \$(pidof accounts.js 2>/dev/null) \$(ps | grep -E 'accounts.js|service.accounts' | grep -v grep | awk '{print \$1}'); do kill \$p; done 2>/dev/null || true"
nr "P=\$(pidof LunaSysMgr); [ -n \"\$P\" ] && kill -9 \$P || true"
echo "== done. Settings > Accounts > Add > Facebook: enter email + password =="
