#!/bin/bash
# stage.sh — per-connector stager for a messaging (libpurple) connector: account template +
# setup-app front + its prpl plugin dropped into the real /usr/lib/purple-2 (libpurple's own
# compiled-in plugin search path — owned by the generic package, this only ADDS a new filename
# there, never touches what's already present) + any runtime .so deps unique to that plugin into
# the private /usr/lib/synergy-runtime dir. WPE-staged runtime .so deps (opus/ogg/opusfile,
# libgcrypt/libpng/libwebp) are the same ARM builds every existing deploy-*.sh script already
# sources from /home/herrie/webos/wpe/staging-glibc-252/lib — bundled here so the .ipk is
# self-contained.
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
    # org.webosports.app.teams (renamed from com.palm.app.teams for vendor-namespace consistency)
    # is now a plain setup app like every other connector's — the shared libpurple engine used to
    # be (wrongly) nested inside its app dir; it now lives at the real /usr/lib, owned by the
    # generic package (see packaging/README.md "why /usr/lib now").
    stage_account "$M/teams/account/com.palm.teams" com.palm.teams
    stage_app "$M/teams/apps/org.webosports.app.teams" org.webosports.app.teams
    bump_version "$STAGE/$APP_ROOT/org.webosports.app.teams/appinfo.json"
    stage_backend_plugin_as "$M/teams/plugin/purple-teams/libteams-personal.stripped.so" libteams.so
    # Calling (inbound routing): ls-hubd needs this .service on file even though the RESIDENT
    # transport registers com.palm.teams.call itself in-plugin -- without it, "Service does not
    # exist" and inbound calls fail. New name (stock never had Teams calling), no backup needed.
    mkdir -p "$STAGE/usr/share/dbus-1/system-services"
    cp "$M/teams/calling/dbus-1/system-services/com.palm.teams.call.service" \
       "$STAGE/usr/share/dbus-1/system-services/"
    ;;

  telegram)
    stage_account "$M/telegram/account/com.palm.telegram" com.palm.telegram
    stage_app "$M/telegram/apps/com.palm.app.telegram" com.palm.app.telegram
    bump_version "$STAGE/$APP_ROOT/com.palm.app.telegram/appinfo.json"
    # readelf -d confirms libtelegram-tdlib.stripped.so's only third-party NEEDED is libopus.so.0
    # (voice notes) -- libcrypto/libssl/liblunaservice/libasound/libpalmgstskype are either handled
    # by imwrap.sh (sslfix/preload) or expected already on stock. The libgcrypt/libpng16/libwebp/
    # libsharpyuv set once staged here was for the RETIRED tgl-based telegram-purple (per the old
    # deploy-telegram.sh comment, itself stale) -- tdlib-purple doesn't link any of them.
    stage_backend_plugin_as "$M/telegram/plugin/tdlib-purple/build-arm/libtelegram-tdlib.stripped.so" \
      libtelegram-tdlib.so \
      $(wpe_lib libopus.so.0)
    # Calling (inbound routing) -- see the teams case above for why this file is needed.
    mkdir -p "$STAGE/usr/share/dbus-1/system-services"
    cp "$M/telegram/calling/dbus-1/system-services/com.palm.telegram.call.service" \
       "$STAGE/usr/share/dbus-1/system-services/"
    ;;

  signal)
    stage_account "$M/signal/account/com.palm.signal" com.palm.signal
    stage_app "$M/signal/apps/com.palm.app.signal" com.palm.app.signal
    bump_version "$STAGE/$APP_ROOT/com.palm.app.signal/appinfo.json"
    stage_backend_plugin_as "$M/signal/plugin/purple-presage/build-arm/libpresage.stripped.so" libpresage.so
    # Calling (inbound routing) -- see the teams case above for why this file is needed.
    mkdir -p "$STAGE/usr/share/dbus-1/system-services"
    cp "$M/signal/calling/dbus-1/system-services/com.palm.signal.call.service" \
       "$STAGE/usr/share/dbus-1/system-services/"
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
    # Calling (inbound routing) -- see the teams case above for why this file is needed. WhatsApp's
    # own ROLE grant lives in imlibpurple's role (generic package), not a separate role file here
    # (deploy-whatsapp.sh: "a separate role file does NOT work") -- only the .service differs.
    mkdir -p "$STAGE/usr/share/dbus-1/system-services"
    cp "$M/whatsapp/calling/dbus-1/system-services/com.palm.whatsapp.call.service" \
       "$STAGE/usr/share/dbus-1/system-services/"
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
    # libprotobuf-c drops in the private synergy-runtime dir (not purple-2/), matching BUILD-LOG.md.
    # MUST keep the .so.1 suffix -- readelf -d confirms libgooglechat.so's NEEDED entry is the exact
    # SONAME "libprotobuf-c.so.1", not "libprotobuf-c.so" (the dynamic linker matches NEEDED entries
    # by exact string, so the wrong filename here would silently fail dlopen at plugin load).
    mkdir -p "$STAGE/$BACKEND_LIB"
    cp "$M/googlechat/plugin/purple-googlechat/build-arm/libprotobuf-c.stripped.so" \
       "$STAGE/$BACKEND_LIB/libprotobuf-c.so.1"
    ;;

  *)
    echo "!! unknown messaging connector: $NAME" >&2; exit 1 ;;
esac

echo "messaging/$NAME stage complete: $STAGE"
