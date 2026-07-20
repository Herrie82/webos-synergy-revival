#!/bin/bash
# Cross-compile purple-gometa (Facebook Messenger + E2EE via mautrix-meta's messagix +
# whatsmeow) -> libgometa.so for webOS 3.0.5 ARM (HP TouchPad). Adapted from the working
# ../../../whatsapp/plugin/purple-gowhatsapp/build-whatsapp.sh (same two-stage pattern).
#
#   STAGE 1: Go `go build -buildmode=c-archive` -> libgometa.a (+ header). messagix +
#            whatsmeow + libsignal are PURE GO (the spike proved GOARM=7 c-archive builds),
#            so this cross-compiles cleanly; cgo is only the prpl bridge C files.
#   STAGE 2/3: compile glue/*.c + root bridge.c, link against libgometa.a + libpurple.
#
# STATUS: the Go prpl package (root *.go: bridge.go/login.go/send_message.go/...) and the C
# glue (glue/*.c, bridge.c/bridge.h) are NOT written yet — see README "Next steps". Until
# they exist, STAGE 1 has nothing to compile. The env/flags below are the finished recipe;
# `SPIKE_ONLY=1 ./build-meta.sh` cross-compiles just the login-spike (which does exist).
set -e

REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
SRC=$REPO/messaging/facebook-e2ee/plugin/purple-gometa
GLUE=$SRC/glue
BUILD=$SRC/build-arm
PURPLE=$REPO/messaging/libpurple
GLIB_STAGING=/home/herrie/webos/wpe/staging-glibc-252
GO=${GO:-/home/herrie/webos/gotool/go125/bin/go}
TC=/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125

source /home/herrie/webos/wpe/env-glibc-gcc125.sh 2>/dev/null || true
export PATH=$TC/bin:$PATH
: "${CC:=arm-unknown-linux-gnueabi-gcc}"
: "${STRIP:=arm-unknown-linux-gnueabi-strip}"
export GOPATH=${GOPATH:-/home/herrie/webos/gotool/gopath}
export GOCACHE=${GOCACHE:-/home/herrie/webos/gotool/gocache}
export GOMODCACHE=${GOMODCACHE:-/home/herrie/webos/gotool/gomod}
export PKG_CONFIG_PATH=$PURPLE/lib/pkgconfig:$GLIB_STAGING/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH
VERSION=$(cat "$SRC/VERSION" 2>/dev/null || echo 0.0.0)
mkdir -p "$BUILD"

export GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=1
export CC CXX=arm-unknown-linux-gnueabi-g++

if [ "${SPIKE_ONLY:-0}" = "1" ]; then
	echo "=== SPIKE_ONLY: cross-compile login-spike (armv7) ==="
	cd "$SRC"
	CGO_ENABLED=0 GOARM=7 "$GO" build -o "$BUILD/login-spike.arm" ./login-spike
	ls -la "$BUILD/login-spike.arm"; file "$BUILD/login-spike.arm" | cut -d, -f1-2
	exit 0
fi

echo "=== STAGE 1: Go c-archive (libgometa.a) for armv7 ==="
export CGO_CFLAGS="-I$PURPLE/include/libpurple -I$PURPLE/include -I$GLIB_STAGING/include $(pkg-config --cflags glib-2.0) -DPLUGIN_VERSION=$VERSION -D_DEFAULT_SOURCE"
export CGO_LDFLAGS="-L$PURPLE/lib -L$GLIB_STAGING/lib -lpurple"
if ! ls "$SRC"/*.go >/dev/null 2>&1; then
	echo "  !! no root *.go prpl package yet — write the glue first (see README). Aborting."
	echo "  (to build just the spike: SPIKE_ONLY=1 $0)"
	exit 1
fi
( cd "$SRC" && "$GO" build -buildmode=c-archive -o "$BUILD/libgometa.a" . )
echo "  -> $(ls -la "$BUILD/libgometa.a" | awk '{print $5}') bytes"

echo "=== STAGE 2: compile C glue ==="
GCFLAGS="$CFLAGS $CPPFLAGS -fPIC -DPURPLE_PLUGINS -DPLUGIN_VERSION=$VERSION \
	-I$GLUE -I$SRC -I$BUILD -I$PURPLE/include $(pkg-config --cflags purple glib-2.0) -I$GLIB_STAGING/include"
OBJS=()
for s in $(cd "$GLUE" 2>/dev/null && ls *.c 2>/dev/null | sed 's/\.c$//'); do
	echo "  CC glue/$s.c"; $CC $GCFLAGS -c "$GLUE/$s.c" -o "$BUILD/glue_$s.o"; OBJS+=("$BUILD/glue_$s.o")
done
for s in bridge constants; do
	[ -f "$SRC/$s.c" ] && { echo "  CC $s.c"; $CC $GCFLAGS -c "$SRC/$s.c" -o "$BUILD/root_$s.o"; OBJS+=("$BUILD/root_$s.o"); }
done

echo "=== STAGE 3: link libgometa.so ==="
$CC -shared -fPIC $LDFLAGS -Wl,-soname,libgometa.so -o "$BUILD/libgometa.so" \
	"${OBJS[@]}" "$BUILD/libgometa.a" \
	-L"$PURPLE/lib" -L"$GLIB_STAGING/lib" $(pkg-config --libs purple glib-2.0) \
	-lpthread -ldl -lm -lresolv

echo "=== Stripping ==="
cp "$BUILD/libgometa.so" "$BUILD/libgometa.stripped.so"
"$STRIP" --strip-unneeded "$BUILD/libgometa.stripped.so"
ls -la "$BUILD/libgometa.stripped.so"
echo "=== NEEDED ===" && arm-unknown-linux-gnueabi-readelf -d "$BUILD/libgometa.so" | grep NEEDED
echo "purple_init_plugin: $(arm-unknown-linux-gnueabi-nm -D "$BUILD/libgometa.so" | grep -c purple_init_plugin)"
