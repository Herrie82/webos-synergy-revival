#!/bin/bash
# stage.sh — templated stager for a cloud connector: account template + service + (if it has one)
# its own dedicated auth app. The shared OAuth webview (com.palm.app.cloud-auth) and _cloudcore
# ship in the generic package, not here.
#
# Usage: stage.sh <connector-name> <stage-dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NAME="$1"; STAGE="$2"
[ -f "$HERE/$NAME/control.env" ] || { echo "!! unknown cloud connector: $NAME" >&2; exit 1; }
# shellcheck source=/dev/null
source "$HERE/$NAME/control.env"
# shellcheck source=/dev/null
source "$REPO/packaging/lib/common.sh"

D="$REPO/cloud/$NAME"
[ -d "$D" ] || { echo "!! unknown cloud connector: $NAME" >&2; exit 1; }

# account/ is either account/com.palm.<id>/ (nested) or account/ itself (flat) — detect which.
ACC_SRC="$D/account"
if [ -d "$D/account" ]; then
  nested=$(find "$D/account" -mindepth 1 -maxdepth 1 -type d -name 'com.palm.*' | head -1)
  [ -n "$nested" ] && ACC_SRC="$nested"
fi
TEMPLATE_ID="$(basename "$ACC_SRC")"
[ "$TEMPLATE_ID" = "account" ] && TEMPLATE_ID=$(basename "$(find "$D/account" -maxdepth 1 -iname '*.json' | head -1)" .json)

SVC_SRC="$(find "$D/service" -mindepth 1 -maxdepth 1 -type d | head -1)"
SVC_ID="$(basename "$SVC_SRC")"

echo "== cloud/$NAME: account ($TEMPLATE_ID) + service ($SVC_ID) =="
stage_account "$ACC_SRC" "$TEMPLATE_ID"
# stage_account now routes through the per-$NAME overwrite dir (cryptofs), not directly under
# $STAGE/$ACCOUNTS_ROOT -- see packaging/lib/common.sh for why (ipkg extracts data.tar.gz before
# postinst can remount root rw, so nothing can be staged at a literal root-fs path anymore).
bump_version "$STAGE/$(overwrite_rel)/$ACCOUNTS_ROOT/$TEMPLATE_ID/$TEMPLATE_ID.json" 2>/dev/null || true

# palm_bus_config.json has to live INSIDE the service's own staged directory (confirmed against a
# real stock jsservicelauncher-based cloud/photo service, com.palm.service.photos.facebook, which
# ships one at exactly /usr/palm/services/<svcid>/palm_bus_config.json) -- copy the source service
# dir to a scratch spot first rather than writing into the tracked source tree directly.
SVC_STAGE="$(mktemp -d)/$SVC_ID"
mkdir -p "$SVC_STAGE"
cp -r "$SVC_SRC/." "$SVC_STAGE/"
printf '{\n\t"busNames": ["%s"],\n\t"privateBusAccess": true\n}' "$SVC_ID" > "$SVC_STAGE/palm_bus_config.json"
stage_service "$SVC_STAGE" "$SVC_ID"
rm -rf "$(dirname "$SVC_STAGE")"

# LS2 role: cloud services communicate over the luna bus (services.json declares "public": true
# commands) -- without a role file granting it, sign-in fails "not permitted". Confirmed live this
# packaging tree was never shipping ANY cloud connector's role at all (not Mega-specific -- every
# one of the 12 was missing it; some may have appeared to work anyway if their very first call
# happened to be reached through an already-permitted caller's session). exeName is "js":
# jsservicelauncher (which runs "engine": "node" services too, despite the name) registers on the
# bus as "js", matching every other jsservicelauncher-based service's role file (confirmed against
# both stock roles and carddav's own org.webosports.service.cdav.json role).
OV_REL="$(overwrite_rel)"
for kind in pub prv; do
  mkdir -p "$STAGE/$OV_REL/usr/share/ls2/roles/$kind"
  printf '{"role": {"allowedNames": ["%s"], "type": "regular", "exeName": "js"}, "permissions": [{"inbound": ["*"], "outbound": ["*"], "service": "%s"}]}' \
    "$SVC_ID" "$SVC_ID" > "$STAGE/$OV_REL/usr/share/ls2/roles/$kind/$SVC_ID.json"
done

# dbus service-activation file: without this, ls-hubd doesn't know how to spawn com.palm.service.<x>
# at all when a client calls it -- confirmed live, this is the exact cause of "Service not listed
# in service files: com.palm.service.mega" reported after installing the LS2-role-only fix. Stock
# only ever ships this under system-services/ for a jsservicelauncher cloud service (confirmed
# against com.palm.service.photos.facebook.service), unlike carddav's own dual pub+system-services
# copy -- one file is enough here.
mkdir -p "$STAGE/$OV_REL/usr/share/dbus-1/system-services"
printf '[D-BUS Service]\nName=%s\nExec=/usr/bin/run-js-service -n /usr/palm/services/%s\n' \
  "$SVC_ID" "$SVC_ID" > "$STAGE/$OV_REL/usr/share/dbus-1/system-services/$SVC_ID.service"

if [ -d "$D/apps" ]; then
  for app in "$D/apps"/*/; do
    [ -d "$app" ] || continue
    app_id="$(basename "$app")"
    echo "   + dedicated auth app $app_id"
    stage_app "$app" "$app_id"
    bump_version "$STAGE/$(overwrite_rel)/$APP_ROOT/$app_id/appinfo.json"
  done
fi

echo "cloud/$NAME stage complete: $STAGE"
