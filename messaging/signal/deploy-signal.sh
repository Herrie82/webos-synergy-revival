#!/bin/bash
# deploy-signal.sh — install the FULL Signal runtime onto the connected TouchPad via novacom.
# Signal is a heavier connector than the others: the prpl embeds a JVM, so besides the plugin
# it deploys a cross-built OpenJDK 11 JRE, the signal-cli 0.8.0 jars, purple_signal.jar and the
# two Rust natives (libsignal_jni / libzkgroup). Run ./assemble-signal.sh first to build the
# bundle in build-output/signal-runtime/ (see build-jvm.sh, build-libsignal.sh, build-signal.sh).
#
# On-device layout:
#   <backend>/jre/                       the ~25 MB headless ARM JRE (purple-signal.so's RPATH
#                                        points here, so libjvm.so resolves at g_module_open)
#   <backend>/signal-cli/lib/*.jar       signal-cli 0.8.0 (ARM libsignal_jni/libzkgroup swapped in)
#   <backend>/lib/purple-2/purple-signal.so + purple_signal.jar + the two natives
#
# The account's signal-cli-lib-dir option (set by the setup app to <backend>/signal-cli/lib)
# tells the prpl where the jars are. Bulk data (JRE + jars ~ 45 MB) is shipped as ONE tarball
# and extracted on-device — far more robust over novacom than thousands of small puts.
#
# This novacom build word-splits `sh -c "cmd"`, so remote commands are piped on stdin via nr().
set -e
PKG="$(cd "$(dirname "$0")" && pwd)"
REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
BUNDLE=$REPO/build-output/signal-runtime
nr() { printf '%s\n' "$1" | novacom run file://bin/sh; }

BACKEND_PURPLE2="${BACKEND_PURPLE2:-/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/lib/purple-2}"
BACKEND="$(dirname "$(dirname "$BACKEND_PURPLE2")")"   # .../backend
[ -d "$BUNDLE/jre" ] || { echo "!! $BUNDLE not assembled — run ./assemble-signal.sh first"; exit 1; }

echo "== 1. push custom setup app com.palm.app.signal =="
APPDIR=/media/cryptofs/apps/usr/palm/applications/com.palm.app.signal
nr "mkdir -p $APPDIR/source $APPDIR/images"
cd "$PKG/apps/com.palm.app.signal"
for f in appinfo.json validator.html depends.js framework_config.json source/validator.js \
         images/header-icon.png images/icon-256x256.png; do
  novacom put "file://$APPDIR/$f" < "$f"
done

echo "== 2. install account template (rootfs rw) =="
ACC=/usr/palm/public/accounts/com.palm.signal
nr "mount -o remount,rw /dev/mapper/store-root / ; mkdir -p $ACC/images"
cd "$PKG/account/com.palm.signal"
novacom put "file://$ACC/com.palm.signal.json" < com.palm.signal.json
for f in images/signal-32x32.png images/signal-48x48.png; do
  novacom put "file://$ACC/$f" < "$f"
done
nr "mount -o remount,ro /dev/mapper/store-root / || true"

echo "== 3. ship JRE + signal-cli jars as one tarball, extract on device =="
TARBALL=/tmp/signal-runtime.tar.gz
tar czf "$TARBALL" -C "$BUNDLE" jre signal-cli
nr "mkdir -p $BACKEND && rm -rf $BACKEND/jre $BACKEND/signal-cli"
novacom put "file:///tmp/signal-runtime.tar.gz" < "$TARBALL"
nr "cd $BACKEND && tar xzf /tmp/signal-runtime.tar.gz && rm -f /tmp/signal-runtime.tar.gz && chmod -R a+rx jre/bin jre/lib && echo extracted:; ls $BACKEND"
rm -f "$TARBALL"

echo "== 4. drop prpl + jar + natives into the live backend plugin dir =="
nr "mkdir -p $BACKEND_PURPLE2"
for f in purple-signal.so purple_signal.jar libsignal_jni.so libzkgroup.so; do
  novacom put "file://$BACKEND_PURPLE2/$f" < "$BUNDLE/prpl/$f"
done

echo "== 5. rescan apps + accounts =="
nr "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
nr "for p in \$(pidof accounts.js 2>/dev/null); do kill \$p; done 2>/dev/null || true"
nr "P=\$(pidof LunaSysMgr); [ -n \"\$P\" ] && kill -9 \$P || true"
echo "== done. Add Account > Signal (phone number). First on-device Signal test still pending — =="
echo "   watch the transport log for JVM start + signal-cli registration (heavy: JVM on 1 GB). =="
