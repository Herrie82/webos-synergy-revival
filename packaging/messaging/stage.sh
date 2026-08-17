#!/bin/bash
# stage.sh — per-connector stager for a messaging (libpurple) connector: account template +
# setup-app front + its prpl plugin dropped into the real /usr/lib/purple-2 (libpurple's own
# compiled-in plugin search path — owned by the generic package, this only ADDS a new filename
# there, never touches what's already present) + any runtime .so dep that's UNIQUE to that one
# connector (verified with `readelf -d` against every plugin .so + the transport binary -- see
# git history for the full table). Anything needed by 2+ packages (libopus/libogg/libtidy -- all
# three actually NEEDED by the transport binary itself, so truly universal regardless of which
# connectors are installed; libopusfile -- shared by WhatsApp+Facebook) is staged ONCE by generic
# instead (packaging/generic/stage.sh), not duplicated here -- every connector already hard-depends
# on generic being installed, so there's nothing to gain from a defensive per-connector copy, and
# ipkg would treat two packages shipping the same tracked filename as a hard conflict anyway
# (confirmed live installing telegram then whatsapp when both carried their own libopus.so.0).
#
# Usage: stage.sh <teams|telegram|signal|discord|whatsapp|facebook|googlechat> <stage-dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NAME="$1"; STAGE="$2"
[ -f "$HERE/$NAME/control.env" ] || { echo "!! unknown messaging connector: $NAME" >&2; exit 1; }
# shellcheck source=/dev/null
source "$HERE/$NAME/control.env"
# shellcheck source=/dev/null
source "$REPO/packaging/lib/common.sh"

M="$REPO/messaging"
GXX_SYSROOT="/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125/arm-unknown-linux-gnueabi/sysroot/lib"

