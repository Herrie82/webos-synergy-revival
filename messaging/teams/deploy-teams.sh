#!/bin/bash
# deploy-teams.sh — install the Microsoft Teams Synergy surface onto the connected TouchPad via
# novacom. Mirrors deploy-whatsapp.sh. Three artifacts:
#   1. account template -> /usr/palm/public/accounts/com.palm.teams
#   2. setup app        -> /media/cryptofs/apps/usr/palm/applications/com.palm.app.teams  (FLAT!)
#   3. the prpl plugin  -> the LIVE imlibpurple backend's purple-2/ dir
#
# IMPORTANT: com.palm.app.teams is ALSO the backend-runtime host — its dir contains backend/lib/purple-2
# where EVERY messaging prpl lives. The setup-app files (appinfo.json, validator, ...) must land
# ALONGSIDE backend/ at the app ROOT. A previous mis-deploy put them in a NESTED
# com.palm.app.teams/com.palm.app.teams/ subdir, so the app had no top-level appinfo.json and "didn't
# load". This script pushes each file to $APP/<file> (flat) and removes any stale nested copy.
set -e
PKG="$(cd "$(dirname "$0")" && pwd)"
# NOTE: this novacom build word-splits `sh -c "cmd"`, so run remote shell commands by piping the
# (already-expanded) command string on stdin instead of via -c (same as deploy-whatsapp.sh).
nr() { printf '%s\n' "$1" | novacom run file://bin/sh; }
BACKEND_PURPLE2="${BACKEND_PURPLE2:-/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/lib/purple-2}"
PRPL="$PKG/plugin/purple-teams/libteams-personal.stripped.so"

echo "== 1. install account template (rootfs rw) =="
ACC=/usr/palm/public/accounts/com.palm.teams
nr "mount -o remount,rw /dev/mapper/store-root / ; mkdir -p $ACC/images"
cd "$PKG/account/com.palm.teams"
novacom put "file://$ACC/com.palm.teams.json" < com.palm.teams.json
for f in images/teams-32x32.png images/teams-48x48.png; do
  novacom put "file://$ACC/$f" < "$f"
done
nr "mount -o remount,ro /dev/mapper/store-root / || true"

echo "== 2. install Teams setup app (com.palm.app.teams) — FLAT at the app root =="
APP=/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams
# clean up a previous mis-deploy that nested the app one level too deep, then (re)create the subdirs
nr "rm -rf $APP/com.palm.app.teams ; mkdir -p $APP/source $APP/images"
cd "$PKG/apps/com.palm.app.teams"
for f in appinfo.json validator.html oauth.html depends.js framework_config.json source/validator.js \
         images/header-icon.png images/icon-256x256.png; do
  [ -f "$f" ] && novacom put "file://$APP/$f" < "$f"
done

echo "== 3. drop the Teams prpl into the live backend plugin dir =="
if [ -f "$PRPL" ]; then
  nr "mkdir -p $BACKEND_PURPLE2"
  novacom put "file://$BACKEND_PURPLE2/libteams.so" < "$PRPL"
else
  echo "   !! $PRPL not built yet — skipping prpl (see plugin/purple-teams/README.md)"
fi

echo "== 4. rescan apps + accounts =="
nr "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
nr "for p in \$(pidof accounts.js 2>/dev/null); do kill \$p; done 2>/dev/null || true"
echo "== done. Add Account > Teams to finish setup. =="
