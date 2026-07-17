#!/bin/bash
# Cross-compile the Facebook prpl (dequis/purple-facebook -> libfacebook.so) for
# webOS 3.0.5 ARM (HP TouchPad). Authoritative build: everything lives in this
# monorepo (webos-synergy-revival).
#
# purple-facebook ships an autotools build, but cross-configuring it against our
# staged sysroot is fussy, so — like the Discord/Teams prpls — we compile the fixed
# FACEBOOKSOURCES list directly with the ARM toolchain, replicating the exact flags
# the plugin's Makefile.am / configure.ac would use:
#   PLUGIN_CFLAGS = -I<repo>/include -I<repo>/pidgin -I<repo>/pidgin/libpurple \
#                   -DPURPLE_PLUGINS -include purple-compat.h
#   + $(GLIB_CFLAGS) $(JSON_CFLAGS) $(PURPLE_CFLAGS) $(ZLIB_CFLAGS)
#   link: $GLIB_LIBS $JSON_LIBS $PURPLE_LIBS $ZLIB_LIBS  (TLS is libpurple's SSL plugin)
#
# The marshal.c/marshal.h are generated from marshaller.list with the HOST
# glib-genmarshal (a build tool, arch-independent output).
set -e

REPO=/home/herrie/Documents/GitHub/webos-synergy-revival
SRC=$REPO/messaging/facebook/plugin/purple-facebook           # prpl source (this repo)
FBDIR=$SRC/pidgin/libpurple/protocols/facebook                # facebook protocol sources
COMPAT=$SRC/pidgin/libpurple                                  # purple2compat http.c / purple-socket.c
BUILD=$SRC/build-arm                                          # build dir (gitignored)
PURPLE=$REPO/messaging/libpurple                              # prebuilt libpurple 2.14 staging (this repo)
GLIB_STAGING=/home/herrie/webos/wpe/staging-glibc-252         # glib/json-glib/zlib/openssl staging (external dep)

OUT=$BUILD/libfacebook.so
STRIPPED=$BUILD/libfacebook.stripped.so

source /home/herrie/webos/wpe/env-glibc-gcc125.sh 2>/dev/null || true
: "${CC:=arm-unknown-linux-gnueabi-gcc}"
: "${STRIP:=arm-unknown-linux-gnueabi-strip}"
export PKG_CONFIG_PATH=$PURPLE/lib/pkgconfig:$GLIB_STAGING/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PKG_CONFIG_PATH

PKGS="purple json-glib-1.0 glib-2.0 gobject-2.0 gio-2.0 zlib"
PKG_CFLAGS=$(pkg-config --cflags $PKGS)
PKG_LIBS=$(pkg-config --libs $PKGS)

# purple.pc's Cflags is only "-I<prefix>/include/libpurple" (bare-name includes like
# "account.h"); the compat headers also use <libpurple/util.h>, which needs the parent
# include dir on the path. On a normal /usr install that's implicit; with our staged
# prefix we must add it explicitly.
# config.h substitutions autotools would normally provide (from configure.ac AC_INIT).
# Only PACKAGE_VERSION (api.h user-agent) and PACKAGE_URL (facebook.c homepage) are used.
FB_VERSION=$(cat "$SRC/RELEASE_VERSION")
VERSION_DEFS="-DPACKAGE_VERSION=\"$FB_VERSION\" -DPACKAGE_URL=\"https://github.com/dequis/purple-facebook\""
PLUGIN_CFLAGS="-I$SRC/include -I$SRC/pidgin -I$COMPAT -I$BUILD -I$PURPLE/include -DPURPLE_PLUGINS -include purple-compat.h $VERSION_DEFS"

mkdir -p "$BUILD"

echo "=== Generating marshal.{c,h} (host glib-genmarshal) ==="
glib-genmarshal --prefix=fb_marshal --header "$FBDIR/marshaller.list" > "$BUILD/marshal.h"
{ echo "#include \"marshal.h\""; glib-genmarshal --prefix=fb_marshal --body "$FBDIR/marshaller.list"; } > "$BUILD/marshal.c"

# FACEBOOKSOURCES (.c only); note TWO http.c (facebook's + the purple2compat one) -> distinct .o names.
compile() { # <src> <objname>
	echo "  CC $2"
	$CC $CFLAGS $CPPFLAGS $PLUGIN_CFLAGS $PKG_CFLAGS -fPIC -c "$1" -o "$BUILD/$2"
}

echo "=== Compiling ==="
compile "$BUILD/marshal.c"   marshal.o
compile "$FBDIR/api.c"       api.o
compile "$FBDIR/data.c"      data.o
compile "$FBDIR/facebook.c"  facebook.o
compile "$FBDIR/http.c"      fb_http.o
compile "$FBDIR/json.c"      json.o
compile "$FBDIR/mqtt.c"      mqtt.o
compile "$FBDIR/thrift.c"    thrift.o
compile "$FBDIR/util.c"      util.o
compile "$COMPAT/http.c"     compat_http.o
compile "$COMPAT/purple-socket.c" purple-socket.o

echo "=== Linking libfacebook.so ==="
$CC -shared -fPIC $LDFLAGS -Wl,-soname,libfacebook.so \
	"$BUILD"/marshal.o "$BUILD"/api.o "$BUILD"/data.o "$BUILD"/facebook.o \
	"$BUILD"/fb_http.o "$BUILD"/json.o "$BUILD"/mqtt.o "$BUILD"/thrift.o \
	"$BUILD"/util.o "$BUILD"/compat_http.o "$BUILD"/purple-socket.o \
	$PKG_LIBS -o "$OUT"

echo "=== Stripping ==="
cp "$OUT" "$STRIPPED"
"$STRIP" --strip-unneeded "$STRIPPED"
ls -la "$OUT" "$STRIPPED"
echo ""
echo "=== NEEDED ==="
arm-unknown-linux-gnueabi-readelf -d "$OUT" | grep NEEDED
echo "purple_init_plugin: $(arm-unknown-linux-gnueabi-nm -D "$OUT" | grep -c purple_init_plugin)"
echo "md5 (stripped): $(md5sum "$STRIPPED" | awk '{print $1}')"
echo ""
echo "Deploy the STRIPPED lib to device (see deploy-facebook.sh):"
echo "  /media/cryptofs/apps/usr/palm/applications/com.palm.app.teams/backend/lib/purple-2/libfacebook.so"
