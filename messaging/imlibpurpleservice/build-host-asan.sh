#!/bin/bash
# Build imlibpurpletransport NATIVELY for the build host, instrumented with ASan + UBSan.
#
# WHY THIS EXISTS
# The device build (build.sh) cannot be sanitized: the crosstool-NG ARMv7 toolchain ships no
# libasan/libubsan/liblsan, and valgrind is not built for webOS. Every lifetime bug this
# project has actually shipped -- the Teams image-send double-free, the Discord reconnect
# use-after-free, the whatsmeow dlclose crash -- lives across callback boundaries where static
# analysis cannot see it. Running the same sources natively under ASan is the only way to
# execute them with instrumentation.
#
# The payoff is bigger than it looks: ASan replaces malloc process-wide, so a sanitized
# transport reports heap errors raised inside dlopen'd prpl plugins too, even though those .so
# files are built without instrumentation.
#
# Scope: this builds the transport and its webOS stack. test/fuzz/ in the imlibpurpleservice
# repo covers the leaf text helpers, which need none of this.
#
# STATUS: stages 1-2 (uriparser, yajl) are verified working. Stages 3-7 are written from each
# component's declared dependencies but have NOT been run end to end -- they are blocked on the
# prerequisites below. Expect to iterate on them.
set -e

REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
IMLIB_REPO=${IMLIB_REPO:-/home/herrie/Documents/GitHub/imlibpurpleservice}
AUDIOD=${AUDIOD:-/home/herrie/Documents/GitHub/webos-audiod-port}   # source of the LS2 stack
DEPS=${DEPS:-/home/herrie/webos/touchpad-kernel/doctor305/build-deps}
H=$REPO/build-output/host-asan                                      # gitignored
ST=$H/staging
L=$H/log
mkdir -p "$ST" "$L" "$H/src"

# ---------------------------------------------------------------- prerequisites
# Checked up front, all at once: a half-built staging tree is worse than a clean refusal.
#   gperf/lemon/flex/bison  build-time generators for pbnjson
#   leveldb/icu             db8's storage engine and collation
#   libpurple-dev           the one dependency with no source on disk (messaging/libpurple is
#                           ARM staging -- portable headers, non-portable .so)
# Boost is deliberately absent: pbnjson references it only from the pbnjson_validate CLI tool,
# and that subdir is already commented out in the audiod-port tree, so it is never configured.
MISSING=""
command -v gperf >/dev/null           || MISSING="$MISSING gperf"
command -v lemon >/dev/null           || MISSING="$MISSING lemon"
command -v flex  >/dev/null           || MISSING="$MISSING flex"
command -v bison >/dev/null           || MISSING="$MISSING bison"
pkg-config --exists purple 2>/dev/null || MISSING="$MISSING libpurple-dev"
[ -e /usr/include/leveldb/db.h ]      || MISSING="$MISSING libleveldb-dev"
pkg-config --exists icu-uc 2>/dev/null || MISSING="$MISSING libicu-dev"
if [ -n "$MISSING" ]; then
  echo "!! missing build prerequisites:$MISSING"
  echo "   sudo apt install$MISSING"
  exit 1
fi

export PKG_CONFIG_PATH=$ST/lib/pkgconfig:$ST/share/pkgconfig:$ST/usr/share/pkgconfig:$ST/usr/lib/pkgconfig
# CMAKE_POLICY_VERSION_MINIMUM: these trees predate CMake 4's minimum-version floor.
# CMAKE_MODULE_PATH: cmake-modules-webos installs into the system cmake dir (needs root), so
# point at it in place instead -- `include(webOS/webOS)` resolves from here.
CM="-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_MODULE_PATH=$AUDIOD/cmake-modules-webos
    -DCMAKE_INSTALL_PREFIX=$ST -DCMAKE_PREFIX_PATH=$ST -DCMAKE_BUILD_TYPE=Debug
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON"
SAN="-fsanitize=address,undefined -fno-omit-frame-pointer -g -O1"

stage() {  # stage <name> <src> <marker> [extra cmake args...]
  local n=$1 s=$2 marker=$3; shift 3
  if [ -e "$marker" ]; then printf "== %-12s (cached)\n" "$n"; return 0; fi
  printf "== %-12s " "$n"
  # shellcheck disable=SC2086
  if cmake -S "$s" -B "$H/b-$n" $CM "$@" > "$L/$n.log" 2>&1 \
     && cmake --build "$H/b-$n" -j"$(nproc)" >> "$L/$n.log" 2>&1 \
     && cmake --install "$H/b-$n" >> "$L/$n.log" 2>&1; then echo "ok"
  else echo "FAILED -- see $L/$n.log"; tail -8 "$L/$n.log"; exit 1; fi
}

