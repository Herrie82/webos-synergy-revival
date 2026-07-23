#!/bin/bash
# build-mp-autoplug.sh - cross-compile the media-pipeline autoplug shim (libmp-autoplug.so) with the
# PalmPDK toolchain. The prebuilt .so in prebuilt/ is what install-videoplayer-webm.sh ships; rebuild
# only if you change src/mp_autoplug.c.
#
# The shim only calls dlsym + a few gst_*/g_* symbols that are resolved from the host process
# (media-pipeline.real) at load time, so it links against nothing but libdl - it just needs the
# gstreamer-0.10 / glib-2.16 HEADERS to compile. Point GSTBUILD at the same header tree used to build
# the gst-video-codecs plugins (glib-2.16.6/, gstreamer-0.10.29/ from the HP Open Source drops).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
CC="${CC:-/opt/PalmPDK/arm-gcc/bin/arm-none-linux-gnueabi-gcc}"
GSTBUILD="${GSTBUILD:-$HOME/webos/gstbuild}"   # tree with glib-2.16.6/ and gstreamer-0.10.29/ headers

CFLAGS="-fPIC -O2 -Wall
  -I$GSTBUILD/glib-2.16.6 -I$GSTBUILD/glib-2.16.6/glib -I$GSTBUILD/glib-2.16.6/gmodule
  -I$GSTBUILD/glib-2.16.6/gobject
  -I$GSTBUILD/gstreamer-0.10.29 -I$GSTBUILD/gstreamer-0.10.29/libs
  -I$GSTBUILD"

echo "CC=$CC"
echo "GSTBUILD=$GSTBUILD"
"$CC" $CFLAGS -shared -o "$HERE/prebuilt/libmp-autoplug.so" "$HERE/src/mp_autoplug.c" -ldl
echo "built prebuilt/libmp-autoplug.so"
"${CC%-gcc}-nm" -D -u "$HERE/prebuilt/libmp-autoplug.so" | grep -iE "dlsym|gst_|g_signal" || true
echo "(undefined gst_*/g_signal_* symbols above resolve from media-pipeline.real at LD_PRELOAD time)"
