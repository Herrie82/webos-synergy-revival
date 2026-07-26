#!/bin/bash
# deploy-telegram.sh — install the Telegram Synergy surface onto the connected
# TouchPad via novacom: account template + custom setup app (com.palm.app.telegram)
# + the prpl plugin. Mirrors teams-port/pkg/deploy-teams-surface.sh.
#
# Unlike Discord (generic username/password validator, no app), Telegram ships a
# custom validator app that collects the phone number; the login code is entered
# later in the Messaging app (see PATCH-AUTH.md / PORT-PLAN sec.4).
#
# The modern libpurple 2.14 + ssl-openssl backend is ALREADY on the device from the
# teams-port work; Telegram reuses it. Point BACKEND_PURPLE2 at that plugin dir.
set -e
PKG="$(cd "$(dirname "$0")" && pwd)"
NR="novacom run file://bin/sh"
BACKEND_PURPLE2="${BACKEND_PURPLE2:-/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/lib/purple-2}"
# The Telegram prpl is now the tdlib-purple build (libtelegram-tdlib.so from build-prpl.sh), which
# REPLACED the retired tgl-based src/purple-telegram/libtelegram.so. Deploy ONLY the tdlib .so and
# purge any other libtelegram*.so on-device (step 3) — see the crash note there.
PRPL="$PKG/plugin/tdlib-purple/build-arm/libtelegram-tdlib.stripped.so"
PRPL_NAME="libtelegram-tdlib.so"

echo "== 1. push custom setup app com.palm.app.telegram =="
APPDIR=/media/cryptofs/apps/usr/palm/applications/com.palm.app.telegram
$NR -- -c "mkdir -p $APPDIR/source $APPDIR/images"
cd "$PKG/pkg/usr/palm/applications/com.palm.app.telegram"
for f in appinfo.json validator.html depends.js framework_config.json source/validator.js \
         images/header-icon.png images/icon-256x256.png; do
  novacom put "file://$APPDIR/$f" < "$f"
done

echo "== 2. install account template (rootfs rw) =="
ACC=/usr/palm/public/accounts/com.palm.telegram
$NR -- -c "mount -o remount,rw / ; mkdir -p $ACC/images"
cd "$PKG/pkg/usr/palm/public/accounts/com.palm.telegram"
novacom put "file://$ACC/com.palm.telegram.json" < com.palm.telegram.json
for f in images/telegram-32x32.png images/telegram-48x48.png; do
  novacom put "file://$ACC/$f" < "$f"
done
$NR -- -c "mount -o remount,ro / || true"

echo "== 3. drop the tdlib prpl into the live backend plugin dir (purge any stale telegram .so first) =="
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

echo "== 3b. ensure libtelegram.so runtime deps are in backend/lib =="
# tgl links libgcrypt (crypto), libpng16 + libwebp (+libsharpyuv) (sticker/avatar decode) and
# libgpg-error — deps that Teams/Discord don't need, so they were never staged in backend/lib.
# If the plugin's g_module_open can't resolve them, purple_find_prpl("prpl-telegram") returns
# NULL and the transport aborts (uncaught MojoException in Util::getProtocolInfo) => "stuck on
# Signing in". Stage them next to libjson-glib (the proven plugin-dep location). Source = the
# atlas wpe-252 libs already on the device (version-matched to gcrypt).
BACKEND_LIB="$(dirname "$BACKEND_PURPLE2")"
ATLAS_LIB=/media/cryptofs/apps/usr/palm/applications/org.webosports.app.atlas/deviceroot/wpe-252/lib
$NR -- -c "for L in libgcrypt.so.20 libgpg-error.so.0 libpng16.so.16 libwebp.so.7 libsharpyuv.so.0; do \
  [ -f $BACKEND_LIB/\$L ] || cp -a $ATLAS_LIB/\$L $BACKEND_LIB/ 2>/dev/null && echo \"  staged \$L\" || echo \"  (skip \$L)\"; done"

echo "== 4. rescan apps + accounts =="
$NR -- -c "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
$NR -- -c "restart LunaSysMgr 2>/dev/null || true"
echo "== done. Settings > Accounts > Add > Telegram (phone number);"
echo "         then finish in Messaging by replying to the 'Telegram' chat with the code. =="
