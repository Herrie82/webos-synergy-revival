#!/bin/bash
# Cross-compile the Google Chat prpl (EionRobb/purple-googlechat -> libgooglechat.so)
# for webOS 3.0.5 ARM (HP TouchPad). Same direct-compile approach as build-facebook.sh.
#
# Extra dependency vs Facebook: protobuf-c. Google Chat's wire protocol is protobuf, so:
#   - googlechat.pb-c.{c,h} are PRE-GENERATED (protoc-c 1.4.1) and vendored in the plugin
#     dir, so no host protoc-c is needed here (generated C is arch-independent).
#   - the tiny libprotobuf-c RUNTIME (protobuf-c-runtime/protobuf-c.c, v1.4.1) is cross-
#     compiled to a .so and linked. libprotobuf-c.so.1 must also be present on-device.
# TLS is libpurple's SSL plugin; other deps (json-glib, zlib) are already on-device.
set -e

REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
SRC=$REPO/messaging/googlechat/plugin/purple-googlechat
COMPAT=$SRC/purple2compat
PBRT=$SRC/protobuf-c-runtime
BUILD=$SRC/build-arm
PURPLE=$REPO/messaging/libpurple
GLIB_STAGING=/home/herrie/webos/wpe/staging-glibc-252

source /home/herrie/webos/wpe/env-glibc-gcc125.sh 2>/dev/null || true
: "${CC:=arm-unknown-linux-gnueabi-gcc}"
: "${STRIP:=arm-unknown-linux-gnueabi-strip}"
export PKG_CONFIG_PATH=$PURPLE/lib/pkgconfig:$GLIB_STAGING/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH

PKGS="purple json-glib-1.0 glib-2.0 gobject-2.0 gio-2.0 zlib"
PKG_CFLAGS=$(pkg-config --cflags $PKGS)
PKG_LIBS=$(pkg-config --libs $PKGS)

mkdir -p "$BUILD"

echo "=== Cross-compiling libprotobuf-c runtime (v1.4.1) ==="
$CC $CFLAGS -fPIC -shared -I"$PBRT/protobuf-c" -o "$BUILD/libprotobuf-c.so" "$PBRT/protobuf-c/protobuf-c.c" -Wl,-soname,libprotobuf-c.so.1

CFLAGS_ALL="$CFLAGS $CPPFLAGS -std=gnu99 -fPIC -DPURPLE_PLUGINS -DGOOGLECHAT_PLUGIN_VERSION=\"1.0\" \
	-I$SRC -I$COMPAT -I$PBRT -I$PURPLE/include $PKG_CFLAGS"

# PURPLE_C_FILES + generated pb-c + purple2compat (from the upstream Makefile).
SRCS=(
	libgooglechat.c googlechat.pb-c.c googlechat_json.c googlechat_pblite.c
	googlechat_connection.c googlechat_auth.c googlechat_events.c googlechat_conversation.c
)
COMPAT_SRCS=(http.c purple-socket.c)

echo "=== Compiling plugin ==="
OBJS=()
for s in "${SRCS[@]}"; do
	o="$BUILD/${s%.c}.o"; echo "  CC $s"
	$CC $CFLAGS_ALL -c "$SRC/$s" -o "$o"; OBJS+=("$o")
done
for s in "${COMPAT_SRCS[@]}"; do
	o="$BUILD/compat_${s%.c}.o"; echo "  CC purple2compat/$s"
	$CC $CFLAGS_ALL -c "$COMPAT/$s" -o "$o"; OBJS+=("$o")
done

echo "=== Linking libgooglechat.so ==="
$CC -shared -fPIC $LDFLAGS -Wl,-soname,libgooglechat.so "${OBJS[@]}" \
	-L"$BUILD" -lprotobuf-c -Wl,-rpath-link,"$BUILD" $PKG_LIBS -o "$BUILD/libgooglechat.so"

echo "=== Stripping ==="
cp "$BUILD/libgooglechat.so" "$BUILD/libgooglechat.stripped.so"
"$STRIP" --strip-unneeded "$BUILD/libgooglechat.stripped.so"
cp "$BUILD/libprotobuf-c.so" "$BUILD/libprotobuf-c.stripped.so"
"$STRIP" --strip-unneeded "$BUILD/libprotobuf-c.stripped.so"
ls -la "$BUILD/libgooglechat.stripped.so" "$BUILD/libprotobuf-c.stripped.so"
echo ""
echo "=== NEEDED ===" && arm-unknown-linux-gnueabi-readelf -d "$BUILD/libgooglechat.so" | grep NEEDED
echo "purple_init_plugin: $(arm-unknown-linux-gnueabi-nm -D "$BUILD/libgooglechat.so" | grep -c purple_init_plugin)"
echo "prpl id: $(strings "$BUILD/libgooglechat.so" | grep -m1 prpl-googlechat)"
