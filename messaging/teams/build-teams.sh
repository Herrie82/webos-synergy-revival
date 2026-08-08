#!/bin/bash
# Rebuild libteams-personal.so (purple-teams, consumer/TFL) for webOS ARMv7 (HP TouchPad).
# Mirrors messaging/discord/build-discord.sh: cross-gcc from the wpe env + purple/glib/json-glib
# pkg-config from the in-monorepo libpurple staging. The upstream Makefile has no ARM target and
# its PURPLE_C_FILES lists libteams.c twice (dup-link), so we invoke the compiler directly with a
# deduped file list. Output libteams-personal.stripped.so is what deploy-teams.sh pushes (renamed
# libteams.so on-device).
#
# H.264 video bridge: voipkit.cpp/h264_rtp.c/teams_video_relay.cpp link directly against the
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

# libpalmgstskype.so (SkypeKit's native RTP transport) lives in the firmware rootfs's
# gstreamer-0.10 plugin dir. It is LEGACY-ONLY: gstreamer-0.10 and this library do not exist on
# LuneOS, so TEAMS_VOIPKIT=0 builds the plugin without the video bridge (see teams_calling.c).
#
# Resolved from a candidate list rather than one hardcoded path -- the doctor extraction under
# ~/Downloads this used to point at is long gone. topaz first: that is the TouchPad, and the
# mantaray build of this library is a different binary.
FW_ROOTFS=${FW_ROOTFS:-}
if [ -z "$FW_ROOTFS" ]; then
  for c in /home/herrie/webos/305att/nova-cust-image-topaz.rootfs-att \
           /home/herrie/webos/224/nova-cust-image-mantaray.rootfs \
           /home/herrie/Downloads/webosdoctorp305hstnhatt/resources/webOS/nova-cust-image-topaz.rootfs; do
    [ -f "$c/usr/lib/gstreamer-0.10/libpalmgstskype.so" ] && { FW_ROOTFS=$c; break; }
  done
fi
SOLIB_DIR=$FW_ROOTFS/usr/lib/gstreamer-0.10

TEAMS_VOIPKIT=${TEAMS_VOIPKIT:-1}
if [ "$TEAMS_VOIPKIT" = "1" ]; then
  if [ ! -f "$SOLIB_DIR/libpalmgstskype.so" ]; then
    echo "!! libpalmgstskype.so not found (looked under the candidate rootfs list)."
    echo "   Set FW_ROOTFS=/path/to/rootfs, or TEAMS_VOIPKIT=0 to build without the video bridge."
    exit 1
  fi
  # rpath-link resolves libpalmgstskype's own transitive chain (libmedia-clonk, libpbnjson_cpp,
  # liblunaservice) out of the same firmware rootfs at link time; rpath points the loader at the
  # device's plugin dir at runtime.
  VOIPKIT_LDFLAGS="-L$SOLIB_DIR -lpalmgstskype
                    -Wl,-rpath-link,$FW_ROOTFS/usr/lib -Wl,-rpath,/usr/lib/gstreamer-0.10"
else
  VOIPKIT_LDFLAGS=""
fi

FILES="teams_connection.c teams_contacts.c teams_login.c teams_messages.c teams_util.c \
purple-websocket.c teams_trouter.c teams_cards.c markdown.c libteams.c \
teams_calling.c teams_call_luna.c h264_rtp.c \
purple2compat/http.c purple2compat/purple-socket.c"

CFLAGS_COMMON="`pkg-config purple glib-2.0 json-glib-1.0 zlib --cflags` \
  -I$LUNAINC -I$LUNAINC/luna-service2 -I$PMLOGINC -Ipurple2compat -I$REPO/messaging/common"

rm -f libteams-personal.so libteams-personal.stripped.so *.o

# voipkit.cpp: C++ (the asm-mangled SkypeKit symbol bindings need extern "C" from C++) -
# compiled separately with $CXX, same include set as the C sources. With TEAMS_VOIPKIT=0 the
# whole video bridge is swapped for voipkit_none.c (the null backend), so the plugin links
# without libpalmgstskype
# on targets that do not have it (LuneOS). Voice calling and messaging are unaffected.
if [ "$TEAMS_VOIPKIT" = "1" ]; then
  echo "== compiling voipkit.o (C++) =="
  $CXX -fPIC -O2 -g -fno-rtti $CFLAGS_COMMON -c voipkit.cpp -o voipkit.o
else
  echo "== compiling voipkit_none.o (no libpalmgstskype: video bridge disabled) =="
  $CC -fPIC -O2 -g $CFLAGS_COMMON -c voipkit_none.c -o voipkit.o
fi

echo "== compiling C sources =="
$CC -fPIC -O2 -g -DENABLE_TEAMS_PERSONAL -DTEAMS_WEBOS_CALL -c $FILES $CFLAGS_COMMON
# $CC -c with multiple inputs and no -o writes each object next to its source; teams_video_relay
# is C++-flavored glue (uses pthread/cstdint idioms) but has no C++-only syntax needs beyond what
# $CC's C mode rejects, so compile it with $CXX like voipkit.cpp.
echo "== compiling teams_video_relay.o (C++) =="
$CXX -fPIC -O2 -g -fno-rtti $CFLAGS_COMMON -c teams_video_relay.cpp -o teams_video_relay.o

OBJS=$(echo $FILES | tr ' ' '\n' | sed -E 's#(.*/)?([^/]+)\.c#\2.o#' | tr '\n' ' ')

echo "== linking libteams-personal.so =="
# -Bsymbolic-functions: this plugin and the WhatsApp/FB combined plugin (purple-combined) both
# dlopen into the SAME imlibpurpletransport process, and both define the identically-named
# voipkit_video_start/_receive_frame/_stop/_wait_thread_b bridge symbols (the Teams bridge was
# ported verbatim from WhatsApp's). Neither .so hides these symbols, so without this flag, GModule's
# default global symbol export lets ELF interposition redirect one plugin's calls into the OTHER
# plugin's copy depending on dlopen order -- confirmed live: WhatsApp's calls into its own
# voipkit_video_start were silently not running WhatsApp's code at all. -Bsymbolic-functions makes
# intra-.so calls to these bind to the LOCAL definition first, regardless of what else is loaded.
$CC -fPIC -O2 -g -shared -Wl,-Bsymbolic-functions -o libteams-personal.so \
  $OBJS voipkit.o teams_video_relay.o \
  `pkg-config purple glib-2.0 json-glib-1.0 zlib --libs` \
  "$LSSTUB" \
  $VOIPKIT_LDFLAGS -Wl,--allow-shlib-undefined \
  -lstdc++ -lpthread -g -ggdb

arm-unknown-linux-gnueabi-strip -o libteams-personal.stripped.so libteams-personal.so

echo "=== built ==="
ls -la libteams-personal.stripped.so
arm-unknown-linux-gnueabi-readelf -d libteams-personal.stripped.so | grep NEEDED
echo "purple_init_plugin: $(arm-unknown-linux-gnueabi-nm -D libteams-personal.so | grep -c purple_init_plugin)"