case "$NAME" in
  teams)
    # com.palm.app.teams -- was briefly renamed to org.webosports.app.teams for vendor-namespace
    # consistency, then reverted (commit f963964, "Teams: Rename back to com.palm.app.teams"; this
    # stage.sh reference was left stale pointing at the reverted name, confirmed live as a build
    # failure -- "stage_root_dir: .../org.webosports.app.teams missing"). Plain setup app like
    # every other connector's — the shared libpurple engine used to be (wrongly) nested inside its
    # app dir; it now lives at the real /usr/lib, owned by the generic package (see
    # packaging/README.md "why /usr/lib now").
    stage_account "$M/teams/account/com.palm.teams" com.palm.teams
    stage_app "$M/teams/apps/com.palm.app.teams" com.palm.app.teams
    bump_version "$STAGE/$(overwrite_rel)/$APP_ROOT/com.palm.app.teams/appinfo.json"
    stage_backend_plugin_as "$M/teams/plugin/purple-teams/libteams-personal.stripped.so" libteams.so
    # Calling (inbound routing): ls-hubd needs this .service on file even though the RESIDENT
    # transport registers com.palm.teams.call itself in-plugin -- without it, "Service does not
    # exist" and inbound calls fail. New name (stock never had Teams calling), no backup needed.
    stage_root_file "$M/teams/calling/dbus-1/system-services/com.palm.teams.call.service" \
      "/usr/share/dbus-1/system-services/com.palm.teams.call.service"
    # Deliberately NOT staging messaging/teams/calling/ls2/roles/pub/com.palm.teams.call.json --
    # confirmed live this actively BREAKS registration rather than fixing anything. LS2 roles are
    # keyed by exeName, and generic's own com.palm.imlibpurple.json role (imlibpurpleservice repo)
    # ALREADY declares one combined role for exeName /usr/bin/imlibpurpletransport that grants
    # com.palm.imlibpurple + teams/telegram/signal/whatsapp.call all together. Staging this
    # standalone per-connector file (same exeName, only one of those names) collides with that
    # combined role instead of extending it -- reported live as "ls-hubd: ... does not have
    # permission to register name: com.palm.signal.call" (and teams/telegram too, same cause).
    # This messaging/teams/calling/ls2/... source file looks like a stale artifact from before the
    # role got consolidated into imlibpurpleservice's own file; leave it in source, don't stage it.
    ;;

  telegram)
    stage_account "$M/telegram/account/com.palm.telegram" com.palm.telegram
    stage_app "$M/telegram/apps/com.palm.app.telegram" com.palm.app.telegram
    bump_version "$STAGE/$(overwrite_rel)/$APP_ROOT/com.palm.app.telegram/appinfo.json"
    # readelf -d confirms libtelegram-tdlib.stripped.so's only third-party NEEDED is libopus.so.0
    # (voice notes) -- generic already provides this (needed by the transport itself too). libcrypto/
    # libssl/liblunaservice/libasound/libpalmgstskype are either handled by imwrap.sh
    # (sslfix/preload) or expected already on stock. The libgcrypt/libpng16/libwebp/libsharpyuv set
    # once staged here was for the RETIRED tgl-based telegram-purple (per the old deploy-telegram.sh
    # comment, itself stale) -- tdlib-purple doesn't link any of them.
    stage_backend_plugin_as "$M/telegram/plugin/tdlib-purple/build-arm/libtelegram-tdlib.stripped.so" \
      libtelegram-tdlib.so
    # Calling (inbound routing) -- see the teams case above for why this file is needed.
    stage_root_file "$M/telegram/calling/dbus-1/system-services/com.palm.telegram.call.service" \
      "/usr/share/dbus-1/system-services/com.palm.telegram.call.service"
    # Deliberately NOT staging the LS2 role -- see the teams case above.
    ;;

  signal)
    stage_account "$M/signal/account/com.palm.signal" com.palm.signal
    stage_app "$M/signal/apps/com.palm.app.signal" com.palm.app.signal
    bump_version "$STAGE/$(overwrite_rel)/$APP_ROOT/com.palm.app.signal/appinfo.json"
    # readelf -d confirms libpresage.stripped.so's only third-party NEEDED beyond the universal set
    # is libutil.so.1 (not needed by any other connector or the transport itself) -- from the same
    # crosstool-ng gcc125 sysroot as libstdc++/libnsl (generic/stage.sh), size-verified against the
    # actual on-device deployed copy.
    stage_backend_plugin_as "$M/signal/plugin/purple-presage/build-arm/libpresage.stripped.so" libpresage.so \
      "$GXX_SYSROOT/libutil.so.1"
    # Calling (inbound routing) -- see the teams case above for why this file is needed.
    stage_root_file "$M/signal/calling/dbus-1/system-services/com.palm.signal.call.service" \
      "/usr/share/dbus-1/system-services/com.palm.signal.call.service"
    # Deliberately NOT staging the LS2 role -- see the teams case above.
    ;;

  discord)
    stage_account "$M/discord/account/com.palm.discord" com.palm.discord
    stage_app "$M/discord/apps/com.palm.app.discord" com.palm.app.discord
    stage_app "$M/discord/apps/com.palm.app.discordqr" com.palm.app.discordqr
    bump_version "$STAGE/$(overwrite_rel)/$APP_ROOT/com.palm.app.discord/appinfo.json"
    bump_version "$STAGE/$(overwrite_rel)/$APP_ROOT/com.palm.app.discordqr/appinfo.json"
    stage_backend_plugin_as "$M/discord/plugin/purple-discord/libdiscord.stripped.so" libdiscord.so
    ;;

  whatsapp)
    stage_account "$M/whatsapp/account/com.palm.whatsapp" com.palm.whatsapp
    stage_app "$M/whatsapp/apps/com.palm.app.whatsapp" com.palm.app.whatsapp
    bump_version "$STAGE/$(overwrite_rel)/$APP_ROOT/com.palm.app.whatsapp/appinfo.json"
    # readelf -d: libwhatsmeow's third-party NEEDED set (libopusfile/libopus/libogg) is entirely
    # generic-provided -- libopusfile is shared with Facebook below, libopus/libogg the transport
    # itself needs regardless.
    stage_backend_plugin_as "$M/facebook-e2ee/plugin/purple-combined/build-arm/libwhatsmeow.stripped.so" \
      libwhatsmeow.so
    # Calling (inbound routing) -- see the teams case above for why this file is needed. WhatsApp's
    # own ROLE grant lives in imlibpurple's role (generic package), not a separate role file here
    # (deploy-whatsapp.sh: "a separate role file does NOT work") -- only the .service differs.
    stage_root_file "$M/whatsapp/calling/dbus-1/system-services/com.palm.whatsapp.call.service" \
      "/usr/share/dbus-1/system-services/com.palm.whatsapp.call.service"
    ;;

  facebook)
    stage_account "$M/facebook-e2ee/account/com.palm.gometa" com.palm.gometa
    stage_app "$M/facebook-e2ee/apps/com.palm.app.gometa" com.palm.app.gometa
    bump_version "$STAGE/$(overwrite_rel)/$APP_ROOT/com.palm.app.gometa/appinfo.json"
    # Same combined plugin as WhatsApp (messagix + whatsmeow in one Go runtime) — packaged
    # independently per-connector (small duplication; simplest, matches "one IPK per connector").
    # Runtime deps (libopusfile/libopus/libogg) generic-provided -- see the WhatsApp case above.
    stage_backend_plugin_as "$M/facebook-e2ee/plugin/purple-combined/build-arm/libwhatsmeow.stripped.so" \
      libwhatsmeow.so
    ;;

  googlechat)
    stage_account "$M/googlechat/account/com.palm.googlechat" com.palm.googlechat
    stage_app "$M/googlechat/apps/com.palm.app.googlechat" com.palm.app.googlechat
    bump_version "$STAGE/$(overwrite_rel)/$APP_ROOT/com.palm.app.googlechat/appinfo.json"
    stage_backend_plugin_as "$M/googlechat/plugin/purple-googlechat/build-arm/libgooglechat.stripped.so" \
      libgooglechat.so
    # libprotobuf-c drops in the private synergy-runtime dir (not purple-2/), matching BUILD-LOG.md.
    # MUST keep the .so.1 suffix -- readelf -d confirms libgooglechat.so's NEEDED entry is the exact
    # SONAME "libprotobuf-c.so.1", not "libprotobuf-c.so" (the dynamic linker matches NEEDED entries
    # by exact string, so the wrong filename here would silently fail dlopen at plugin load). Staged
    # by this package (not via generic): no other connector needs protobuf-c, so no filename
    # conflict risk. Routed through stage_root_file (overwrite_rel() OV mechanism), not written
    # directly under $STAGE/$BACKEND_LIB - same doubling hazard as everywhere else in this repo.
    stage_root_file "$M/googlechat/plugin/purple-googlechat/build-arm/libprotobuf-c.stripped.so" \
      "/$BACKEND_LIB/libprotobuf-c.so.1"
    ;;

  *)
    echo "!! unknown messaging connector: $NAME" >&2; exit 1 ;;
esac

echo "messaging/$NAME stage complete: $STAGE"
