#!/bin/bash
# deploy-telegram.sh — install the Telegram Synergy surface onto the connected
# TouchPad via novacom: account template + custom setup app (com.palm.app.telegram)
# + the prpl plugin. Mirrors teams-port/pkg/deploy-teams-surface.sh.
#
# Unlike Discord (generic username/password validator, no app), Telegram ships a
# custom validator app that collects the phone number; the login code is entered
# later in the Messaging app (see PATCH-AUTH.md / PORT-PLAN sec.4).
#
# The modern libpurple 2.14 + ssl-openssl engine lives at the real /usr/lib (installed by the
# generic package); Telegram just adds its plugin there. Point BACKEND_PURPLE2 at that dir.
set -e
PKG="$(cd "$(dirname "$0")" && pwd)"
NR="novacom run file://bin/sh"
BACKEND_PURPLE2="${BACKEND_PURPLE2:-/usr/lib/purple-2}"
# The Telegram prpl is now the tdlib-purple build (libtelegram-tdlib.so from build-prpl.sh), which
# REPLACED the retired tgl-based src/purple-telegram/libtelegram.so. Deploy ONLY the tdlib .so and
# purge any other libtelegram*.so on-device (step 3) — see the crash note there.
PRPL="$PKG/plugin/tdlib-purple/build-arm/libtelegram-tdlib.stripped.so"
PRPL_NAME="libtelegram-tdlib.so"

echo "== 1. push custom setup app com.palm.app.telegram =="
APPDIR=/media/cryptofs/apps/usr/palm/applications/com.palm.app.telegram
$NR -- -c "mkdir -p $APPDIR/source $APPDIR/images"
cd "$PKG/apps/com.palm.app.telegram"
for f in appinfo.json validator.html depends.js framework_config.json source/validator.js \
         images/header-icon.png images/icon-256x256.png; do
  novacom put "file://$APPDIR/$f" < "$f"
done

echo "== 2. install account template (rootfs rw) =="
ACC=/usr/palm/public/accounts/com.palm.telegram
$NR -- -c "mount -o remount,rw / ; mkdir -p $ACC/images"
cd "$PKG/account/com.palm.telegram"
novacom put "file://$ACC/com.palm.telegram.json" < com.palm.telegram.json
for f in images/telegram-32x32.png images/telegram-48x48.png; do
  novacom put "file://$ACC/$f" < "$f"
done
# rootfs stays rw through steps 3-3b too now (both write to the real /usr/lib).

echo "== 3. drop the tdlib prpl into /usr/lib/purple-2 (purge any stale telegram .so first) =="
if [ -f "$PRPL" ]; then
  $NR -- -c "mkdir -p $BACKEND_PURPLE2"
  # CRITICAL: keep EXACTLY ONE telegram plugin. Two .so both registering "prpl-telegram" (e.g. the
  # retired tgl libtelegram.so lingering next to the tdlib libtelegram-tdlib.so) leave the prpl
  # UNREGISTERED -> at Telegram login the transport hits purple_find_prpl()==NULL -> uncaught
  # Util::getProtocolInfo MojoException -> terminate -> the WHOLE transport CRASH-LOOPS (every account
  # goes down, not just Telegram). So remove every libtelegram*.so that isn't the one we deploy.
  $NR -- -c "for f in $BACKEND_PURPLE2/libtelegram*.so; do [ -e \"\$f\" ] || continue; [ \"\$f\" = \"$BACKEND_PURPLE2/$PRPL_NAME\" ] || { rm -f \"\$f\" && echo \"  purged stale \$f\"; }; done; true"
  novacom put "file://$BACKEND_PURPLE2/$PRPL_NAME" < "$PRPL"
  echo "  deployed $PRPL_NAME ($(wc -c < "$PRPL") bytes)"
else
  echo "   !! $PRPL not built yet — run ./build-prpl.sh first (see README.md), then patch per PATCH-AUTH.md"
fi

echo "== 3b. ensure libtelegram-tdlib.so's runtime deps are in the private synergy-runtime dir =="
# readelf -d confirms tdlib-purple's only third-party NEEDED is libopus.so.0 (voice notes) --
# libcrypto/libssl/liblunaservice/libasound/libpalmgstskype are either handled by imwrap.sh
# (sslfix/preload) or expected already on stock. (The libgcrypt/libpng16/libwebp/libsharpyuv set
# staged here previously was for the RETIRED tgl-based telegram-purple, not tdlib-purple — stale,
# removed.) Kept OUT of /usr/lib (unlike libpurple.so itself) so it can't silently replace a
# system-wide lib version other apps rely on. Source = the atlas wpe-252 libs already on the
# device (version-matched).
BACKEND_LIB="${BACKEND_LIB:-/usr/lib/synergy-runtime}"
ATLAS_LIB=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252/lib
$NR -- -c "mkdir -p $BACKEND_LIB; for L in libopus.so.0; do \
  [ -f $BACKEND_LIB/\$L ] || cp -a $ATLAS_LIB/\$L $BACKEND_LIB/ 2>/dev/null && echo \"  staged \$L\" || echo \"  (skip \$L)\"; done"
$NR -- -c "mount -o remount,ro / || true"

echo "== 4. rescan apps + accounts =="
$NR -- -c "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
$NR -- -c "restart LunaSysMgr 2>/dev/null || true"
echo "== done. Settings > Accounts > Add > Telegram (phone number);"
echo "         then finish in Messaging by replying to the 'Telegram' chat with the code. =="
