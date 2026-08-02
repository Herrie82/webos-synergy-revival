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
stage_service "$SVC_SRC" "$SVC_ID"

if [ -d "$D/apps" ]; then
  for app in "$D/apps"/*/; do
    [ -d "$app" ] || continue
    app_id="$(basename "$app")"
    echo "   + dedicated auth app $app_id"
    stage_app "$app" "$app_id"
    bump_version "$STAGE/$APP_ROOT/$app_id/appinfo.json"
  done
fi

echo "cloud/$NAME stage complete: $STAGE"
