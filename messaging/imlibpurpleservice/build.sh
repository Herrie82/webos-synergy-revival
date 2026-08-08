#!/bin/bash
# Cross-compile imlibpurpleservice -> imlibpurpletransport (ARM webOS 3.0.5).
# Authoritative build: the build deps live in this monorepo (webos-synergy-revival), but the
# transport SOURCE now lives in the standalone shared repo (Herrie82/imlibpurpleservice, branch
# herrie/synergy-revival) - it used to be vendored here under messaging/imlibpurpleservice/
# imlibpurpleservice/ and was moved out so it can be shared/upstreamed. Override IMLIB_REPO if
# your checkout is elsewhere. The old ~/webos/teams-port tree is GONE - do not use it.
# Hand-rolled build (upstream CMakeLists targets modern OSE; ignored). Host-side only.
set -e

REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
IMLIB_REPO=${IMLIB_REPO:-/home/herrie/Documents/GitHub/imlibpurpleservice}
TC=/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125/bin/arm-unknown-linux-gnueabi-
CXX=${TC}g++
READELF=${TC}readelf
STRIP=${TC}strip

SRC=$IMLIB_REPO                                              # transport source (shared repo)
BUILD=$REPO/messaging/imlibpurpleservice/build-arm           # build dir (gitignored)

[ -d "$SRC/src" ] || { echo "!! transport source not found at $SRC"; \
  echo "   clone https://github.com/Herrie82/imlibpurpleservice.git (branch herrie/synergy-revival)"; \
  echo "   or set IMLIB_REPO=/path/to/imlibpurpleservice"; exit 1; }
OBJ=$BUILD/obj
OUT=$BUILD/imlibpurpletransport
mkdir -p "$OBJ"

# Re-homed deps (this repo, gitignored under build-output/ + messaging/libpurple):
PURPLE=$REPO/messaging/libpurple                             # libpurple staging (moved from old-synergy)
TIDY=$REPO/build-output/tidy-arm/install                     # libtidy (HTML sanitize)
LIBSTUB=$REPO/build-output/imtransport/lib                   # device link stubs (mojo*/lunaservice .so)
COMPAT=$REPO/build-output/imtransport/compat-inc             # buffio.h shim

# External build deps (outside the repo, unchanged - like the toolchain/glib staging):
DEPS=/home/herrie/webos/touchpad-kernel/doctor305/build-deps
# db8 headers MUST match the STOCK device libmojocore.so ABI (initial openwebos/db8 @ 8a9a902).
# build-deps/db8 is a NEWER, incompatible db8 and must NOT be used.
DB8=$DEPS/db8-openwebos-initial
GLIB_STAGING=/home/herrie/webos/wpe/staging-glibc-252

export PKG_CONFIG_PATH=$GLIB_STAGING/lib/pkgconfig
GLIB_CFLAGS=$(pkg-config --cflags glib-2.0 gio-2.0 gio-unix-2.0)
GLIB_LIBS=$(pkg-config --libs glib-2.0 gio-2.0 gio-unix-2.0)

# IMLIBPURPLE_LEGACY_DB8: legacy webOS 3.0.5 db8 has no com.palm.config.libpurple:1 kind - bypass the
# modern config-management path that would otherwise fail and block login.
CXXFLAGS="-std=c++17 -fno-rtti -fpermissive -DMOJ_LINUX -DIMLIBPURPLE_LEGACY_DB8 -O2"

INCLUDES="
  -I$SRC/inc
  -I$DB8/inc
  -I$DEPS/luna-service2/include/public
  -I$DEPS/luna-service2/include/public/luna-service2
  -I$PURPLE/include/libpurple
  -I$DEPS/woce-build-support/staging/arm-none-linux-gnueabi/include/PmLogLib/IncsPublic
  -I$TIDY/include
  -I$COMPAT
  -I$GLIB_STAGING/include
  $GLIB_CFLAGS
"

SOURCES=$(ls "$SRC"/src/*.cpp)

echo "=== Compiling ==="
FAILED=0
OBJS=""
for f in $SOURCES; do
  b=$(basename "$f" .cpp)
  o="$OBJ/$b.o"
  echo "  CXX $b.cpp"
  if $CXX $CXXFLAGS $INCLUDES -c "$f" -o "$o" 2> "$OBJ/$b.log"; then
    OBJS="$OBJS $o"
  else
    echo "  *** FAILED: $b.cpp (see $OBJ/$b.log)"; FAILED=1
  fi
done
[ "$FAILED" != "0" ] && { echo "=== Compilation failures above; aborting link ==="; exit 1; }

echo "=== Linking $OUT ==="
LIBDIRS="-L$LIBSTUB -L$PURPLE/lib -L$GLIB_STAGING/lib -L$TIDY/lib"
RPATHLINK="-Wl,-rpath-link,$LIBSTUB -Wl,-rpath-link,$PURPLE/lib -Wl,-rpath-link,$GLIB_STAGING/lib -Wl,-rpath-link,$TIDY/lib"

# Point the interpreter at the synergy-glibc loader, NOT the Teams port's /lib/ld-teams.so.3. Both
# are glibc 2.23 but different builds; the ld-teams build SIGSEGVs purple-signal's in-process JVM
# (libjvm.so), while synergy-glibc runs it. Since the JVM is created in-process (JNI_CreateJavaVM),
# the whole transport must load under the JVM-compatible glibc. imwrap.sh pairs this by putting
# /media/cryptofs/synergy-glibc/lib first on LD_LIBRARY_PATH so the matching libc/pthread load.
# The stock 2011 /lib/ld-linux.so.3 mis-resolves GNU_UNIQUE symbols and is not an option either.
# NB: synergy-glibc lives on /media/cryptofs (NOT /media/internal) so the transport's mmap'd glibc
# doesn't pin the USB-exported vfat and block "USB drive" mode (see
# usb-drive-mode-media-internal-blockers). It is a specific frozen glibc 2.23 build (crosstool-NG)
# -- NOT interchangeable with Atlas's own wpe-252 deviceroot despite both self-reporting "glibc
# 2.23": confirmed live that swapping in Atlas's current build SIGSEGVs immediately when the kernel
# loads it as this interpreter (different build/config, not ABI-compatible with this binary).
$CXX $CXXFLAGS $OBJS -o "$OUT" \
  -Wl,--dynamic-linker=/media/cryptofs/synergy-glibc/lib/ld-linux.so.3 \
  $LIBDIRS $RPATHLINK -Wl,--allow-shlib-undefined \
  -lmojodb -lmojocore -lmojoluna -llunaservice \
  -lpurple -ltidy -lrt -lpthread \
  -lopus -logg \
  $GLIB_LIBS

echo "=== Done: $OUT ==="
$READELF -h "$OUT" | grep -E "Class|Machine"
ls -la "$OUT"
echo "md5: $(md5sum "$OUT" | awk '{print $1}')"
echo "Deploy to device /usr/bin/imlibpurpletransport (unlink busy file first; needs tellbootie reboot)."
