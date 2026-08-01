#!/bin/bash
# deploy-teams.sh — install the Microsoft Teams Synergy surface onto the connected TouchPad via
# novacom. Mirrors deploy-whatsapp.sh. Three artifacts:
#   1. account template -> /usr/palm/public/accounts/com.palm.teams
#   2. setup app        -> /media/cryptofs/apps/usr/palm/applications/org.webosports.app.teams
#   3. the prpl plugin  -> the real /usr/lib/purple-2 (libpurple's own compiled-in plugin dir)
#
# org.webosports.app.teams (renamed from com.palm.app.teams) is now a PLAIN setup app like every
# other messaging connector's — it used to also double as the shared libpurple-engine host
# (backend/lib/purple-2), which never actually belonged to Teams; that engine now lives at the
# real /usr/lib, installed by the generic package (see packaging/README.md "why /usr/lib now").
set -e
PKG="$(cd "$(dirname "$0")" && pwd)"
# NOTE: this novacom build word-splits `sh -c "cmd"`, so run remote shell commands by piping the
# (already-expanded) command string on stdin instead of via -c (same as deploy-whatsapp.sh).
nr() { printf '%s\n' "$1" | novacom run file://bin/sh; }
BACKEND_PURPLE2="${BACKEND_PURPLE2:-/usr/lib/purple-2}"
PRPL="$PKG/plugin/purple-teams/libteams-personal.stripped.so"
APPID=org.webosports.app.teams

echo "== 1. install account template (rootfs rw) =="
ACC=/usr/palm/public/accounts/com.palm.teams
nr "mount -o remount,rw /dev/mapper/store-root / ; mkdir -p $ACC/images"
cd "$PKG/account/com.palm.teams"
novacom put "file://$ACC/com.palm.teams.json" < com.palm.teams.json
for f in images/teams-32x32.png images/teams-48x48.png; do
  novacom put "file://$ACC/$f" < "$f"
done
nr "mount -o remount,ro /dev/mapper/store-root / || true"

echo "== 2. install Teams setup app ($APPID) =="
APP=/media/cryptofs/apps/usr/palm/applications/$APPID
nr "mkdir -p $APP/source $APP/images"
cd "$PKG/apps/$APPID"
for f in appinfo.json validator.html oauth.html depends.js framework_config.json source/validator.js \
         images/header-icon.png images/icon-256x256.png; do
  [ -f "$f" ] && novacom put "file://$APP/$f" < "$f"
done

echo "== 3. drop the Teams prpl into /usr/lib/purple-2 (rootfs rw) =="
if [ -f "$PRPL" ]; then
  nr "mount -o remount,rw /dev/mapper/store-root / ; mkdir -p $BACKEND_PURPLE2"
  novacom put "file://$BACKEND_PURPLE2/libteams.so" < "$PRPL"
  nr "mount -o remount,ro /dev/mapper/store-root / || true"
else
  echo "   !! $PRPL not built yet — skipping prpl (see plugin/purple-teams/README.md)"
fi

echo "== 4. rescan apps + accounts =="
nr "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
nr "for p in \$(pidof accounts.js 2>/dev/null); do kill \$p; done 2>/dev/null || true"
echo "== done. Add Account > Teams to finish setup. =="
