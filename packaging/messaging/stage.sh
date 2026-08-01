#!/bin/bash
# stage.sh — per-connector stager for a messaging (libpurple) connector: account template +
# setup-app front + its prpl plugin (+ unique runtime deps) dropped into the shared backend's
# purple-2 dir (owned by the generic package — this only ADDS files there, never touches what's
# already present). WPE-staged runtime .so deps (opus/ogg/opusfile, libgcrypt/libpng/libwebp) are
# the same ARM builds every existing deploy-*.sh script already sources from
# /home/herrie/webos/wpe/staging-glibc-252/lib — bundled here so the .ipk is self-contained.
#
# Usage: stage.sh <teams|telegram|signal|discord|whatsapp|facebook|googlechat> <stage-dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NAME="$1"; STAGE="$2"
# shellcheck source=/dev/null
source "$REPO/packaging/lib/common.sh"

WPE="/home/herrie/webos/wpe/staging-glibc-252/lib"
M="$REPO/messaging"

wpe_lib() { [ -f "$WPE/$1" ] && echo "$WPE/$1"; }

case "$NAME" in
  teams)
    stage_account "$M/teams/account/com.palm.teams" com.palm.teams
    stage_app_files "$M/teams/apps/com.palm.app.teams" com.palm.app.teams \
      appinfo.json validator.html oauth.html depends.js framework_config.json \
      source/validator.js images/header-icon.png images/icon-256x256.png
    bump_version "$STAGE/$APP_ROOT/com.palm.app.teams/appinfo.json"
    stage_backend_plugin_as "$M/teams/plugin/purple-teams/libteams-personal.stripped.so" libteams.so
    ;;

  telegram)
    stage_account "$M/telegram/account/com.palm.telegram" com.palm.telegram
    stage_app "$M/telegram/apps/com.palm.app.telegram" com.palm.app.telegram
    bump_version "$STAGE/$APP_ROOT/com.palm.app.telegram/appinfo.json"
    stage_backend_plugin_as "$M/telegram/plugin/tdlib-purple/build-arm/libtelegram-tdlib.stripped.so" \
      libtelegram-tdlib.so \
      $(wpe_lib libgcrypt.so.20) $(wpe_lib libgpg-error.so.0) \
      $(wpe_lib libpng16.so.16) $(wpe_lib libwebp.so.7) $(wpe_lib libsharpyuv.so.0)
    ;;

  signal)
    stage_account "$M/signal/account/com.palm.signal" com.palm.signal
    stage_app "$M/signal/apps/com.palm.app.signal" com.palm.app.signal
    bump_version "$STAGE/$APP_ROOT/com.palm.app.signal/appinfo.json"
    stage_backend_plugin_as "$M/signal/plugin/purple-presage/build-arm/libpresage.stripped.so" libpresage.so
    ;;

  discord)
    stage_account "$M/discord/account/com.palm.discord" com.palm.discord
    stage_app "$M/discord/apps/com.palm.app.discord" com.palm.app.discord
    stage_app "$M/discord/apps/com.palm.app.discordqr" com.palm.app.discordqr
    bump_version "$STAGE/$APP_ROOT/com.palm.app.discord/appinfo.json"
    bump_version "$STAGE/$APP_ROOT/com.palm.app.discordqr/appinfo.json"
    stage_backend_plugin_as "$M/discord/plugin/purple-discord/libdiscord.stripped.so" libdiscord.so
    ;;

  whatsapp)
    stage_account "$M/whatsapp/account/com.palm.whatsapp" com.palm.whatsapp
    stage_app "$M/whatsapp/apps/com.palm.app.whatsapp" com.palm.app.whatsapp
    bump_version "$STAGE/$APP_ROOT/com.palm.app.whatsapp/appinfo.json"
    stage_backend_plugin_as "$M/facebook-e2ee/plugin/purple-combined/build-arm/libwhatsmeow.stripped.so" \
      libwhatsmeow.so \
      $(wpe_lib libopusfile.so.0) $(wpe_lib libopus.so.0) $(wpe_lib libogg.so.0)
    ;;

  facebook)
    stage_account "$M/facebook-e2ee/account/com.palm.gometa" com.palm.gometa
    stage_app "$M/facebook-e2ee/apps/com.palm.app.gometa" com.palm.app.gometa
    bump_version "$STAGE/$APP_ROOT/com.palm.app.gometa/appinfo.json"
    # Same combined plugin as WhatsApp (messagix + whatsmeow in one Go runtime) — packaged
    # independently per-connector (small duplication; simplest, matches "one IPK per connector").
    stage_backend_plugin_as "$M/facebook-e2ee/plugin/purple-combined/build-arm/libwhatsmeow.stripped.so" \
      libwhatsmeow.so \
      $(wpe_lib libopusfile.so.0) $(wpe_lib libopus.so.0) $(wpe_lib libogg.so.0)
    ;;

  googlechat)
    stage_account "$M/googlechat/account/com.palm.googlechat" com.palm.googlechat
    stage_app "$M/googlechat/apps/com.palm.app.googlechat" com.palm.app.googlechat
    bump_version "$STAGE/$APP_ROOT/com.palm.app.googlechat/appinfo.json"
    stage_backend_plugin_as "$M/googlechat/plugin/purple-googlechat/build-arm/libgooglechat.stripped.so" \
      libgooglechat.so
    # libprotobuf-c drops in backend/lib/ (not purple-2/) alongside the engine, matching BUILD-LOG.md.
    mkdir -p "$STAGE/$BACKEND_LIB"
    cp "$M/googlechat/plugin/purple-googlechat/build-arm/libprotobuf-c.stripped.so" \
       "$STAGE/$BACKEND_LIB/libprotobuf-c.so"
    ;;

  *)
    echo "!! unknown messaging connector: $NAME" >&2; exit 1 ;;
esac

echo "messaging/$NAME stage complete: $STAGE"
