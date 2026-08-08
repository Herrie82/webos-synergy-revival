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
BACKEND_PURPLE2="${BACKEND_PURPLE2:-/usr/lib/purple-2}"
BACKEND_LIB="${BACKEND_LIB:-/usr/lib/synergy-runtime}"
# The WhatsApp prpl is the COMBINED plugin (facebook-e2ee/purple-combined) - ONE libwhatsmeow.so
# hosts BOTH prpl-hehoe-whatsmeow and prpl-gometa (+ send-reaction, newsletters, calling). The old
# standalone purple-gowhatsapp was removed; build with facebook-e2ee/plugin/purple-combined/build-combined.sh.
BUILD="$PKG/../facebook-e2ee/plugin/purple-combined/build-arm"
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
# rootfs stays rw through steps 3-4 too now (both write to the real /usr/lib, not the always-writable
# /media/cryptofs app storage the old com.palm.app.teams/backend nesting used).

echo "== 3. stage opus/ogg/opusfile runtime libs into the private synergy-runtime dir (size-verified) =="
# A dropped novacom connection ("unexpected EOF from server") mid-`put` leaves a TRUNCATED (often
# 0-byte) file on the device with NO error. A 0-byte libopus.so.0 / libopusfile.so.0 then makes the
# loader reject EVERY plugin that needs it ("libopus.so.0: file too short") -> libtelegram-tdlib.so
# AND libwhatsmeow.so silently fail to register their prpl -> the transport aborts at that account's
# login. So verify the on-device byte count matches the source and retry; hard-fail if it can't.
nr "mkdir -p $BACKEND_LIB"
put_verify() {  # $1 = local source (follows symlinks), $2 = device dest path
  local want got; want=$(wc -c < "$1" 2>/dev/null)
  [ -n "$want" ] && [ "$want" -gt 0 ] || { echo "  !! source $1 missing/empty - skip"; return 1; }
  local t; for t in 1 2 3; do
    novacom put "file://$2" < "$1"
    got=$(nr "wc -c < $2 2>/dev/null" | tr -cd '0-9')
    [ "$got" = "$want" ] && { echo "  staged $(basename "$2") ($want bytes)"; return 0; }
    echo "  !! $(basename "$2") truncated on-device ($got != $want) - retry $t/3 (novacom EOF?)"
  done
  echo "  !!! FAILED to stage $(basename "$2") intact - plugins needing it will NOT load"; return 1
}
for L in libopusfile.so.0 libopus.so.0 libogg.so.0; do
  [ -f "$STAGING/lib/$L" ] && put_verify "$STAGING/lib/$L" "$BACKEND_LIB/$L"
done

echo "== 4. drop libwhatsmeow.so into /usr/lib/purple-2 =="
if [ -f "$PRPL" ]; then
  nr "mkdir -p $BACKEND_PURPLE2"
  novacom put "file://$BACKEND_PURPLE2/libwhatsmeow.so" < "$PRPL"
else
  echo "   !! not built — run ./build-whatsapp.sh first (see README.md)"
fi

echo "== 4b. WhatsApp calling: grant com.palm.whatsapp.call in the imlibpurple role =="
# Calling runs IN this plugin (glue/call.c) on the shared messaging session — no separate wacallm
# process. The account manifest (step 2) already points PHONE at com.palm.whatsapp.call. The
# imlibpurpletransport role (com.palm.imlibpurple.json) must ALLOW the plugin to own the
# com.palm.whatsapp.call bus name — same as telegram.call/signal.call. A separate role file does NOT
# work; the name must be in imtransport's own role. The RESIDENT transport registers that name itself,
# so no DBus activation .service is needed for it (see the neuter below).
IMROLES="${IMLIB_REPO:-/home/herrie/Documents/GitHub/imlibpurpleservice}/files/ls2/roles"
nr "mount -o remount,rw /dev/mapper/store-root / || true"
novacom put "file:///usr/share/ls2/roles/prv/com.palm.imlibpurple.json" < "$IMROLES/prv/com.palm.imlibpurple.json"
novacom put "file:///usr/share/ls2/roles/pub/com.palm.imlibpurple.json" < "$IMROLES/pub/com.palm.imlibpurple.json"
nr "rm -f /usr/share/ls2/roles/pub/com.palm.whatsapp.call.json"  # superseded by the imlibpurple role grant
# *** DO NOT NEUTER ANY of these .service files. *** They were neutered earlier this line of work to
# chase a transport "churn", but that was WRONG on two counts and broke real features:
#   - com.palm.imlibpurple.service (MAIN): needed so the activitymanager can CALL sendIM/sendCommand -
#     without it NOTHING sends (msgs + reactions stuck pending); "Service not listed in service files".
#   - com.palm.{whatsapp,telegram,signal}.call.service (VoIP): even though the resident registers
#     com.palm.whatsapp.call IN-PLUGIN, ls-hubd still needs the .service file to know the name for
#     INBOUND routing - without it a caller gets "Service does not exist" and CALLS FAIL.
# The "churn" (a second activated transport colliding on com.palm.imlibpurple) was really a symptom of
# transport CRASHES freeing the bus name; that crash-class is now fixed by the createPurpleAccount
# try/catch (f998f33), so with a stable resident these .service files just route to it (no activation,
# no churn). ENSURE they are present (restore any left .disabled by the old neuter):
nr "for s in com.palm.imlibpurple.service com.palm.whatsapp.call.service com.palm.telegram.call.service com.palm.signal.call.service; do [ -f /usr/share/dbus-1/system-services/\$s.disabled ] && mv /usr/share/dbus-1/system-services/\$s.disabled /usr/share/dbus-1/system-services/\$s && echo \"  restored \$s\"; done; true"
echo "== 4c. retire the standalone wacallm mediator (it owned com.palm.whatsapp) =="
nr "kill \$(pidof wacallm-luna) 2>/dev/null || true"
nr "rm -f /usr/share/dbus-1/system-services/com.palm.whatsapp.service /usr/share/ls2/roles/prv/com.palm.whatsapp.json /usr/share/ls2/roles/pub/com.palm.whatsapp.json"
nr "ls-control scan-services 2>/dev/null || true"
nr "mount -o remount,ro /dev/mapper/store-root / || true"

echo "== 4d. restart imlibpurpletransport so the plugin loads calling + registers com.palm.whatsapp.call =="
# SIGTERM only (never -9: that corrupts the PmLog init semaphore); clear a stale sem before respawn.
nr "kill \$(pidof imlibpurpletransport) 2>/dev/null || true"
sleep 2
nr "rm -f /dev/shm/sem.PmLogLib"

echo "== 5. rescan apps + accounts =="
nr "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
nr "for p in \$(pidof accounts.js 2>/dev/null); do kill \$p; done 2>/dev/null || true"
nr "P=\$(pidof LunaSysMgr); [ -n \"\$P\" ] && kill -9 \$P || true"
echo "== done. Add Account > WhatsApp (phone number); finish by scanning the QR in Messaging =="
