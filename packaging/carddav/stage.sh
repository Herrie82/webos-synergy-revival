#!/bin/bash
# stage.sh — CardDAV/CalDAV connector. Adapts carddav/deploy/deploy-cdav.sh's own staging block
# (same file list) to write into a local stage dir instead of pushing over novacom. Self-contained
# (own service/roles/dbus activation/db kinds) — no dependency on the generic package.
#
# Usage: stage.sh <stage-dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAGE="$1"
ROOT="$REPO/carddav"
DEPLOY="$ROOT/deploy"
SVCID=org.webosports.service.cdav
APPID=org.webosports.app.cdav

P_SVC="$STAGE/usr/palm/services/$SVCID"
P_PUB="$STAGE/usr/share/ls2/roles/pub"
P_PRV="$STAGE/usr/share/ls2/roles/prv"
P_DBUS="$STAGE/usr/share/dbus-1/system-services"
P_DBUS_PUB="$STAGE/usr/share/dbus-1/services"
P_KINDS="$STAGE/etc/palm/db/kinds"
P_PERMS="$STAGE/etc/palm/db/permissions"
P_ACCT="$STAGE/usr/palm/public/accounts"
P_APP="$STAGE/media/cryptofs/apps/usr/palm/applications/$APPID"
mkdir -p "$P_SVC" "$P_PUB" "$P_PRV" "$P_DBUS" "$P_DBUS_PUB" "$P_KINDS" "$P_PERMS" "$P_ACCT"

echo "== carddav: service =="
cp -r "$ROOT/service/services.json" "$ROOT/service/sources.json" "$ROOT/service/javascript" "$P_SVC/"
cp "$DEPLOY/palm_bus_config.json" "$P_SVC/"

echo "== carddav: ls2 roles + dbus activation =="
cp "$DEPLOY/ls2/pub/$SVCID.json" "$P_PUB/"
cp "$DEPLOY/ls2/prv/$SVCID.json" "$P_PRV/"
cp "$DEPLOY/dbus/$SVCID.service" "$P_DBUS/"
cp "$DEPLOY/dbus/$SVCID.service" "$P_DBUS_PUB/"

echo "== carddav: db8 kinds + permissions =="
cp "$ROOT/service/configuration/db/kinds/"org.webosports.cdav.* "$P_KINDS/"
cp "$ROOT/service/configuration/db/permissions/"org.webosports.cdav.* "$P_PERMS/"

echo "== carddav: account templates =="
cp -r "$DEPLOY/accounts/"org.webosports.cdav.account* "$P_ACCT/"

if [ -d "$DEPLOY/app/$APPID" ]; then
  echo "== carddav: setup app =="
  mkdir -p "$P_APP"
  cp -r "$DEPLOY/app/$APPID/." "$P_APP/"
  # The Google OAuth client_secret is kept out of git (see GoogleSetup.js's GOCSPX_INJECTED_AT_DEPLOY
  # placeholder). Inject it at package-build time the same way deploy-cdav.sh does at deploy time.
  GSECRET="${CDAV_GOOGLE_CLIENT_SECRET:-}"
  if [ -z "$GSECRET" ]; then
    GJSON=$(ls "$HOME"/Downloads/client_secret_*apps.googleusercontent.com.json 2>/dev/null | head -1)
    [ -n "$GJSON" ] && GSECRET=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['web']['client_secret'])" "$GJSON" 2>/dev/null)
  fi
  if [ -n "$GSECRET" ]; then
    sed -i "s/GOCSPX_INJECTED_AT_DEPLOY/$GSECRET/" "$P_APP/source/GoogleSetup.js"
    echo "   injected Google client_secret into setup app"
  else
    echo "   !! no Google client_secret found — Google CardDAV setup will fail until GoogleSetup.js is patched (set CDAV_GOOGLE_CLIENT_SECRET)"
  fi
else
  echo "   (no setup app in deploy/app/$APPID -- skipping)"
fi

mkdir -p "$STAGE/var"
cp "$DEPLOY/provision-cdav-db.sh" "$STAGE/var/provision-cdav-db.sh"

echo "carddav stage complete: $STAGE"
