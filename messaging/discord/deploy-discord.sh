#!/bin/bash
# deploy-discord.sh — install the Discord Synergy surface onto the connected
# TouchPad via novacom. Mirrors teams-port/pkg/deploy-teams-surface.sh but for a
# generic (username/password) libpurple account — no custom setup app.
#
# Two artifacts land on the device:
#   1. the account template  -> /usr/palm/public/accounts/com.palm.discord
#   2. the prpl plugin        -> the LIVE imlibpurple backend's purple-2/ dir
#
# The modern libpurple 2.14 + ssl-openssl backend is ALREADY on the device from
# the teams-port work (see TEAMS-SYNERGY-PORT-PLAN.md); Discord reuses it verbatim.
# Point BACKEND_PURPLE2 at that same on-device plugin dir.
set -e
PKG="$(cd "$(dirname "$0")" && pwd)"
NR="novacom run file://bin/sh"

# on-device plugin dir of the LIVE (modern) imlibpurple backend bundle.
BACKEND_PURPLE2="${BACKEND_PURPLE2:-/media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/lib/purple-2}"
PRPL="$PKG/src/purple-discord/libdiscord.so"

echo "== 1. install account template (rootfs rw) =="
ACC=/usr/palm/public/accounts/com.palm.discord
$NR -- -c "mount -o remount,rw / ; mkdir -p $ACC/images"
cd "$PKG/pkg/usr/palm/public/accounts/com.palm.discord"
novacom put "file://$ACC/com.palm.discord.json" < com.palm.discord.json
for f in images/discord-32x32.png images/discord-48x48.png; do
  novacom put "file://$ACC/$f" < "$f"
done
$NR -- -c "mount -o remount,ro / || true"

echo "== 1b. install Discord customUI setup app (com.palm.app.discord) =="
# The stock 2011 imaccountvalidator rejects templateId com.palm.discord ("Invalid
# templateId"), so the template uses a customUI (like Teams/Telegram) instead of the
# generic checkCredentials. This app collects a username + Discord auth TOKEN and
# stores the token as the account password; patched libdiscord.c uses it as the token.
APP=/media/cryptofs/apps/usr/palm/applications/com.palm.app.discord
$NR -- -c "mkdir -p $APP/source $APP/images"
cd "$PKG/pkg/usr/palm/applications/com.palm.app.discord"
for f in appinfo.json validator.html depends.js framework_config.json source/validator.js \
         images/header-icon.png images/icon-256x256.png; do
  novacom put "file://$APP/$f" < "$f"
done

echo "== 2. drop libdiscord.so into the live backend plugin dir =="
if [ -f "$PRPL" ]; then
  $NR -- -c "mkdir -p $BACKEND_PURPLE2"
  novacom put "file://$BACKEND_PURPLE2/libdiscord.so" < "$PRPL"
else
  echo "   !! $PRPL not built yet — run the build first (see README.md)"
fi

echo "== 3. rescan apps + accounts =="
$NR -- -c "luna-send -n 1 luna://com.palm.applicationManager/rescan '{}' || true"
# re-read templates + re-scan cryptofs apps (kill = respawn); 'restart' not in PATH
$NR -- -c "for p in \$(pidof accounts.js 2>/dev/null) \$(ps | grep -E 'accounts.js|service.accounts' | grep -v grep | awk '{print \$1}'); do kill \$p; done 2>/dev/null || true"
$NR -- -c "P=\$(pidof LunaSysMgr); [ -n \"\$P\" ] && kill -9 \$P || true"
echo "== done. Settings > Accounts > Add > Discord: enter handle + paste Discord web auth token =="
