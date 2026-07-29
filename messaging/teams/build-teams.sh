#!/bin/bash
# Rebuild libteams-personal.so (purple-teams, consumer/TFL) for webOS ARMv7 (HP TouchPad).
# Mirrors messaging/discord/build-discord.sh: cross-gcc from the wpe env + purple/glib/json-glib
# pkg-config from the in-monorepo libpurple staging. The upstream Makefile has no ARM target and
# its PURPLE_C_FILES lists libteams.c twice (dup-link), so we invoke the compiler directly with a
# deduped file list. Output libteams-personal.stripped.so is what deploy-teams.sh pushes (renamed
# libteams.so on-device).
set -e
source ~/webos/wpe/env-glibc-gcc125.sh
REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
export PKG_CONFIG_PATH=$REPO/messaging/libpurple/lib/pkgconfig:~/webos/wpe/staging-glibc-252/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH

cd "$REPO/messaging/teams/plugin/purple-teams"

# luna-service2 for the com.palm.teams.call bridge (teams_call_luna.c). Same headers + link
# stub the Telegram calling build uses (messaging/telegram/build-prpl.sh).
LUNAINC=/home/herrie/webos/touchpad-kernel/doctor305/build-deps/luna-service2/include/public
PMLOGINC=/home/herrie/webos/touchpad-kernel/doctor305/build-deps/woce-build-support/staging/arm-none-linux-gnueabi/include/PmLogLib/IncsPublic
LSSTUB=$REPO/build-output/imtransport/lib/liblunaservice.so

FILES="teams_connection.c teams_contacts.c teams_login.c teams_messages.c teams_util.c \
purple-websocket.c teams_trouter.c teams_cards.c markdown.c libteams.c \
teams_calling.c teams_call_luna.c \
purple2compat/http.c purple2compat/purple-socket.c"

rm -f libteams-personal.so libteams-personal.stripped.so
$CC -fPIC -O2 -g -DENABLE_TEAMS_PERSONAL -DTEAMS_WEBOS_CALL -shared -o libteams-personal.so $FILES \
  `pkg-config purple glib-2.0 json-glib-1.0 zlib --libs --cflags` \
  -I"$LUNAINC" -I"$LUNAINC/luna-service2" -I"$PMLOGINC" -Ipurple2compat \
  "$LSSTUB" -g -ggdb

arm-unknown-linux-gnueabi-strip -o libteams-personal.stripped.so libteams-personal.so

echo "=== built ==="
ls -la libteams-personal.stripped.so
arm-unknown-linux-gnueabi-readelf -d libteams-personal.stripped.so | grep NEEDED
echo "purple_init_plugin: $(arm-unknown-linux-gnueabi-nm -D libteams-personal.so | grep -c purple_init_plugin)"
