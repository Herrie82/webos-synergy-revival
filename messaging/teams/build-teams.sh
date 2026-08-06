#!/bin/bash
# Rebuild libteams-personal.so (purple-teams, consumer/TFL) for webOS ARMv7 (HP TouchPad).
# Mirrors messaging/discord/build-discord.sh: cross-gcc from the wpe env + purple/glib/json-glib
# pkg-config from the in-monorepo libpurple staging. The upstream Makefile has no ARM target and
# its PURPLE_C_FILES lists libteams.c twice (dup-link), so we invoke the compiler directly with a
# deduped file list. Output libteams-personal.stripped.so is what deploy-teams.sh pushes (renamed
# libteams.so on-device).
#
# H.264 video bridge: skypekit.cpp/h264_rtp.c/teams_video_relay.cpp link directly against the
# real, headerless libpalmgstskype.so (SkypeKit's native RTP transport) using the asm-mangled-
# symbol trick proven in messaging/whatsapp/calling/skypekit_send_test.cpp, exactly as
# messaging/facebook-e2ee/plugin/purple-combined/build-combined.sh does for WhatsApp. This process
# (imlibpurpletransport, which dlopens this .so) already runs under the wpe-glibc loader with the
# LD_LIBRARY_PATH imwrap.sh needs to resolve libpalmgstskype.so's transitive libmedia-clonk/
# libpbnjson_cpp/liblunaservice chain — unlike teams_media (a separate subprocess with a stock ELF
# interpreter, which is why that engine only relays raw RTP bytes here instead of linking this
# chain itself; see teams_media.c's top-of-file comment).
set -e
source ~/webos/wpe/env-glibc-gcc125.sh
REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
export PKG_CONFIG_PATH=$REPO/messaging/libpurple/lib/pkgconfig:~/webos/wpe/staging-glibc-252/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH
: "${CXX:=arm-unknown-linux-gnueabi-g++}"

cd "$REPO/messaging/teams/plugin/purple-teams"

# luna-service2 for the com.palm.teams.call bridge (teams_call_luna.c). Same headers + link
# stub the Telegram calling build uses (messaging/telegram/build-prpl.sh).
LUNAINC=/home/herrie/webos/touchpad-kernel/doctor305/build-deps/luna-service2/include/public
PMLOGINC=/home/herrie/webos/touchpad-kernel/doctor305/build-deps/woce-build-support/staging/arm-none-linux-gnueabi/include/PmLogLib/IncsPublic
LSSTUB=$REPO/build-output/imtransport/lib/liblunaservice.so

# libpalmgstskype.so lives in the firmware rootfs's gstreamer-0.10 plugin dir - same FW_ROOTFS/
# SOLIB_DIR as build-combined.sh and messaging/whatsapp/calling/skypekit_send_test.cpp.
FW_ROOTFS=/home/herrie/Downloads/webosdoctorp305hstnhatt/resources/webOS/nova-cust-image-topaz.rootfs
SOLIB_DIR=$FW_ROOTFS/usr/lib/gstreamer-0.10

FILES="teams_connection.c teams_contacts.c teams_login.c teams_messages.c teams_util.c \
purple-websocket.c teams_trouter.c teams_cards.c markdown.c libteams.c \
teams_calling.c teams_call_luna.c h264_rtp.c \
purple2compat/http.c purple2compat/purple-socket.c"

CFLAGS_COMMON="`pkg-config purple glib-2.0 json-glib-1.0 zlib --cflags` \
  -I$LUNAINC -I$LUNAINC/luna-service2 -I$PMLOGINC -Ipurple2compat"

rm -f libteams-personal.so libteams-personal.stripped.so *.o

# skypekit.cpp: C++ (the asm-mangled SkypeKit symbol bindings need extern "C" from C++) -
# compiled separately with $CXX, same include set as the C sources.
echo "== compiling skypekit.o (C++) =="
$CXX -fPIC -O2 -g -fno-rtti $CFLAGS_COMMON -c skypekit.cpp -o skypekit.o

echo "== compiling C sources =="
$CC -fPIC -O2 -g -DENABLE_TEAMS_PERSONAL -DTEAMS_WEBOS_CALL -c $FILES $CFLAGS_COMMON
# $CC -c with multiple inputs and no -o writes each object next to its source; teams_video_relay
# is C++-flavored glue (uses pthread/cstdint idioms) but has no C++-only syntax needs beyond what
# $CC's C mode rejects, so compile it with $CXX like skypekit.cpp.
echo "== compiling teams_video_relay.o (C++) =="
$CXX -fPIC -O2 -g -fno-rtti $CFLAGS_COMMON -c teams_video_relay.cpp -o teams_video_relay.o

OBJS=$(echo $FILES | tr ' ' '\n' | sed -E 's#(.*/)?([^/]+)\.c#\2.o#' | tr '\n' ' ')

echo "== linking libteams-personal.so =="
# -Bsymbolic-functions: this plugin and the WhatsApp/FB combined plugin (purple-combined) both
# dlopen into the SAME imlibpurpletransport process, and both define the identically-named
# skypekit_video_start/_receive_frame/_stop/_wait_thread_b bridge symbols (the Teams bridge was
# ported verbatim from WhatsApp's). Neither .so hides these symbols, so without this flag, GModule's
# default global symbol export lets ELF interposition redirect one plugin's calls into the OTHER
# plugin's copy depending on dlopen order -- confirmed live: WhatsApp's calls into its own
# skypekit_video_start were silently not running WhatsApp's code at all. -Bsymbolic-functions makes
# intra-.so calls to these bind to the LOCAL definition first, regardless of what else is loaded.
$CC -fPIC -O2 -g -shared -Wl,-Bsymbolic-functions -o libteams-personal.so \
  $OBJS skypekit.o teams_video_relay.o \
  `pkg-config purple glib-2.0 json-glib-1.0 zlib --libs` \
  "$LSSTUB" \
  -L"$SOLIB_DIR" -lpalmgstskype -Wl,--allow-shlib-undefined \
  -Wl,-rpath-link,"$FW_ROOTFS/usr/lib" -Wl,-rpath,/usr/lib/gstreamer-0.10 \
  -lstdc++ -lpthread -g -ggdb

arm-unknown-linux-gnueabi-strip -o libteams-personal.stripped.so libteams-personal.so

echo "=== built ==="
ls -la libteams-personal.stripped.so
arm-unknown-linux-gnueabi-readelf -d libteams-personal.stripped.so | grep NEEDED
echo "purple_init_plugin: $(arm-unknown-linux-gnueabi-nm -D libteams-personal.so | grep -c purple_init_plugin)"
