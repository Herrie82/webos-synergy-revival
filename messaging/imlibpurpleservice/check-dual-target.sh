#!/bin/bash
# Verify the transport still compiles against BOTH webOS stacks.
#
# This repo has to serve two very different targets:
#
#   legacy   webOS 3.0.5 -- the initial openwebos db8 and luna-service2 3.9.5, 32-bit ARM.
#            Built by build.sh with -DIMLIBPURPLE_LEGACY_DB8.
#   LuneOS   db8 3.2.0 and luna-service2 3.21.2, 64-bit. Built by its own recipe from
#            CMakeLists.txt, where IMLIBPURPLE_LEGACY_DB8 defaults to OFF.
#
# Both flag states are checked against both header sets -- four combinations. The shipping
# configurations are only two of those, but a branch that compiles in just one configuration is
# exactly how dual-target support rots: nobody notices until the other target is next built.
#
# Compile-only (-fsyntax-only): this answers "does the source still build against both APIs",
# which is the property that breaks. Linking is covered by build.sh (legacy ARM) and
# build-host-asan.sh (legacy host); a full link against the LuneOS stack additionally needs its
# ICU and uriparser, since its libmojodb is built against ICU 74 while a modern host has 78.
set -u

IMLIB_REPO=${IMLIB_REPO:-/home/herrie/Documents/GitHub/imlibpurpleservice}
DEPS=${DEPS:-/home/herrie/webos/touchpad-kernel/doctor305/build-deps}
LUNEOS=${LUNEOS:-/media/herrie/LuneOS/scarthgap/webos-ports}
LUNE_SYSROOT=$LUNEOS/tmp-glibc/sysroots-components/corei7-64
HOST_STAGING=${HOST_STAGING:-$(dirname "$0")/../../build-output/host-asan/staging}
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

COMMON="-I$IMLIB_REPO/inc -I$IMLIB_REPO/test/fuzz/compat -I$HOST_STAGING/include"
COMMON="$COMMON $(pkg-config --cflags glib-2.0 gio-2.0 gio-unix-2.0 purple opus ogg 2>/dev/null)"

LEGACY_INC="-I$DEPS/db8-openwebos-initial/inc
            -I$DEPS/luna-service2/include/public
            -I$DEPS/luna-service2/include/public/luna-service2
            -I$DEPS/woce-build-support/staging/arm-none-linux-gnueabi/include/PmLogLib/IncsPublic"
MODERN_INC="-I$LUNE_SYSROOT/db8/usr/include/mojodb
            -I$LUNE_SYSROOT/luna-service2/usr/include
            -I$LUNE_SYSROOT/luna-service2/usr/include/luna-service2
            -I$LUNE_SYSROOT/pmloglib/usr/include
            -I$LUNE_SYSROOT/libpbnjson/usr/include"

[ -d "$DEPS/db8-openwebos-initial/inc" ] || { echo "!! legacy db8 headers not at $DEPS"; exit 1; }
[ -d "$LUNE_SYSROOT/db8" ] || { echo "!! LuneOS sysroot not at $LUNE_SYSROOT (set LUNEOS=)"; exit 1; }

RC=0
check() {  # check <label> <includes> <extra-defines>
  local label=$1 inc=$2 defs=$3 fails="" n=0
  for f in "$IMLIB_REPO"/src/*.cpp; do
    n=$((n + 1))
    # shellcheck disable=SC2086
    g++ -std=c++17 -fno-rtti -fpermissive -DMOJ_LINUX $defs -fsyntax-only \
        $COMMON $inc "$f" 2>> "$TMP/$label.log" || fails="$fails $(basename "$f" .cpp)"
  done
  if [ -z "$fails" ]; then
    printf "  %-34s %2d/%2d ok\n" "$label" "$n" "$n"
  else
    printf "  %-34s FAILED:%s\n" "$label" "$fails"; RC=1
    grep "error:" "$TMP/$label.log" | sed 's/^/      /' | sort -u | head -5
  fi
}

echo "legacy stack (db8-openwebos-initial + luna-service2 3.9.5)"
check "legacy, LEGACY_DB8=on  [ships]" "$LEGACY_INC" "-DIMLIBPURPLE_LEGACY_DB8"
check "legacy, LEGACY_DB8=off"         "$LEGACY_INC" ""

echo "LuneOS stack (db8 3.2.0 + luna-service2 3.21.2)"
check "LuneOS, LEGACY_DB8=off [ships]" "$MODERN_INC" ""
check "LuneOS, LEGACY_DB8=on"          "$MODERN_INC" "-DIMLIBPURPLE_LEGACY_DB8"

echo
[ $RC -eq 0 ] && echo "both targets compile" || echo "!! dual-target build is broken"
exit $RC
