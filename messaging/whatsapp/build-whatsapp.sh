#!/bin/bash
# Cross-compile the WhatsApp prpl (hoehermann/purple-gowhatsapp, whatsmeow branch ->
# libwhatsmeow.so) for webOS 3.0.5 ARM (HP TouchPad).
#
# Two stages, mirroring the upstream CMake but done directly (the CMake has no cross plumbing):
#   1. Go: `go build -buildmode=c-archive` cross-compiled to libwhatsmeow.a (+ header). The
#      WhatsApp stack (go.mau.fi/whatsmeow) and its SQLite (modernc.org/sqlite) are PURE GO,
#      so this cross-compiles cleanly; the only cgo C files are bridge.c/constants.c/opusreader.c.
#   2. C glue: compile glue/*.c + root bridge.c and link against libwhatsmeow.a + libpurple
#      (+ opusfile for voice-note transcoding). gdk-pixbuf is optional — pixbuf.c is guarded by
#      __has_include, so we simply don't add it to the include path.
set -e

REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
SRC=$REPO/messaging/whatsapp/plugin/purple-gowhatsapp
GLUE=$SRC/glue
BUILD=$SRC/build-arm
PURPLE=$REPO/messaging/libpurple
GLIB_STAGING=/home/herrie/webos/wpe/staging-glibc-252     # glib + opus/ogg/opusfile (opusfile cross-built here)
GO=${GO:-/home/herrie/webos/gotool/go125/bin/go}          # Go 1.25+ (whatsmeow go.mod requires 1.25.5)
TC=/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125

source /home/herrie/webos/wpe/env-glibc-gcc125.sh 2>/dev/null || true
export PATH=$TC/bin:$PATH
: "${CC:=arm-unknown-linux-gnueabi-gcc}"
: "${STRIP:=arm-unknown-linux-gnueabi-strip}"
export PKG_CONFIG_PATH=$PURPLE/lib/pkgconfig:$GLIB_STAGING/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH
VERSION=$(cat "$SRC/VERSION" 2>/dev/null || echo 0.0.0)

mkdir -p "$BUILD"

echo "=== STAGE 1: Go c-archive (libwhatsmeow.a) for armv7 ==="
export GOPATH=${GOPATH:-/home/herrie/webos/gotool/gopath}
export GOCACHE=${GOCACHE:-/home/herrie/webos/gotool/gocache}
export GOMODCACHE=${GOMODCACHE:-/home/herrie/webos/gotool/gomod}
export GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=1
export CGO_CFLAGS="-I$PURPLE/include/libpurple -I$PURPLE/include -I$GLIB_STAGING/include -I$GLIB_STAGING/include/opus $(pkg-config --cflags glib-2.0) -DPLUGIN_VERSION=$VERSION -D_DEFAULT_SOURCE"
export CGO_LDFLAGS="-L$PURPLE/lib -L$GLIB_STAGING/lib -lpurple -lopusfile -lopus -logg"
( cd "$SRC" && "$GO" build -buildmode=c-archive -o "$BUILD/libwhatsmeow.a" . )
echo "  -> $(ls -la "$BUILD/libwhatsmeow.a" | awk '{print $5}') bytes"

echo "=== STAGE 2: compile C glue ==="
# NB: include $BUILD (for the go-generated libwhatsmeow.h) and $SRC (root bridge.h/constants.h);
# do NOT add gdk-pixbuf to the path so pixbuf.c takes its no-pixbuf fallback.
GCFLAGS="$CFLAGS $CPPFLAGS -fPIC -DPURPLE_PLUGINS -DPLUGIN_VERSION=$VERSION \
	-I$GLUE -I$SRC -I$BUILD -I$PURPLE/include $(pkg-config --cflags purple glib-2.0) -I$GLIB_STAGING/include -I$GLIB_STAGING/include/opus"
OBJS=()
# glue/*.c
for s in init login qrcode bridge process_message display_message groups blist \
         send_message handle_attachment send_file presence options receipt pixbuf commands; do
	echo "  CC glue/$s.c"; $CC $GCFLAGS -c "$GLUE/$s.c" -o "$BUILD/glue_$s.o"; OBJS+=("$BUILD/glue_$s.o")
done
# root C files compiled into the plugin too (per glue/CMakeLists): ../bridge.c is required again
for s in bridge constants; do
	echo "  CC $s.c"; $CC $GCFLAGS -c "$SRC/$s.c" -o "$BUILD/root_$s.o"; OBJS+=("$BUILD/root_$s.o")
done

echo "=== STAGE 3: link libwhatsmeow.so ==="
# The Go c-archive pulls in the Go runtime: needs pthread/dl/m + libresolv (net) at link.
$CC -shared -fPIC $LDFLAGS -Wl,-soname,libwhatsmeow.so -o "$BUILD/libwhatsmeow.so" \
	"${OBJS[@]}" "$BUILD/libwhatsmeow.a" \
	-L"$PURPLE/lib" -L"$GLIB_STAGING/lib" $(pkg-config --libs purple glib-2.0) \
	-lopusfile -lopus -logg -lpthread -ldl -lm -lresolv

echo "=== Stripping ==="
cp "$BUILD/libwhatsmeow.so" "$BUILD/libwhatsmeow.stripped.so"
"$STRIP" --strip-unneeded "$BUILD/libwhatsmeow.stripped.so"
ls -la "$BUILD/libwhatsmeow.stripped.so"
echo ""
echo "=== NEEDED ===" && arm-unknown-linux-gnueabi-readelf -d "$BUILD/libwhatsmeow.so" | grep NEEDED
echo "purple_init_plugin: $(arm-unknown-linux-gnueabi-nm -D "$BUILD/libwhatsmeow.so" | grep -c purple_init_plugin)"
echo "prpl id: $(arm-unknown-linux-gnueabi-strings "$BUILD/libwhatsmeow.so" | grep -m1 prpl-hehoe-whatsmeow)"
