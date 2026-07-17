#!/bin/bash
# deploy-signal.sh — install the Signal Synergy *surface* (account template + setup
# app) onto the connected TouchPad via novacom. Mirrors deploy-telegram.sh.
#
# ============================================================================
#  !!  SIGNAL IS NOT FUNCTIONAL ON THIS DEVICE  !!
#  This installs only the account template + customUI app so the entry appears
#  under Settings > Accounts. There is NO working prpl to deploy: purple-signal
#  needs an embedded JVM + an ARMv7 Rust libsignal, neither of which exists for
#  webOS ARMv7 (see BUILD-LOG.md). Sign-in will NOT succeed. By default this
#  script SKIPS pushing purple-signal.so. Set DEPLOY_PRPL=1 to push the (non-
#  loadable) .so anyway for experimentation.
# ============================================================================
set -e
PKG="$(cd "$(dirname "$0")" && pwd)"
NR="novacom run file://bin/sh"
BACKEND_PURPLE2="${BACKEND_PURPLE2:-/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/lib/purple-2}"
PRPL="$PKG/plugin/purple-signal/build-arm/purple-signal.so"

echo "== 1. push custom setup app com.palm.app.signal =="
APPDIR=/media/cryptofs/apps/usr/palm/applications/com.palm.app.signal
$NR -- -c "mkdir -p $APPDIR/source $APPDIR/images"
cd "$PKG/apps/com.palm.app.signal"
for f in appinfo.json validator.html depends.js framework_config.json source/validator.js \
         images/header-icon.png images/icon-256x256.png; do
  novacom put "file://$APPDIR/$f" < "$f"
done

echo "== 2. install account template (rootfs rw) =="
ACC=/usr/palm/public/accounts/com.palm.signal
$NR -- -c "mount -o remount,rw / ; mkdir -p $ACC/images"
cd "$PKG/account/com.palm.signal"
novacom put "file://$ACC/com.palm.signal.json" < com.palm.signal.json
for f in images/signal-32x32.png images/signal-48x48.png; do
  novacom put "file://$ACC/$f" < "$f"
done
$NR -- -c "mount -o remount,ro / || true"

if [ "${DEPLOY_PRPL:-0}" = "1" ] && [ -f "$PRPL" ]; then
  echo "== 3. (DEPLOY_PRPL=1) drop non-loadable purple-signal.so into backend plugin dir =="
  $NR -- -c "mkdir -p $BACKEND_PURPLE2"
  novacom put "file://$BACKEND_PURPLE2/purple-signal.so" < "$PRPL"
  echo "   (note: this will fail to g_module_open — unresolved JNI_CreateJavaVM, no ARM libjvm)"
else
  echo "== 3. SKIPPED pushing purple-signal.so (no runnable prpl; set DEPLOY_PRPL=1 to force) =="
fi

echo "== 4. rescan apps + accounts =="
$NR -- -c "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
$NR -- -c "for p in \$(pidof accounts.js 2>/dev/null); do kill \$p; done 2>/dev/null || true"
$NR -- -c "P=\$(pidof LunaSysMgr); [ -n \"\$P\" ] && kill -9 \$P || true"
echo "== done. The Signal entry appears in Add Account, but cannot sign in yet (see BUILD-LOG.md). =="
