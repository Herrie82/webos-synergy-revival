#!/bin/sh
# Cross-compile the Teams call media engine (teams_media.c) for the HP TouchPad (webOS ARMv7,
# gst-1.20.7 from the Atlas/WPE staging). Simpler than the Signal build: no OpenSSL / no KDF -
# Teams uses SDES keys carried in the SDP, so there is no DH to derive. Produces:
#   teams_media   : standalone ARM binary. `teams_media --loopback` self-tests SRTP-GCM+RTP+Opus;
#                   `teams_media --answer` drives a live call over the stdin/stdout IPC.
# Runtime: run under the wpe-glibc loader (patchelf --set-interpreter) with the WPE gst plugin path,
# same recipe as messaging/signal/calling/media/RUNTIME_STATUS.reference.md.
set -e
HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"

TOOLCHAIN=/home/herrie/x-tools/arm-unknown-linux-gnueabi-gcc125
CROSS=$TOOLCHAIN/bin/arm-unknown-linux-gnueabi-
SYSROOT=/home/herrie/webos/wpe/staging-glibc-252
CC=${CROSS}gcc
[ -x "$CC" ] || { echo "ERROR: cross gcc not at $CC" >&2; exit 1; }

export PKG_CONFIG_PATH=$SYSROOT/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$SYSROOT/lib/pkgconfig
PKGS="gstreamer-1.0 gstreamer-base-1.0 gstreamer-app-1.0 nice glib-2.0 gobject-2.0 gthread-2.0"
CFLAGS=$(pkg-config --cflags $PKGS)
LIBS=$(pkg-config --libs $PKGS)

# -Wl,-rpath-link resolves transitive .so deps inside staging at link time.
RPATHLINK="-Wl,-rpath-link,$SYSROOT/lib"

echo "== building teams_media (ARM) =="
$CC -O2 -g -o teams_media teams_media.c $CFLAGS $LIBS $RPATHLINK
${CROSS}strip teams_media 2>/dev/null || true
echo "== built =="
ls -la teams_media
${CROSS}readelf -d teams_media | grep NEEDED