# 1. uriparser (pbnjson dependency)                                          [VERIFIED]
stage uriparser "$AUDIOD/uriparser" "$ST/lib/liburiparser.so" \
      -DURIPARSER_BUILD_TESTS=OFF -DURIPARSER_BUILD_DOCS=OFF

# 2. yajl (pbnjson dependency)                                               [VERIFIED]
# Built from a COPY: reformatter/ and verify/ call GET_TARGET_PROPERTY(... LOCATION), which
# CMake 4 removed. Only the library is needed, so those subdirs are dropped from the copy --
# the upstream tree is never modified.
if [ ! -e "$ST/lib/libyajl.so" ]; then
  rm -rf "$H/src/yajl"; cp -r "$AUDIOD/yajl" "$H/src/yajl"
  sed -i -E 's@^ADD_SUBDIRECTORY\((test|reformatter|verify|example|perf)\)@# & (host: library only)@' \
      "$H/src/yajl/CMakeLists.txt"
fi
stage yajl "$H/src/yajl" "$ST/lib/libyajl.so"

# 3. pbnjson (luna-service2 + PmLogLib dependency)                           [UNVERIFIED]
stage pbnjson "$AUDIOD/libpbnjson" "$ST/usr/lib/libpbnjson_c.so"

# 4. PmLogLib (luna-service2 + db8 dependency)                               [UNVERIFIED]
stage PmLogLib "$AUDIOD/PmLogLib" "$ST/usr/lib/libPmLogLib.so"

# 5. luna-service2 (db8 + transport dependency)                              [UNVERIFIED]
# Ships desktop_hub.sh and valgrind.supp -- upstream supported desktop runs, which is what
# lets the sanitized transport actually talk to a bus.
stage luna-service2 "$DEPS/luna-service2" "$ST/usr/lib/libluna-service2.so"

# 6. db8 -> libmojocore / libmojodb / libmojoluna                            [UNVERIFIED]
# Uses its own Makefile.Ubuntu (PLATFORM=linux-x86), not CMake. Must be the initial
# openwebos/db8 tree: the newer db8 under build-deps has an incompatible ABI (see build.sh).
if [ ! -e "$ST/usr/lib/libmojocore.so" ]; then
  printf "== %-12s " db8
  if ( cd "$DEPS/db8-openwebos-initial" \
       && make -f Makefile.Ubuntu LUNA_STAGING="$ST/usr" -j"$(nproc)" ) > "$L/db8.log" 2>&1
  then echo ok
  else echo "FAILED -- see $L/db8.log"; tail -8 "$L/db8.log"; exit 1; fi
fi

# 7. the transport itself                                                    [UNVERIFIED]
# Mirrors build.sh's flags with the ARM/device-specific parts swapped out: MOJ_X86 instead of
# the implicit ARM target, host libpurple/glib via pkg-config, and no synergy-glibc interpreter
# games. IMLIBPURPLE_LEGACY_DB8 stays -- it matches the db8 built above.
OBJ=$H/obj; OUT=$H/imlibpurpletransport
mkdir -p "$OBJ"
CXXFLAGS="-std=c++17 -fno-rtti -fpermissive -DMOJ_LINUX -DMOJ_X86 -DIMLIBPURPLE_LEGACY_DB8 $SAN"
INCLUDES="-I$IMLIB_REPO/inc -I$DEPS/db8-openwebos-initial/inc
  -I$DEPS/luna-service2/include/public -I$DEPS/luna-service2/include/public/luna-service2
  -I$ST/usr/include -I$ST/include
  -I$IMLIB_REPO/test/fuzz/compat
  $(pkg-config --cflags glib-2.0 gio-2.0 gio-unix-2.0 purple)"

OBJS=""; FAILED=0
for f in "$IMLIB_REPO"/src/*.cpp; do
  b=$(basename "$f" .cpp)
  echo "  CXX $b.cpp"
  # shellcheck disable=SC2086
  if g++ $CXXFLAGS $INCLUDES -c "$f" -o "$OBJ/$b.o" 2> "$OBJ/$b.log"; then OBJS="$OBJS $OBJ/$b.o"
  else echo "  *** FAILED: $b.cpp (see $OBJ/$b.log)"; FAILED=1; fi
done
[ $FAILED -eq 0 ] || exit 1

# Word splitting on the flag vars and pkg-config output is intended here.
# shellcheck disable=SC2086,SC2046
g++ $CXXFLAGS $OBJS -o "$OUT" \
  -L"$ST/usr/lib" -L"$ST/lib" -lmojocore -lmojodb -lmojoluna -lluna-service2 \
  $(pkg-config --libs glib-2.0 gio-2.0 gio-unix-2.0 purple) -ltidy -lrt -lpthread

echo
echo "built: $OUT"
echo "run against a desktop bus:  $DEPS/luna-service2/desktop_hub.sh"
echo "valgrind alternative:       valgrind --suppressions=$DEPS/luna-service2/valgrind.supp $OUT"
