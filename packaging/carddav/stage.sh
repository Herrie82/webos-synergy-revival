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
NAME=carddav
# shellcheck source=/dev/null
source "$HERE/control.env"
# shellcheck source=/dev/null
source "$REPO/packaging/lib/common.sh"
ROOT="$REPO/carddav"
DEPLOY="$ROOT/deploy"
SVCID=org.webosports.service.cdav
APPID=org.webosports.app.cdav

echo "== carddav: service =="
# usr/palm/services/... is a root-fs path -- stock webOS boots root READ-ONLY, and ipkg extracts
# data.tar.gz itself before postinst ever runs and gets a chance to remount root rw, so this can't
# be staged directly under $STAGE/usr/... anymore (confirmed live: that made the whole extraction
# fail outright). stage_root_dir/stage_root_file stage it on cryptofs instead; postinst copies it
# into place.
mkdir -p "$STAGE/.carddav-svc-src/$SVCID"
cp -r "$ROOT/service/services.json" "$ROOT/service/sources.json" "$ROOT/service/javascript" \
   "$STAGE/.carddav-svc-src/$SVCID/"
cp "$DEPLOY/palm_bus_config.json" "$STAGE/.carddav-svc-src/$SVCID/"
stage_root_dir "$STAGE/.carddav-svc-src/$SVCID" "/$SERVICES_ROOT/$SVCID"
rm -rf "$STAGE/.carddav-svc-src"

echo "== carddav: ls2 roles + dbus activation =="
stage_root_file "$DEPLOY/ls2/pub/$SVCID.json" "/usr/share/ls2/roles/pub/$SVCID.json"
stage_root_file "$DEPLOY/ls2/prv/$SVCID.json" "/usr/share/ls2/roles/prv/$SVCID.json"
stage_root_file "$DEPLOY/dbus/$SVCID.service" "/usr/share/dbus-1/system-services/$SVCID.service"
stage_root_file "$DEPLOY/dbus/$SVCID.service" "/usr/share/dbus-1/services/$SVCID.service"

echo "== carddav: db8 kinds + permissions =="
for f in "$ROOT/service/configuration/db/kinds/"org.webosports.cdav.*; do
  stage_root_file "$f" "/etc/palm/db/kinds/$(basename "$f")"
done
for f in "$ROOT/service/configuration/db/permissions/"org.webosports.cdav.*; do
  stage_root_file "$f" "/etc/palm/db/permissions/$(basename "$f")"
done

echo "== carddav: account templates =="
for d in "$DEPLOY/accounts/"org.webosports.cdav.account*; do
  [ -d "$d" ] || continue
  stage_root_dir "$d" "/$ACCOUNTS_ROOT/$(basename "$d")"
done

if [ -d "$DEPLOY/app/$APPID" ]; then
  echo "== carddav: setup app =="
  # stage_app routes through stage_root_dir (the overwrite_rel() OV mechanism), not written
  # directly under $STAGE/$APP_ROOT - see stage_app's comment in packaging/lib/common.sh for why.
  stage_app "$DEPLOY/app/$APPID" "$APPID"
  APP_STAGED="$STAGE/$(overwrite_rel)/$APP_ROOT/$APPID"
  # Every other stage_app call in this repo (generic/, cloud/, messaging/) is immediately paired
  # with bump_version so the staged app's own appinfo.json can never silently drift from the
  # package version -- this was the one stage_app call in the whole repo missing it (confirmed:
  # currently harmless, deploy/app/org.webosports.app.cdav's committed appinfo.json and this
  # package's control.env both happen to say 0.9.0 today, but nothing enforced that).
  bump_version "$APP_STAGED/appinfo.json"
  # The Google OAuth client_secret is kept out of git (see GoogleSetup.js's GOCSPX_INJECTED_AT_DEPLOY
  # placeholder). Inject it at package-build time the same way deploy-cdav.sh does at deploy time.
  GSECRET="${CDAV_GOOGLE_CLIENT_SECRET:-}"
  if [ -z "$GSECRET" ]; then
    GJSON=$(ls "$HOME"/Downloads/client_secret_*apps.googleusercontent.com.json 2>/dev/null | head -1)
    [ -n "$GJSON" ] && GSECRET=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['web']['client_secret'])" "$GJSON" 2>/dev/null)
  fi
  if [ -n "$GSECRET" ]; then
    sed -i "s/GOCSPX_INJECTED_AT_DEPLOY/$GSECRET/" "$APP_STAGED/source/GoogleSetup.js"
    echo "   injected Google client_secret into setup app"
  else
    echo "   !! no Google client_secret found — Google CardDAV setup will fail until GoogleSetup.js is patched (set CDAV_GOOGLE_CLIENT_SECRET)"
  fi
else
  echo "   (no setup app in deploy/app/$APPID -- skipping)"
fi

# /var is its own small (~60MB), always-writable partition, but that only sidesteps the
# READ-ONLY-ROOT problem -- a direct $STAGE/var/... write is still vulnerable to Preware/WebOS
# Quick Install's offline-root doubling (confirmed live elsewhere in this repo: landed at
# /media/cryptofs/apps/var/... instead of /var/...). Routed through stage_root_file.
stage_root_file "$DEPLOY/provision-cdav-db.sh" "/var/provision-cdav-db.sh"

echo "carddav stage complete: $STAGE"
